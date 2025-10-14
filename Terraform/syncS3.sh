#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# syncs3.sh (post-counts only)
# - Runs aws s3 sync via vault_keepalive.sh
# - BASE optional: blank => full-bucket sync
# - Per-minute progress CSV (bytes) + objects/min CSV (from "copy:" lines)
# - Pretty, colored speedometer: shows MB/s + objs/min, prints only on new data
# - Object-level failure CSV + prefix breakdown
# - Excludes legacy $folder$ markers by default
# -----------------------------------------------------------------------------

LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
FULL_LOG="$LOG_DIR/sync_${RUN_ID}.log"
ERR_LOG="$LOG_DIR/sync_${RUN_ID}.err.log"
SUM_LOG="$LOG_DIR/sync_${RUN_ID}.summary.txt"
PROG_CSV="$LOG_DIR/sync_${RUN_ID}.progress.csv"            # bytes/minute
SYNC_RAW_LOG="$LOG_DIR/sync_${RUN_ID}.raw.log"             # raw stdout from sync (copy: lines)
COPIES_CSV="$LOG_DIR/sync_${RUN_ID}.copies_per_min.csv"    # objects/minute
FAIL_CSV="$LOG_DIR/sync_${RUN_ID}.failures.csv"
FAIL_KEYS="$LOG_DIR/sync_${RUN_ID}.failkeys.txt"
FAIL_PREFIX="$LOG_DIR/sync_${RUN_ID}.failprefix.txt"

# Log this script's stdout/stderr to files + console
exec > >(tee -a "$FULL_LOG") 2> >(tee -a "$ERR_LOG" >&2)
echo "[init] Logs -> full=$FULL_LOG  errors=$ERR_LOG  progress=$PROG_CSV  copies=$COPIES_CSV  failures=$FAIL_CSV"

# --- Source helper (sets AWS tuning + SRC/DST/BASE) --------------------------
if [[ ! -f ./awshelper.sh ]]; then
  echo "ERROR: awshelper.sh not found" >&2; exit 1
fi
# shellcheck disable=SC1091
source ./awshelper.sh

# Only SRC/DST are required. BASE optional (blank => whole bucket).
if [[ -z "${SRC:-}" || -z "${DST:-}" ]]; then
  echo "ERROR: SRC/DST must be set (in awshelper.sh or here)" >&2
  exit 1
fi

# Normalize inputs to avoid s3://bucket//prefix
trim_slashes() { local s="${1:-}"; s="${s#/}"; s="${s%/}"; echo "$s"; }
SRC="$(trim_slashes "$SRC")"
DST="$(trim_slashes "$DST")"
BASE="$(trim_slashes "${BASE:-}")"

# Build URIs with/without BASE
if [[ -n "${BASE:-}" ]]; then
  SRC_URI="s3://${SRC}/${BASE}"
  DST_URI="s3://${DST}/${BASE}"
  echo "[init] Mode: prefix sync (${BASE})"
else
  SRC_URI="s3://${SRC}"
  DST_URI="s3://${DST}"
  echo "[init] Mode: FULL BUCKET sync"
fi
echo "[init] Source      : $SRC_URI"
echo "[init] Destination : $DST_URI"

# Helpful AWS envs
export AWS_PAGER=""
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"
export COLOR="${COLOR:-1}"

# --- Helpers -----------------------------------------------------------------
have_timeout=1; command -v timeout >/dev/null 2>&1 || have_timeout=0
COUNT_TIMEOUT="${COUNT_TIMEOUT:-10m}"

_run_with_timeout() { local to="$1"; shift; if [[ $have_timeout -eq 1 ]]; then timeout "$to" "$@"; else "$@"; fi; }

_safe_ls_summary() {
  local uri="$1" out rc
  set +e
  out=$(_run_with_timeout "$COUNT_TIMEOUT" aws s3 ls "$uri" --recursive --summarize 2>&1)
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "[post] WARN: ls failed for $uri (rc=$rc): ${out//$'\n'/ }" >&2
    echo ""
  else
    echo "$out"
  fi
}

_safe_number() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

safe_total_bytes() {
  local out b; out="$(_safe_ls_summary "$1")"
  b=$(awk '/Total Size:/ {print $3}' <<<"$out" | tail -n1)
  _safe_number "${b:-0}"
}

safe_obj_count() {
  local out n; out="$(_safe_ls_summary "$1")"
  n=$(awk '/Total Objects:/ {print $3}' <<<"$out" | tail -n1)
  _safe_number "${n:-0}"
}

