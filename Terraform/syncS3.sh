#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# syncs3.sh
# Purpose:
#   Long-running S3 sync wrapped with vault_keepalive.sh.
#   Provides:
#     - live rate tracker (prints every 60s)
#     - progress CSV (timestamp,total_bytes,delta_bytes,mb_per_sec)
#     - object-level failure CSV (key,error)
#     - failure prefix breakdown + summary
#
# Requires: awshelper.sh, vault_keepalive.sh, .vault_creds.env
# -----------------------------------------------------------------------------

LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
FULL_LOG="$LOG_DIR/sync_${RUN_ID}.log"
ERR_LOG="$LOG_DIR/sync_${RUN_ID}.err.log"
SUM_LOG="$LOG_DIR/sync_${RUN_ID}.summary.txt"
PROG_CSV="$LOG_DIR/sync_${RUN_ID}.progress.csv"
FAIL_CSV="$LOG_DIR/sync_${RUN_ID}.failures.csv"
FAIL_KEYS="$LOG_DIR/sync_${RUN_ID}.failkeys.txt"
FAIL_PREFIX="$LOG_DIR/sync_${RUN_ID}.failprefix.txt"

exec > >(tee -a "$FULL_LOG") 2> >(tee -a "$ERR_LOG" >&2)

echo "[init] Logs: $LOG_DIR"
echo "  full=$FULL_LOG"
echo "  errors=$ERR_LOG"
echo "  progress=$PROG_CSV"
echo "  failures=$FAIL_CSV"

# --- Source helper -----------------------------------------------------------
source ./awshelper.sh

if [[ -z "${SRC:-}" || -z "${DST:-}" || -z "${BASE:-}" ]]; then
  echo "ERROR: SRC/DST/BASE must be set (in awshelper.sh or here)" >&2
  exit 1
fi

SRC_URI="s3://${SRC}/${BASE}"
DST_URI="s3://${DST}/${BASE}"

export AWS_PAGER=""
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=10

# --- Helpers -----------------------------------------------------------------
safe_total_bytes() {
  local uri="$1"
  aws s3 ls "$uri" --recursive --summarize 2>/dev/null |
    awk '/Total Size:/ {print $3}' | tail -n1 | tr -d '\r' || echo 0
}

safe_obj_count() {
  local uri="$1"
  aws s3 ls "$uri" --recursive --summarize 2>/dev/null |
    awk '/Total Objects:/ {print $3}' | tail -n1 | tr -d '\r' || echo 0
}

# --- Pre-counts --------------------------------------------------------------
echo "[prep] Collecting pre-run counts..."
src_before_objs=$(safe_obj_count "$SRC_URI")
dst_before_objs=$(safe_obj_count "$DST_URI")
echo "[prep] Source objs: $src_before_objs  Dest objs: $dst_before_objs"
start_ts=$(date +%s)

# --- Progress CSV ------------------------------------------------------------
echo "timestamp,total_bytes,delta_bytes,mb_per_sec" >"$PROG_CSV"

progress_loop() {
  local prev_bytes prev_ts now_bytes now_ts delta_b delta_s mbps
  prev_bytes=$(safe_total_bytes "$DST_URI")
  prev_ts=$(date +%s)
  while kill -0 "$SYNC_PID" 2>/dev/null; do
    sleep 60
    now_bytes=$(safe_total_bytes "$DST_URI")
    now_ts=$(date +%s)
    delta_b=$((now_bytes - prev_bytes))
    delta_s=$((now_ts - prev_ts))
    if ((delta_b >= 0 && delta_s > 0)); then
      mbps=$(awk -v b="$delta_b" -v s="$delta_s" 'BEGIN{printf "%.2f", (b/1048576)/s}')
      printf "%s,%s,%s,%s\n" "$(date -Iseconds)" "$now_bytes" "$delta_b" "$mbps" | tee -a "$PROG_CSV" >/dev/null
    fi
    prev_bytes=$now_bytes
    prev_ts=$now_ts
  done
}

# --- Live console speedometer ------------------------------------------------
display_speedometer() {
  while kill -0 "$SYNC_PID" 2>/dev/null; do
    if [[ -s "$PROG_CSV" ]]; then
      line=$(tail -n1 "$PROG_CSV")
      ts=$(cut -d',' -f1 <<<"$line")
      total=$(cut -d',' -f2 <<<"$line")
      delta=$(cut -d',' -f3 <<<"$line")
      rate=$(cut -d',' -f4 <<<"$line")
      printf "[rate] %s  %'d bytes total  Δ %'d  (%.2f MB/s)\n" "$ts" "$total" "$delta" "$rate"
    fi
    sleep 60
  done
}

# --- Run sync via vault_keepalive -------------------------------------------
echo "[run] Starting sync ..."
set +e
./vault_keepalive.sh aws s3 sync "$SRC_URI" "$DST_URI" \
  --exact-timestamps --size-only --no-progress --only-show-errors &
SYNC_PID=$!
progress_loop &
PROG_PID=$!
display_speedometer &
SPEED_PID=$!

wait "$SYNC_PID"
sync_rc=$?
kill "$PROG_PID" "$SPEED_PID" 2>/dev/null || true
set -e
end_ts=$(date +%s)

# --- Post-counts -------------------------------------------------------------
dst_after_objs=$(safe_obj_count "$DST_URI")
delta_copied=$((dst_after_objs - dst_before_objs))
((delta_copied < 0)) && delta_copied=0

# --- Failure parsing ---------------------------------------------------------
: >"$FAIL_KEYS"
if [[ -s "$ERR_LOG" ]]; then
  grep -Eo "s3://[^ ]+" "$ERR_LOG" | grep -E "s3://($SRC|$DST)/" | sort -u >"$FAIL_KEYS"
fi
fail_count=0
[[ -s "$FAIL_KEYS" ]] && fail_count=$(wc -l <"$FAIL_KEYS" | tr -d ' ')

echo "key,error" >"$FAIL_CSV"
if ((fail_count > 0)); then
  while IFS= read -r uri; do
    err_line=$(grep -F "$uri" "$ERR_LOG" | head -n1 | sed 's/"/'\''/g')
    printf "\"%s\",\"%s\"\n" "$uri" "$err_line" >>"$FAIL_CSV"
  done <"$FAIL_KEYS"
fi

# --- Summary -----------------------------------------------------------------
duration=$((end_ts - start_ts))
{
  echo "Run ID: $RUN_ID"
  echo "Started: $(date -d @"$start_ts" '+%F %T' 2>/dev/null || date -r "$start_ts")"
  echo "Finished: $(date -d @"$end_ts" '+%F %T' 2>/dev/null || date -r "$end_ts")"
  echo "Duration (s): $duration"
  echo "Source: $SRC_URI"
  echo "Destination: $DST_URI"
  echo
  echo "Source objs (pre): $src_before_objs"
  echo "Dest objs (pre):   $dst_before_objs"
  echo "Dest objs (post):  $dst_after_objs"
  echo "Copied/updated:    $delta_copied"
  echo "Failures:          $fail_count"
  echo
  echo "Progress CSV: $PROG_CSV"
  echo "Failure CSV:  $FAIL_CSV"
  echo "Logs: $FULL_LOG, $ERR_LOG"
  echo "Exit code: $sync_rc"
} | tee "$SUM_LOG"

exit "$sync_rc"
