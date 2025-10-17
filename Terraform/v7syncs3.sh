#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# syncs3.sh (v5.3) — per-P1 dispatcher with background jobs + copy counts + CSV
# ------------------------------------------------------------------------------
# - Lists next-level prefixes (P1) under s3://$SRC/(BASE/)
# - Optional substring filter (--filter or env COMPARE_FILTER)
# - Classifies P1s by source object count:
#       < 10 objs    -> LIGHT   (high concurrency)
#       10..150 objs -> MEDIUM
#       > 150 objs   -> HEAVY   (concurrency 5)
# - Runs per-P1 sync: s3://SRC/(BASE/)P1 -> s3://DST/(BASE/)P1
#     flags: --exclude '*$folder$' --exact-timestamps --size-only --no-progress --only-show-errors
# - Computes copied deltas from DST pre/post totals; prints concise lines
# - Emits per-prefix logs and a master CSV: logs/sync_<RUNID>_deltas.csv
#
# Requires:
#   - ./awshelper.sh       (exports SRC, DST, optional BASE)
#   - ./vault_keepalive.sh (keeps Vault token/lease fresh around long AWS calls)
#
# Knobs (env):
#   LOG_DIR (./logs), LIGHT_CONC (10), MED_CONC (3), HEAVY_CONC (5), EXTRA_SYNC_ARGS ("")
# ==============================================================================

# ---- knobs -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-./logs}"
LIGHT_CONC="${LIGHT_CONC:-10}"
MED_CONC="${MED_CONC:-3}"
HEAVY_CONC="${HEAVY_CONC:-5}"
EXTRA_SYNC_ARGS="${EXTRA_SYNC_ARGS:-}"

mkdir -p "$LOG_DIR"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
START_TS="$(date +%s)"
MASTER_CSV="$LOG_DIR/sync_${RUN_ID}_deltas.csv"

# ---- colors ------------------------------------------------------------------
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

human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'function p(x,u){printf "%.2f %s",x,u}
    b<1024{p(b,"B");exit}
    b<1048576{p(b/1024,"KiB");exit}
    b<1073741824{p(b/1048576,"MiB");exit}
    b<1099511627776{p(b/1073741824,"GiB");exit}
    {p(b/1099511627776,"TiB")}'
}

summarize_count_bytes() {
  # echoes: "<count> <bytes>" (0 0 on error)
  local uri="$1" out rc objs bytes
  set +e
  out=$(aws s3 ls "$uri" --recursive --summarize 2>/dev/null)
  rc=$?
  set -e
  if (( rc != 0 )); then echo "0 0"; return; fi
  objs=$(awk '/Total Objects:/ {print $3}' <<<"$out" | tail -n1)
  bytes=$(awk '/Total Size:/ {print $3}'   <<<"$out" | tail -n1)
  echo "$(safe_number "$objs") $(safe_number "$bytes")"
}

list_p1_prefixes() {
  local base_uri="$1"
  aws s3 ls "$base_uri" | awk '/ PRE /{print $2}'
}

