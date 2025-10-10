cat > syncs3.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# syncs3.sh
# Purpose:
#   Long-running S3 sync wrapped with vault_keepalive.sh.
#   Provides:
#     - per-minute progress CSV (timestamp,total_bytes,delta_bytes,mb_per_sec)
#     - live console speedometer (optionally colored; enable with COLOR=1)
#     - object-level failure CSV (key,error)
#     - failure prefix breakdown
#     - end-of-run summary
#
# Requires (in same dir):
#   - awshelper.sh         (sets AWS tuning, and SRC/DST/BASE vars)
#   - vault_keepalive.sh   (keeps Vault token + lease alive via .vault_creds.env)
#   - .vault_creds.env     (used by vault_keepalive.sh)
#
# Outputs (default LOG_DIR=./logs):
#   - sync_<id>.log            (full stdout)
#   - sync_<id>.err.log        (stderr/errors)
#   - sync_<id>.progress.csv   (per-minute progress)
#   - sync_<id>.failures.csv   (object-level failures)
#   - sync_<id>.failkeys.txt   (unique failed URIs; helper)
#   - sync_<id>.failprefix.txt (failures grouped by prefix)
#   - sync_<id>.summary.txt    (final summary)
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

# Log everything from this script
exec > >(tee -a "$FULL_LOG") 2> >(tee -a "$ERR_LOG" >&2)
echo "[init] Logs -> full=$FULL_LOG  errors=$ERR_LOG  progress=$PROG_CSV  failures=$FAIL_CSV"

# --- Source helper (sets AWS tuning + SRC/DST/BASE) --------------------------
if [[ ! -f ./awshelper.sh ]]; then
  echo "ERROR: awshelper.sh not found" >&2; exit 1
fi
# shellcheck disable=SC1091
source ./awshelper.sh

if [[ -z "${SRC:-}" || -z "${DST:-}" || -z "${BASE:-}" ]]; then
  echo "ERROR: SRC/DST/BASE must be set (in awshelper.sh or here)" >&2
  exit 1
fi

SRC_URI="s3://${SRC}/${BASE}"
DST_URI="s3://${DST}/${BASE}"
echo "[init] Source      : $SRC_URI"
echo "[init] Destination : $DST_URI"

# Helpful AWS envs (resiliency)
export AWS_PAGER=""
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

# --- Helpers -----------------------------------------------------------------
have_timeout=1; command -v timeout >/dev/null 2>&1 || have_timeout=0
COUNT_TIMEOUT="${COUNT_TIMEOUT:-15m}"

_run_with_timeout() {
  local to="$1"; shift
  if [[ $have_timeout -eq 1 ]]; then timeout "$to" "$@"; else "$@"; fi
}

