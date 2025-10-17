#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# syncs3.sh (v5) — per-P1 dispatcher with background jobs
# ------------------------------------------------------------------------------
# Requires:
#   - ./awshelper.sh   -> exports SRC, DST, optional BASE
#   - ./vault_keepalive.sh (wrapper that keeps Vault token/lease alive)
#
# Behavior:
#   - Prompts (or --filter / COMPARE_FILTER) for substring to match P1 prefixes
#   - Peeks object count per P1 on SOURCE
#       < 10   -> light queue (fast; high concurrency)
#       10-150 -> medium queue
#       > 150  -> heavy queue (concurrency 5)
#   - One sync per P1: s3://SRC/(BASE/)<P1> -> s3://DST/(BASE/)<P1>
#   - Logs per-prefix into ./logs
#   - Summary: total objects in bucket/base, and sum over selected P1s
# ------------------------------------------------------------------------------

# ---- knobs (you can override via env) ----------------------------------------
LOG_DIR="${LOG_DIR:-./logs}"
LIGHT_CONC="${LIGHT_CONC:-10}"
MED_CONC="${MED_CONC:-3}"
HEAVY_CONC="${HEAVY_CONC:-5}"  # as requested
EXTRA_SYNC_ARGS="${EXTRA_SYNC_ARGS:-}"  # allow site-specific flags

mkdir -p "$LOG_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
SELF_PID="$$"
START_TS="$(date +%s)"

# ---- colors (best-effort) ----------------------------------------------------
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

safe_number() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

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
  out=$(aws s3 ls "$uri" --recursive --summarize 2>"$LOG_DIR/.peek_err_${RUN_ID}.tmp")
  rc=$?
  set -e
  if (( rc != 0 )); then
    echo "[WARN] peek failed for $uri; treating as 0. Details in $LOG_DIR/.peek_err_${RUN_ID}.tmp" >&2
    echo "0 0"; return
  fi
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

run_one_prefix() {
  local p1="$1"
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

  echo "[run ] ${p1}  ->  ${dst_uri}" | tee -a "$raw_log"

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
  if (( rc == 0 )); then
    echo "[done] ${p1}" | tee -a "$raw_log"
  else
    echo "[FAIL] ${p1} (rc=${rc}) — see ${err_log}" | tee -a "$raw_log"
  fi
  return $rc
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
echo "------------------------------------------------------------"

# ---- filter parsing (flag, env, prompt fallback) -----------------------------
FILTER="${COMPARE_FILTER:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)      FILTER="${2:-}"; shift 2 ;;
    --filter=*)    FILTER="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

if [[ -z "${FILTER:-}" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    printf "Enter any part of the next-level prefix to sync (e.g., 2021, myfolder): "
    IFS= read -r FILTER || FILTER=""
    echo
  else
    FILTER=""
  fi
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
  exit 0
fi

echo "[info] ${#CAND[@]} P1 candidate(s) matched filter '${FILTER}'"
for p in "${CAND[@]}"; do echo "  - $p"; done
echo

# ---- peek counts and classify ------------------------------------------------
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
  (( TOTAL_SELECTED_OBJS += cnt ))
  (( TOTAL_SELECTED_BYTES += bytes ))

  if   (( cnt < 10 ));     then LIGHT+=("$p")
  elif (( cnt > 150 ));    then HEAVY+=("$p")
  else                          MED+=("$p")
  fi
done

echo "[plan] heavy: ${#HEAVY[@]}  (limit ${HEAVY_CONC})"
echo "[plan] medium: ${#MED[@]}   (limit ${MED_CONC})"
echo "[plan] light: ${#LIGHT[@]}   (limit ${LIGHT_CONC})"
echo

# ---- run jobs ---------------------------------------------------------------
echo "[run ] Dispatching HEAVY queue..."
for p in "${HEAVY[@]}"; do
  gate "$HEAVY_CONC"
  run_one_prefix "$p" </dev/null &
done
wait

echo "[run ] Dispatching MEDIUM queue..."
for p in "${MED[@]}"; do
  gate "$MED_CONC"
  run_one_prefix "$p" </dev/null &
done
wait

echo "[run ] Dispatching LIGHT queue..."
for p in "${LIGHT[@]}"; do
  gate "$LIGHT_CONC"
  run_one_prefix "$p" </dev/null &
done
wait

# ---- summary ----------------------------------------------------------------
BUCKET_TOTAL_OBJS=0
BUCKET_TOTAL_BYTES=0
read -r BUCKET_TOTAL_OBJS BUCKET_TOTAL_BYTES <<<"$(summarize_count_bytes "$SRC_BASE_URI")"

END_TS="$(date +%s)"
ELAPSED=$(( END_TS - START_TS ))

echo
echo "==================== Summary (RUN ${RUN_ID}) ===================="
printf " Bucket/Base total (SRC):  %12d  (%s)\n" \
       "$BUCKET_TOTAL_OBJS" "$(human_bytes "$BUCKET_TOTAL_BYTES")"
printf " Selected P1s total (SRC): %12d  (%s)\n" \
       "$TOTAL_SELECTED_OBJS" "$(human_bytes "$TOTAL_SELECTED_BYTES")"
echo
printf " Jobs dispatched:  heavy=%d  medium=%d  light=%d\n" \
       "${#HEAVY[@]}" "${#MED[@]}" "${#LIGHT[@]}"
printf " Concurrency:     heavy=%d  medium=%d  light=%d\n" \
       "$HEAVY_CONC" "$MED_CONC" "$LIGHT_CONC"
echo " Elapsed:          ${ELAPSED}s"
echo " Logs:             ${LOG_DIR}/sync_${RUN_ID}_<pfx>.raw.log  (+ .err.log)"
echo "==============================================================="