human_bytes() {
  local b="$(_safe_number "${1:-0}")"
  awk -v b="$b" 'function f(x,u){printf "%.2f %s", x, u}
    b<1024{f(b,"B");exit}
    b<1048576{f(b/1024,"KB");exit}
    b<1073741824{f(b/1048576,"MB");exit}
    b<1099511627776{f(b/1073741824,"GB");exit}
    {f(b/1099511627776,"TB")}'
}

colorize() {
  if [[ "${COLOR:-0}" -ne 1 ]]; then echo "$2"; return; fi
  local rate="$1" text="$2" g y r z
  g="$(tput setaf 2 2>/dev/null || true)"
  y="$(tput setaf 3 2>/dev/null || true)"
  r="$(tput setaf 1 2>/dev/null || true)"
  z="$(tput sgr0 2>/dev/null || true)"
  awk -v r="$rate" -v g="$g" -v y="$y" -v d="$r" -v z="$z" -v t="$text" '
    BEGIN{
      if (r+0>8) printf "%s%s%s\n", g,t,z;
      else if (r+0>=1) printf "%s%s%s\n", y,t,z;
      else printf "%s%s%s\n", d,t,z;
    }'
}

# --- CSVs --------------------------------------------------------------------
echo "timestamp,total_bytes,delta_bytes,mb_per_sec" >"$PROG_CSV"
echo "timestamp,copies" > "$COPIES_CSV"
: > "$SYNC_RAW_LOG"   # ensure file exists for tail

# Bytes/min via listing (may be >60s on big trees)
progress_loop() {
  local prev_bytes prev_ts now_bytes now_ts delta_b delta_s mbps
  prev_bytes="$(safe_total_bytes "$DST_URI")"
  prev_ts="$(date +%s)"
  printf "%s,%s,0,0.000\n" "$(date -Iseconds)" "$prev_bytes" >>"$PROG_CSV"
  while kill -0 "$SYNC_PID" 2>/dev/null; do
    sleep 60
    now_bytes="$(safe_total_bytes "$DST_URI")"
    now_ts="$(date +%s)"
    delta_b=$(( now_bytes - prev_bytes )); (( delta_b < 0 )) && delta_b=0
    delta_s=$(( now_ts - prev_ts )); (( delta_s <= 0 )) && delta_s=1
    mbps=$(awk -v b="$delta_b" -v s="$delta_s" 'BEGIN{printf "%.3f", (b/1048576)/s}')
    printf "%s,%s,%s,%s\n" "$(date -Iseconds)" "$now_bytes" "$delta_b" "$mbps" >>"$PROG_CSV"
    prev_bytes="$now_bytes"; prev_ts="$now_ts"
  done
}

# Objects/min from "copy:" lines (silent; reads SYNC_RAW_LOG)
copies_counter_loop() {
  local last_ts=$(date +%s) count=0 line
  # tail -F prints new lines as they arrive; quiet if none
  tail -n0 -F "$SYNC_RAW_LOG" 2>/dev/null | while read -r line; do
    [[ "$line" == copy:* ]] && ((count++))
    local now=$(date +%s)
    if (( now - last_ts >= 60 )); then
      printf "%s,%d\n" "$(date -Iseconds)" "$count" >> "$COPIES_CSV"
      count=0; last_ts=$now
    fi
  done
}

# Pretty, non-duplicate speedometer
display_speedometer() {
  local last_ts_printed="" last_copies="0"
  while kill -0 "$SYNC_PID" 2>/dev/null; do
    if (( $(wc -l < "$PROG_CSV") > 1 )); then
      IFS=',' read -r ts total delta rate < <(tail -n1 "$PROG_CSV")
      ts=${ts%$'\r'}; total=${total%$'\r'}; delta=${delta%$'\r'}; rate=${rate%$'\r'}
      if [[ "$ts" != "$last_ts_printed" ]]; then
        last_ts_printed="$ts"
        # latest copies-per-minute (if any yet)
        if (( $(wc -l < "$COPIES_CSV") > 1 )); then
          IFS=',' read -r _ts_c _copies < <(tail -n1 "$COPIES_CSV")
          [[ $_copies =~ ^[0-9]+$ ]] && last_copies="$_copies" || last_copies="0"
        fi
        # Pretty + hardened numbers
        ts_fmt="$(date -d "$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ts")"
        [[ $total =~ ^[0-9]+$ ]] || total=0
        [[ $delta =~ ^[0-9]+$ ]] || delta=0
        [[ $rate  =~ ^[0-9.]+$ ]] || rate=0
        local line_fmt
        line_fmt=$(printf "[rate] %s  %s total  Δ %s  (%.3f MB/s)  [%s objs/min]" \
          "$ts_fmt" "$(human_bytes "$total")" "$(human_bytes "$delta")" "$rate" "$last_copies")
        if (( $(printf '%.0f' "$rate") == 0 )); then
          line_fmt="$line_fmt  (scanning)"
        fi
        colorize "$rate" "$line_fmt"
      fi
    fi
    sleep 15
  done
}

