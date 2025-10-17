#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# syncs3.sh (v5.7)
# - Concurrent per-P1 sync with background queues
# - Clean plan/run output (no class names)
# - Summary uses pure bash (no awk), and we hard-stop any straggler children
# ==============================================================================

LOG_DIR="${LOG_DIR:-./logs}"
LIGHT_CONC="${LIGHT_CONC:-10}"
MED_CONC="${MED_CONC:-3}"
HEAVY_CONC="${HEAVY_CONC:-5}"
EXTRA_SYNC_ARGS="${EXTRA_SYNC_ARGS:-}"

mkdir -p "$LOG_DIR"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
START_TS="$(date +%s)"
MASTER_CSV="$LOG_DIR/sync_${RUN_ID}_deltas.csv"

# ---- colors (optional) -------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN="$(tput setaf 2 || true)"; RED="$(tput setaf 1 || true)"; YEL="$(tput setaf 3 || true)"
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
else
  GREEN=""; RED=""; YEL=""; BOLD=""; RESET=""
fi

# ---- preflight ---------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "[ERROR] aws CLI not found" >&2; exit 127; }
[[ -f ./awshelper.sh ]] || { echo "[ERROR] awshelper.sh not found" >&2; exit 1; }
# shellcheck disable=SC1091
source ./awshelper.sh
[[ -n "${SRC:-}" && -n "${DST:-}" ]] || { echo "[ERROR] SRC and DST must be set (awshelper.sh)" >&2; exit 1; }
[[ -x ./vault_keepalive.sh ]] || { echo "[ERROR] vault_keepalive.sh not found or not executable" >&2; exit 1; }

# ---- helpers -----------------------------------------------------------------
trim_slashes() { local s="${1:-}"; s="${s#/}"; s="${s%/}"; echo "$s"; }
safe_number()  { [[ "${1:-}" =~ ^-?[0-9]+$ ]] && echo "$1" || echo 0; }