gate() {  # gate <limit>
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
  MODE="BASE=${BASE}"
else
  SRC_BASE_URI="s3://${SRC}/"
  DST_BASE_URI="s3://${DST}/"
  MODE="FULL BUCKET"
fi

echo "------------------------------------------------------------"
echo " Sync dispatcher"
echo " Source:       ${SRC_BASE_URI}"
echo " Destination:  ${DST_BASE_URI}"
echo " Mode:         ${MODE}"
echo " Logs:         ${LOG_DIR}/sync_${RUN_ID}_<pfx>.raw.log / .err.log"
echo " Master CSV:   ${MASTER_CSV}"
echo "------------------------------------------------------------"

# ---- parse flags / filter ----------------------------------------------------
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

if [[ -z "${FILTER:-}" && -t 0 && -t 1 ]]; then
  printf "Enter any part of the next-level prefix to sync (e.g., 2021, myfolder): "
  IFS= read -r FILTER || FILTER=""
  echo
fi

# ---- list candidate P1s ------------------------------------------------------
echo "[scan] Listing P1 under: ${SRC_BASE_URI}"
mapfile -t ALL_P1 < <(list_p1_prefixes "$SRC_BASE_URI")

CAND=()
for p in "${ALL_P1[@]}"; do
  p="${p%/}"
  if [[ -z "$FILTER" || "${p,,}" == *"${FILTER,,}"* ]]; then
    CAND+=("$p")
  fi
done

if ((${#CAND[@]}==0)); then
  echo "[WARN] No P1 prefixes matched filter '${FILTER}'. Exiting."
  # still create empty CSV w/header so automation doesn't choke
  echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"
  exit 0
fi

echo "[info] ${#CAND[@]} P1 candidate(s) matched filter '${FILTER}'"
for p in "${CAND[@]}"; do echo "  - $p"; done
echo

# ---- peek counts on SRC & classify ------------------------------------------
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

  if   (( cnt < 10 ));     then LIGHT+=("$p"); PCLASS["$p"]="LIGHT"
  elif (( cnt > 150 ));    then HEAVY+=("$p"); PCLASS["$p"]="HEAVY"
  else                          MED+=("$p");   PCLASS["$p"]="MEDIUM"
  fi
done

echo "[plan] heavy: ${#HEAVY[@]}  (limit ${HEAVY_CONC})"
echo "[plan] medium: ${#MED[@]}   (limit ${MED_CONC})"
echo "[plan] light: ${#LIGHT[@]}   (limit ${LIGHT_CONC})"
echo

# ---- dry-run preview ---------------------------------------------------------
if (( DRY_RUN == 1 )); then
  echo "[dry-run] Would sync per-P1 with these commands:"
  for p in "${CAND[@]}"; do
    if [[ -n "$BASE" ]]; then
      echo "  aws s3 sync s3://${SRC}/${BASE}/${p}  s3://${DST}/${BASE}/${p}  --exclude '*\$folder\$' --exact-timestamps --size-only --no-progress --only-show-errors"
    else
      echo "  aws s3 sync s3://${SRC}/${p}  s3://${DST}/${p}  --exclude '*\$folder\$' --exact-timestamps --size-only --no-progress --only-show-errors"
    fi
  done
  # header so tools can still ingest
  echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"
  exit 0
fi

# ---- init master CSV ---------------------------------------------------------
echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"

# ---- per-prefix runner (with class + pre/post deltas) ------------------------
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

  # pre-sync DST totals
  read -r dst_pre_objs dst_pre_bytes <<<"$(summarize_count_bytes "$dst_uri")"

  echo "[run ] ${p1} (${class}) -> ${dst_uri}" | tee -a "$raw_log"

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

  # post-sync DST totals and delta
  read -r dst_post_objs dst_post_bytes <<<"$(summarize_count_bytes "$dst_uri")"
  local copied_objs=$(( dst_post_objs - dst_pre_objs ))
  local copied_bytes=$(( dst_post_bytes - dst_pre_bytes ))

  if (( rc == 0 )); then
    if (( copied_objs > 0 || copied_bytes > 0 )); then
      echo "[done] ${p1}  copied: ${copied_objs} objs ($(human_bytes "$copied_bytes"))" | tee -a "$raw_log"
    else
      echo "[done] ${p1}  already up-to-date" | tee -a "$raw_log"
    fi
  else
    echo "[FAIL] ${p1} (rc=${rc}) — see ${err_log}" | tee -a "$raw_log"
  fi

  # store per-prefix delta for aggregation & for master CSV
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

# ---- run queues --------------------------------------------------------------
echo "[run ] Dispatching HEAVY queue..."
for p in "${HEAVY[@]}"; do gate "$HEAVY_CONC"; run_one_prefix "$p" "HEAVY" </dev/null & done
wait
for p in "${HEAVY[@]}"; do aggregate_delta_csv "$LOG_DIR/sync_${RUN_ID}_${p//\//__}.delta.csv"; done

echo "[run ] Dispatching MEDIUM queue..."
for p in "${MED[@]}"; do gate "$MED_CONC"; run_one_prefix "$p" "MEDIUM" </dev/null & done
wait
for p in "${MED[@]}"; do aggregate_delta_csv "$LOG_DIR/sync_${RUN_ID}_${p//\//__}.delta.csv"; done

echo "[run ] Dispatching LIGHT queue..."
for p in "${LIGHT[@]}"; do gate "$LIGHT_CONC"; run_one_prefix "$p" "LIGHT" </dev/null & done
wait
for p in "${LIGHT[@]}"; do aggregate_delta_csv "$LOG_DIR/sync_${RUN_ID}_${p//\//__}.delta.csv"; done

# ---- summary ----------------------------------------------------------------
read -r BUCKET_TOTAL_OBJS BUCKET_TOTAL_BYTES <<<"$(summarize_count_bytes "$SRC_BASE_URI")"
END_TS="$(date +%s)"
ELAPSED=$(( END_TS - START_TS ))

echo
echo "==================== Summary (RUN ${RUN_ID}) ===================="
printf " Bucket/Base total (SRC):   %12d  (%s)\n" \
       "$BUCKET_TOTAL_OBJS" "$(human_bytes "$BUCKET_TOTAL_BYTES")"
printf " Selected P1s total (SRC):  %12d  (%s)\n" \
       "$TOTAL_SELECTED_OBJS" "$(human_bytes "$TOTAL_SELECTED_BYTES")"
echo
printf " Total copied (DST delta):  %12d  (%s)\n" \
       "$TOTAL_COPIED_OBJS" "$(human_bytes "$TOTAL_COPIED_BYTES")"
printf " Already up-to-date P1s:    %12d  / %d\n" \
       "$ALREADY_UP_TO_DATE" "${#CAND[@]}"
echo
printf " Jobs dispatched:  heavy=%d  medium=%d  light=%d\n" \
       "${#HEAVY[@]}" "${#MED[@]}" "${#LIGHT[@]}"
printf " Concurrency:     heavy=%d  medium=%d  light=%d\n" \
       "$HEAVY_CONC" "$MED_CONC" "$LIGHT_CONC"
echo " Elapsed:          ${ELAPSED}s"
echo " Logs:             ${LOG_DIR}/sync_${RUN_ID}_<pfx>.raw.log  (+ .err.log)"
echo " Master CSV:       ${MASTER_CSV}"
echo "==============================================================="