# --- Run the sync via vault_keepalive ---------------------------------------
start_ts=$(date +%s)
echo "[run ] Starting sync at $(date -d @"$start_ts" "+%F %T" 2>/dev/null || date)"

set +e

# Note: forward stdout through a tee → raw log AND to console,
# but filter out noisy "copy:" lines so terminal isn't spammed.
# Keep stderr in ERR_LOG.
command -v stdbuf >/dev/null || stdbuf() { "$@"; }  # fallback if stdbuf not present

./vault_keepalive.sh aws s3 sync "$SRC_URI" "$DST_URI" \
  --exclude "*\$folder\$" \
  --exact-timestamps --size-only --no-progress \
  > >(stdbuf -oL tee -a "$SYNC_RAW_LOG" | stdbuf -oL grep --line-buffered -v '^copy:') \
  2>>"$ERR_LOG" &

SYNC_PID=$!


# Background helpers
progress_loop &            PROG_PID=$!
copies_counter_loop &      COPIES_PID=$!
display_speedometer &      SPEED_PID=$!

wait "$SYNC_PID"
sync_rc=$?
kill "$PROG_PID" "$COPIES_PID" "$SPEED_PID" 2>/dev/null || true
set -e
end_ts=$(date +%s)

# --- Post-run counts ---------------------------------------------------------
echo "[post] Collecting post-sync counts..."
src_after_objs="$(safe_obj_count "$SRC_URI")"
dst_after_objs="$(safe_obj_count "$DST_URI")"
echo "[post] Source objs (post): $src_after_objs"
echo "[post] Dest objs   (post): $dst_after_objs"

# --- Failure parsing ---------------------------------------------------------
: >"$FAIL_KEYS"
if [[ -s "$ERR_LOG" ]]; then
  grep -Eo "s3://[^ ]+" "$ERR_LOG" \
    | grep -E "s3://${SRC}/|s3://${DST}/" \
    | sort -u >"$FAIL_KEYS" || true
fi
fail_count=0; [[ -s "$FAIL_KEYS" ]] && fail_count=$(wc -l <"$FAIL_KEYS" | tr -d ' ')

echo "key,error" >"$FAIL_CSV"
if (( fail_count > 0 )); then
  while IFS= read -r uri; do
    err_line="$(grep -F "$uri" "$ERR_LOG" | head -n1 | sed 's/"/'\''/g')"
    printf "\"%s\",\"%s\"\n" "$uri" "$err_line" >>"$FAIL_CSV"
  done <"$FAIL_KEYS"
fi

# --- Summary -----------------------------------------------------------------
duration=$(( end_ts - start_ts ))
{
  echo "Run ID:            $RUN_ID"
  echo "Started:           $(date -d @"$start_ts" "+%F %T" 2>/dev/null || date -r "$start_ts")"
  echo "Finished:          $(date -d @"$end_ts"   "+%F %T" 2>/dev/null || date -r "$end_ts")"
  echo "Duration (s):      $duration"
  echo "Source:            $SRC_URI"
  echo "Destination:       $DST_URI"
  echo
  echo "Source objects (post):       $src_after_objs"
  echo "Destination objects (post):  $dst_after_objs"
  echo "Failures (unique keys):      $fail_count"
  echo
  echo "Progress CSV (bytes/min):    $PROG_CSV"
  echo "Copies CSV (objs/min):       $COPIES_CSV"
  echo "Raw sync log (copy lines):   $SYNC_RAW_LOG"
  echo "Full log:                    $FULL_LOG"
  echo "Error log:                   $ERR_LOG"
  if (( fail_count > 0 )); then
    echo "Failure breakdown:           $FAIL_PREFIX"
  fi
  echo
  echo "Exit code from sync: $sync_rc"
} | tee "$SUM_LOG"

exit "$sync_rc"