_safe_ls_summary() {
  # Echos full summarize text or empty on failure (never exits script)
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

safe_total_bytes() {
  local uri="$1" out b
  out="$(_safe_ls_summary "$uri")"
  b=$(awk '/Total Size:/ {print $3}' <<<"$out" | tail -n1)
  [[ -z "$b" ]] && b=0
  echo "$b"
}

safe_obj_count() {
  local uri="$1" out n
  out="$(_safe_ls_summary "$uri")"
  n=$(awk '/Total Objects:/ {print $3}' <<<"$out" | tail -n1)
  [[ -z "$n" ]] && n=0
  echo "$n"
}

human_bytes() {
  # human_bytes <bytes>
  local b=$1
  awk -v b="$b" 'function f(x,u){printf "%.2f %s", x, u}
    b<1024{f(b,"B");exit}
    b<1048576{f(b/1024,"KB");exit}
    b<1073741824{f(b/1048576,"MB");exit}
    b<1099511627776{f(b/1073741824,"GB");exit}
    {f(b/1099511627776,"TB")}'
}

colorize() {
  # colorize <rateMBps> <string>
  if [[ "${COLOR:-0}" -ne 1 ]]; then echo "$2"; return; fi
  local rate="$1" text="$2"
  local green; local yellow; local red; local reset
  green="$(tput setaf 2 2>/dev/null || true)"; yellow="$(tput setaf 3 2>/dev/null || true)"
  red="$(tput setaf 1 2>/dev/null || true)"; reset="$(tput sgr0 2>/dev/null || true)"
  # thresholds: >8 MB/s green, 1–8 yellow, <1 red
  awk -v r="$rate" -v g="$green" -v y="$yellow" -v d="$red" -v z="$reset" -v t="$text" '
    BEGIN{
      if (r>8) printf "%s%s%s\n", g,t,z;
      else if (r>=1) printf "%s%s%s\n", y,t,z;
      else printf "%s%s%s\n", d,t,z;
    }'
}

# --- Progress CSV + speedometer (every 60s) ----------------------------------
echo "timestamp,total_bytes,delta_bytes,mb_per_sec" >"$PROG_CSV"

progress_loop() {
  local prev_bytes prev_ts now_bytes now_ts delta_b delta_s mbps
  prev_bytes="$(safe_total_bytes "$DST_URI")"
  prev_ts="$(date +%s)"
  while kill -0 "$SYNC_PID" 2>/dev/null; do
    sleep 60
    now_bytes="$(safe_total_bytes "$DST_URI")"
    now_ts="$(date +%s)"
    delta_b=$(( now_bytes - prev_bytes ))
    delta_s=$(( now_ts - prev_ts ))
    if (( delta_b >= 0 && delta_s > 0 )); then
      mbps=$(awk -v b="$delta_b" -v s="$delta_s" 'BEGIN{printf "%.3f", (b/1048576)/s}')
      printf "%s,%s,%s,%s\n" "$(date -Iseconds)" "$now_bytes" "$delta_b" "$mbps" | tee -a "$PROG_CSV" >/dev/null
    fi
    prev_bytes="$now_bytes"
    prev_ts="$now_ts"
  done
}

display_speedometer() {
  while kill -0 "$SYNC_PID" 2>/dev/null; do
    if [[ -s "$PROG_CSV" ]]; then
      local line ts total delta rate line_fmt
      line="$(tail -n1 "$PROG_CSV")"
      ts="$(cut -d',' -f1 <<<"$line")"
      total="$(cut -d',' -f2 <<<"$line")"
      delta="$(cut -d',' -f3 <<<"$line")"
      rate="$(cut -d',' -f4 <<<"$line")"
      line_fmt=$(printf "[rate] %s  %s total  Δ %s  (%s MB/s)" \
        "$ts" "$(human_bytes "$total")" "$(human_bytes "$delta")" "$rate")
      colorize "$rate" "$line_fmt"
    fi
    sleep 60
  done
}

# --- Run the sync via vault_keepalive ---------------------------------------
echo "[run ] Starting sync..."
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

# --- Post-run counts (only counts we need) -----------------------------------
echo "[post] Collecting post-sync counts..."
src_after_objs="$(safe_obj_count "$SRC_URI")"
dst_after_objs="$(safe_obj_count "$DST_URI")"
echo "[post] Source objs (post): $src_after_objs"
echo "[post] Dest objs   (post): $dst_after_objs"

# --- Failure parsing ---------------------------------------------------------
: >"$FAIL_KEYS"
if [[ -s "$ERR_LOG" ]]; then
  # Extract s3:// URIs and keep only SRC/DST bucket URIs
  grep -Eo "s3://[^ ]+" "$ERR_LOG" | grep -E "s3://(${SRC}|${DST})/" | sort -u >"$FAIL_KEYS" || true
fi

fail_count=0
[[ -s "$FAIL_KEYS" ]] && fail_count=$(wc -l <"$FAIL_KEYS" | tr -d ' ')

echo "key,error" >"$FAIL_CSV"
if (( fail_count > 0 )); then
  while IFS= read -r uri; do
    err_line="$(grep -F "$uri" "$ERR_LOG" | head -n1 | sed 's/"/'\''/g')"
    printf "\"%s\",\"%s\"\n" "$uri" "$err_line" >>"$FAIL_CSV"
  done <"$FAIL_KEYS"
fi

# Group failures by prefix depth 1–3 (relative to BASE)
: >"$FAIL_PREFIX"
if (( fail_count > 0 )); then
  rel_tmp="$LOG_DIR/sync_${RUN_ID}.failkeys.rel.txt"
  awk -v src="s3://${SRC}/" -v dst="s3://${DST}/" -v base="${BASE%/}/" '
    {
      uri=$0
      sub(src,"",uri); sub(dst,"",uri)
      if (index(uri, base)==1) {
        rel=substr(uri, length(base)+2)
        if (rel != "") print rel
      } else {
        print uri
      }
    }' "$FAIL_KEYS" > "$rel_tmp"

  {
    echo "---- Failures by first-level prefix ----"
    awk -F'/' '{c[$1]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$rel_tmp" | sort -nr
    echo
    echo "---- Failures by first two levels ----"
    awk -F'/' '{k=$1; if(NF>=2) k=k"/"$2; c[k]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$rel_tmp" | sort -nr
    echo
    echo "---- Failures by first three levels ----"
    awk -F'/' '{k=$1; if(NF>=2) k=k"/"$2; if(NF>=3) k=k"/"$3; c[k]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$rel_tmp" | sort -nr
  } > "$FAIL_PREFIX"
fi

# --- Summary -----------------------------------------------------------------
duration=$(( end_ts - ${start_ts:-end_ts} ))
{
  echo "Run ID:            $RUN_ID"
  echo "Finished:          $(date -d @"$end_ts" "+%F %T" 2>/dev/null || date -r "$end_ts")"
  echo "Duration (s):      $duration"
  echo "Source:            $SRC_URI"
  echo "Destination:       $DST_URI"
  echo
  echo "Source objects (post):       $src_after_objs"
  echo "Destination objects (post):  $dst_after_objs"
  echo "Failures (unique keys):      $fail_count"
  echo
  echo "Progress CSV:  $PROG_CSV"
  echo "Failure CSV:   $FAIL_CSV"
  echo "Full log:      $FULL_LOG"
  echo "Error log:     $ERR_LOG"
  if (( fail_count > 0 )); then
    echo "Failure breakdown: $FAIL_PREFIX"
  fi
  echo
  echo "Exit code from sync: $sync_rc"
} | tee "$SUM_LOG"

exit "$sync_rc"
EOF
chmod +x syncs3.sh