# human_bytes: pure bash, no awk
human_bytes() {
  local b="${1:-0}" units=(B KiB MiB GiB TiB PiB) i=0
  while (( b >= 1024 && i < ${#units[@]}-1 )); do
    # integer "rounding" using 2 decimals: scale via *100 then /1024
    local next=$(( (b * 100 + 512) / 1024 ))
    b=$(( next ))
    (( i++ ))
  done
  # place decimal point for scaled units
  if (( i == 0 )); then
    printf "%d %s" "$b" "${units[i]}"
  else
    printf "%d.%02d %s" $((b/100)) $((b%100)) "${units[i]}"
  fi
}

summarize_count_bytes() {
  # echoes: "<count> <bytes>" (0 0 on error)
  local uri="$1" out rc objs bytes
  set +e
  out=$(aws s3 ls "$uri" --recursive --summarize 2>/dev/null)
  rc=$?
  set -e
  if (( rc != 0 )); then echo "0 0"; return; fi
  objs=$(printf "%s\n" "$out" | sed -n 's/^Total Objects:[[:space:]]*\([0-9]\+\).*$/\1/p' | tail -n1)
  bytes=$(printf "%s\n" "$out" | sed -n 's/^Total Size:[[:space:]]*\([0-9]\+\).*$/\1/p' | tail -n1)
  echo "$(safe_number "$objs") $(safe_number "$bytes")"
}

# Robustly extract first-level prefixes (P1) from `aws s3 ls` output.
# Handles lines with/without indentation, ignores file rows.
# Return first-level prefixes under BASE (or bucket root if BASE empty),
# using the S3 API with delimiter='/'. No jq required.
# --- Robust P1 discovery: API first, ls-text fallback (no jq, pipefail-safe) ---

list_p1_prefixes_api() {
  local bucket="$SRC"
  local base="${BASE:-}"
  local prefix=""
  [[ -n "$base" ]] && prefix="${base%/}/"

  local token="" out p rest
  while : ; do
    # Build args (avoid passing empty flags)
    local args=(s3api list-objects-v2 --bucket "$bucket" --delimiter '/')
    [[ -n "$prefix" ]] && args+=(--prefix "$prefix")
    [[ -n "$token"  ]] && args+=(--continuation-token "$token")

    # CommonPrefixes as text; returns nothing if none
    out="$(aws "${args[@]}" --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null || true)"

    if [[ -n "$out" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # Strip BASE/prefix and trailing slash to get the "P1" component.
        rest="${p#${prefix}}"; rest="${rest%/}"
        # Keep only the first path segment (P1), even if API accidentally gives deeper paths.
        printf '%s\n' "${rest%%/*}"
      done <<<"$out"
    fi

    # Next token?
    token="$(aws "${args[@]}" --query 'NextContinuationToken' --output text 2>/dev/null || true)"
    [[ -z "$token" || "$token" == "None" ]] && break
  done
}

list_p1_prefixes_ls() {
  # Very forgiving parser for human-readable `aws s3 ls` output.
  # Accepts lines like "PRE foo/" (indented or not).
  local base_uri="$1" line name
  local out
  out="$(aws s3 ls "$base_uri" 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      *" PRE "*"/" | "PRE "*"/")
        # Extract the name portion after PRE and strip trailing '/'
        name="${line##* PRE }"
        name="${name#PRE }"
        name="${name%/}"
        printf '%s\n' "$name"
        ;;
    esac
  done <<<"$out"
}

list_p1_prefixes_robust() {
  # 1) API
  local api; api="$(list_p1_prefixes_api | sort -u)"
  if [[ -n "$api" ]]; then printf '%s\n' "$api"; return 0; fi
  # 2) Fallback: ls text
  local base_uri
  if [[ -n "${BASE:-}" ]]; then
    base_uri="s3://${SRC}/${BASE%/}/"
  else
    base_uri="s3://${SRC}/"
  fi
  list_p1_prefixes_ls "$base_uri" | sort -u
}


gate_local() { # limit concurrency within a queue controller
  local limit="${1:-0}"
  if (( limit > 0 )); then
    while (( $(jobs -rp | wc -l) >= limit )); do sleep 0.2; done
  fi
}

# ---- scope / header ----------------------------------------------------------
BASE="$(trim_slashes "${BASE:-}")"
if [[ -n "$BASE" ]]; then
  SRC_BASE_URI="s3://${SRC}/${BASE}/"
  DST_BASE_URI="s3://${DST}/${BASE}/"
  BASE_DESC="BASE=${BASE}"
else
  SRC_BASE_URI="s3://${SRC}/"
  DST_BASE_URI="s3://${DST}/"
  BASE_DESC="FULL BUCKET (all P1s)"
fi

# ---- flags / filter ----------------------------------------------------------
FILTER="${COMPARE_FILTER:-}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)      FILTER="${2:-}"; shift 2 ;;
    --filter=*)    FILTER="${1#*=}"; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    *)             shift ;;
  esac
done

MODE_DESC="$BASE_DESC"
[[ -n "$FILTER" ]] && MODE_DESC="$BASE_DESC; FILTER='${FILTER}'"

echo "------------------------------------------------------------"
echo " Sync dispatcher"
echo " Source:       ${SRC_BASE_URI}"
echo " Destination:  ${DST_BASE_URI}"
echo " Mode:         ${MODE_DESC}"
echo " Logs:         ${LOG_DIR}/sync_${RUN_ID}_<pfx>.raw.log / .err.log"
echo " Master CSV:   ${MASTER_CSV}"
echo "------------------------------------------------------------"

# ---- list candidates ---------------------------------------------------------
echo "[scan] Listing P1 under: ${SRC_BASE_URI}"

ALL_P1=()
# Insulate the mapfile < <(...) from pipefail/empty-output surprises
set +o pipefail
if mapfile -t ALL_P1 < <(list_p1_prefixes_robust); then :; else ALL_P1=(); fi
set -o pipefail

# Optional: quick debug breadcrumb if you ever need it
# SYNC_DEBUG=1 ./syncs3.sh ...
if [[ "${SYNC_DEBUG:-0}" -eq 1 ]]; then
  echo "[debug] raw P1 candidates: ${#ALL_P1[@]}"
  printf '  - %s\n' "${ALL_P1[@]}"
fi

CAND=()
for p in "${ALL_P1[@]}"; do
  # Keep only non-empty names and apply filter (case-insensitive)
  [[ -z "$p" ]] && continue
  if [[ -z "${FILTER:-}" || "${p,,}" == *"${FILTER,,}"* ]]; then
    CAND+=("$p")
  fi
done

if ((${#CAND[@]}==0)); then
  echo "[WARN] No P1 prefixes found under ${SRC_BASE_URI} (filter='${FILTER:-}')"
  echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"
  exit 0
fi




# ---- peek + classify ---------------------------------------------------------
declare -A SRC_OBJS SRC_BYTES PCLASS
LIGHT=() ; MED=() ; HEAVY=()
TOTAL_SELECTED_OBJS=0
TOTAL_SELECTED_BYTES=0

for p in "${CAND[@]}"; do
  if [[ -n "$BASE" ]]; then
    peek_uri="s3://${SRC}/${BASE}/${p}"
  else
    peek_uri="s3://${SRC}/${p}"
  fi
  read -r cnt bytes <<<"$(summarize_count_bytes "$peek_uri")"
  SRC_OBJS["$p"]="$cnt"
  SRC_BYTES["$p"]="$bytes"
  (( TOTAL_SELECTED_OBJS += cnt ))
  (( TOTAL_SELECTED_BYTES += bytes ))

  if   (( cnt < 10 ));     then LIGHT+=("$p");  PCLASS["$p"]="LIGHT"
  elif (( cnt > 150 ));    then HEAVY+=("$p");  PCLASS["$p"]="HEAVY"
  else                          MED+=("$p");    PCLASS["$p"]="MEDIUM"
  fi
done

# ---- plan (simple) -----------------------------------------------------------
echo "[plan] ${#CAND[@]} prefix(es); concurrency ${HEAVY_CONC}/${MED_CONC}/${LIGHT_CONC}  (H/M/L)"
for p in "${CAND[@]}"; do printf "  - %s\n" "$p"; done
echo

# ---- dry-run -----------------------------------------------------------------
if (( DRY_RUN == 1 )); then
  echo "[dry-run] Would sync per-P1 with these commands:"
  for p in "${CAND[@]}"; do
    if [[ -n "$BASE" ]]; then
      echo "  aws s3 sync s3://${SRC}/${BASE}/${p}  s3://${DST}/${BASE}/${p}  --exclude '*\$folder\$' --exact-timestamps --size-only --no-progress --only-show-errors"
    else
      echo "  aws s3 sync s3://${SRC}/${p}  s3://${DST}/${p}  --exclude '*\$folder\$' --exact-timestamps --size-only --no-progress --only-show-errors"
    fi
  done
  echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"
  exit 0
fi

# ---- CSV header --------------------------------------------------------------
echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"

# ---- per-P1 runner -----------------------------------------------------------
run_one_prefix() {
  local p1="$1" class="$2"
  local src_uri dst_uri log_base raw_log err_log
  if [[ -n "${BASE:-}" ]]; then
    src_uri="s3://${SRC}/${BASE}/${p1}"
    dst_uri="s3://${DST}/${BASE}/${p1}"
  else
    src_uri="s3://${SRC}/${p1}"
    dst_uri="s3://${DST}/${p1}"
  fi
  local safe="${p1//\//__}"
  log_base="$LOG_DIR/sync_${RUN_ID}_${safe}"
  raw_log="${log_base}.raw.log"
  err_log="${log_base}.err.log"

  read -r dst_pre_objs dst_pre_bytes <<<"$(summarize_count_bytes "$dst_uri")"

  echo "[run] ${p1} -> ${dst_uri}" | tee -a "$raw_log"

  # shellcheck disable=SC2086
  ./vault_keepalive.sh aws s3 sync "$src_uri" "$dst_uri" \
      --exclude '*$folder$' \
      --exact-timestamps \
      --size-only \
      --no-progress \
      --only-show-errors \
      $EXTRA_SYNC_ARGS \
      >>"$raw_log" 2>>"$err_log"
  local rc=$?

  read -r dst_post_objs dst_post_bytes <<<"$(summarize_count_bytes "$dst_uri")"
  local copied_objs=$(( dst_post_objs - dst_pre_objs ))
  local copied_bytes=$(( dst_post_bytes - dst_pre_bytes ))

  if (( rc == 0 )); then
    if (( copied_objs > 0 || copied_bytes > 0 )); then
      echo "[done] ${p1} copied: ${copied_objs} objs ($(human_bytes "$copied_bytes"))" | tee -a "$raw_log"
    else
      echo "[done] ${p1} already up-to-date" | tee -a "$raw_log"
    fi
  else
    echo "[FAIL] ${p1} (rc=${rc}) — see ${err_log}" | tee -a "$raw_log"
  fi

  printf "%s,%s,%s,%s,%s\n" "$p1" "$class" "$copied_objs" "$copied_bytes" "$rc" \
    | tee -a "$MASTER_CSV" > "${log_base}.delta.csv"
  return $rc
}

# ---- aggregate helpers -------------------------------------------------------
TOTAL_COPIED_OBJS=0
TOTAL_COPIED_BYTES=0
ALREADY_UP_TO_DATE=0
aggregate_delta_csv() {
  local csv="$1"
  [[ -s "$csv" ]] || return 0
  IFS=',' read -r _pfx _class d_objs d_bytes _rc < "$csv" || return 0
  d_objs=$(safe_number "${d_objs:-0}")
  d_bytes=$(safe_number "${d_bytes:-0}")
  (( TOTAL_COPIED_OBJS += d_objs ))
  (( TOTAL_COPIED_BYTES += d_bytes ))
  if (( d_objs == 0 && d_bytes == 0 )); then (( ALREADY_UP_TO_DATE += 1 )); fi
}

# ---- launch queues concurrently ----------------------------------------------
controller_pids=()
echo "[run] Dispatching concurrent sync jobs..."

if ((${#HEAVY[@]})); then
  (
    for p in "${HEAVY[@]}"; do gate_local "$HEAVY_CONC"; run_one_prefix "$p" "HEAVY" </dev/null & done
    wait
  ) & controller_pids+=("$!")
fi
if ((${#MED[@]})); then
  (
    for p in "${MED[@]}"; do gate_local "$MED_CONC"; run_one_prefix "$p" "MEDIUM" </dev/null & done
    wait
  ) & controller_pids+=("$!")
fi
if ((${#LIGHT[@]})); then
  (
    for p in "${LIGHT[@]}"; do gate_local "$LIGHT_CONC"; run_one_prefix "$p" "LIGHT" </dev/null & done
    wait
  ) & controller_pids+=("$!")
fi

for pid in "${controller_pids[@]:-}"; do
  wait "$pid"
done

# Aggregate deltas
for p in "${HEAVY[@]}"; do aggregate_delta_csv "$LOG_DIR/sync_${RUN_ID}_${p//\//__}.delta.csv"; done
for p in "${MED[@]}";   do aggregate_delta_csv "$LOG_DIR/sync_${RUN_ID}_${p//\//__}.delta.csv"; done
for p in "${LIGHT[@]}"; do aggregate_delta_csv "$LOG_DIR/sync_${RUN_ID}_${p//\//__}.delta.csv"; done

# ---- summary (all in bash) ---------------------------------------------------
END_TS="$(date +%s)"
ELAPSED=$(( END_TS - START_TS ))

echo
echo "==================== Summary (RUN ${RUN_ID}) ===================="
printf " Selected P1 total (SRC peek): %12d  (%s)\n" \
       "$TOTAL_SELECTED_OBJS" "$(human_bytes "$TOTAL_SELECTED_BYTES")"
echo
printf " Total copied (DST delta):     %12d  (%s)\n" \
       "$TOTAL_COPIED_OBJS" "$(human_bytes "$TOTAL_COPIED_BYTES")"
printf " Already up-to-date P1s:       %12d  / %d\n" \
       "$ALREADY_UP_TO_DATE" "${#CAND[@]}"
echo
printf " Concurrency (H/M/L):          %d/%d/%d\n" \
       "$HEAVY_CONC" "$MED_CONC" "$LIGHT_CONC"
echo " Elapsed:                       ${ELAPSED}s"
echo " Logs:                          ${LOG_DIR}/sync_${RUN_ID}_<pfx>.raw.log  (+ .err.log)"
echo " Master CSV:                    ${MASTER_CSV}"
echo "==============================================================="

# ---- hard stop any stragglers, then exit cleanly ----------------------------
pkill -P $$ 2>/dev/null || true
for pid in $(jobs -pr); do wait "$pid" || true; done
exit 0
