#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Purpose:
#   Run a long S3 sync wrapped by vault_keepalive.sh with robust logging
#   and a compact end-of-run summary (copied, failed, and failing prefixes).
#
# Requires:
#   - awshelper.sh (sets AWS tuning + optionally SRC/DST/BASE)
#   - vault_keepalive.sh (keeps Vault token + lease alive)
#   - .vault_creds.env (for vault_keepalive.sh)
#
# Notes:
#   - Counts use aws s3 ls --recursive --summarize.
#     This is eventually consistent; final numbers stabilize after a bit.
#   - Failures are parsed from the error log lines emitted by aws s3 sync.
# -----------------------------------------------------------------------------

# --- Config ------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-./logs}"
mkdir -p "$LOG_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
FULL_LOG="$LOG_DIR/sync_${RUN_ID}.log"
ERR_LOG="$LOG_DIR/sync_${RUN_ID}.err.log"
SUM_LOG="$LOG_DIR/sync_${RUN_ID}.summary.txt"

# Where to source AWS prefs + vars (SRC/DST/BASE etc.)
source ./awshelper.sh

# If you prefer defining here, uncomment and override:
# export SRC="in2-sdp-encore-s3-bucket-ncz"
# export DST="nc-dev-00-aog-data-sdp-s3-encore"
# export BASE="ods/parquet/ods_ofra_prod_tier_scan_range"

if [[ -z "${SRC:-}" || -z "${DST:-}" || -z "${BASE:-}" ]]; then
  echo "ERROR: SRC/DST/BASE must be set (either in awshelper.sh or here)." >&2
  exit 1
fi

SRC_URI="s3://${SRC}/${BASE}"
DST_URI="s3://${DST}/${BASE}"

echo "Run ID:      $RUN_ID"
echo "Source:      $SRC_URI"
echo "Destination: $DST_URI"
echo "Logs:        full=$FULL_LOG, errors=$ERR_LOG, summary=$SUM_LOG"
echo

# --- Pre-counts --------------------------------------------------------------
echo "[prep] Collecting pre-run object counts... (eventual consistency applies)"
src_before_objs=$(aws s3 ls "$SRC_URI" --recursive --summarize 2>/dev/null | awk '/Total Objects:/ {print $3; exit}')
src_before_objs="${src_before_objs:-0}"

dst_before_objs=$(aws s3 ls "$DST_URI" --recursive --summarize 2>/dev/null | awk '/Total Objects:/ {print $3; exit}')
dst_before_objs="${dst_before_objs:-0}"

start_ts=$(date +%s)

# --- Run the sync through the keepalive wrapper ------------------------------
echo "[run ] Starting sync via vault_keepalive.sh ..."
# We keep stdout and stderr separate so we can analyze failures.
set +e
./vault_keepalive.sh aws s3 sync "$SRC_URI" "$DST_URI" \
  --exact-timestamps \
  --size-only \
  --no-progress \
  --only-show-errors \
  > >(tee -a "$FULL_LOG") 2> >(tee -a "$ERR_LOG" >&2)
sync_rc=$?
set -e

end_ts=$(date +%s)

# --- Post-counts -------------------------------------------------------------
echo "[post] Collecting post-run object counts..."
dst_after_objs=$(aws s3 ls "$DST_URI" --recursive --summarize 2>/dev/null | awk '/Total Objects:/ {print $3; exit}')
dst_after_objs="${dst_after_objs:-0}"

# Approximate “new/updated copied” = delta at destination.
# (Existing unchanged objects won’t count; updated objects count as 1.)
delta_copied=$(( dst_after_objs - dst_before_objs ))
if [[ $delta_copied -lt 0 ]]; then delta_copied=0; fi

# --- Failure analysis (errors-only log) --------------------------------------
# Extract S3 keys mentioned in errors. We try both src and dst matches.
# This is best-effort; AWS CLI error formats vary. We focus on lines
# containing s3://<bucket>/<key>.
tmp_fail_keys="$LOG_DIR/sync_${RUN_ID}.failkeys.txt"
: > "$tmp_fail_keys"

# Pull any s3://SRC/... or s3://DST/... keys from the error log.
if [[ -s "$ERR_LOG" ]]; then
  # normalize and extract keys
  awk -v s1="s3://${SRC}/" -v s2="s3://${DST}/" '
    {
      while (match($0, /(s3:\/\/[^ ]+)/, m)) {
        uri=m[1]; gsub(/[,;:()]+$/,"",uri);     # trim trailing punct
        if (index(uri, s1)==1 || index(uri, s2)==1) print uri;
        $0=substr($0, RSTART+RLENGTH);          # advance
      }
    }' "$ERR_LOG" \
  | sort -u > "$tmp_fail_keys"
fi

# Count total failures (unique keys found)
fail_count=0
if [[ -s "$tmp_fail_keys" ]]; then
  fail_count=$(wc -l < "$tmp_fail_keys" | tr -d ' ')
fi

# Group failures by prefix depth 1–3 (relative to BASE).
# e.g., if BASE=a/b and failing key is s3://dst/a/b/c/d/e, the rel key = c/d/e.
prefix_report="$LOG_DIR/sync_${RUN_ID}.failprefix.txt"
: > "$prefix_report"

if [[ $fail_count -gt 0 ]]; then
  # get relative keys by stripping bucket and BASE/
  rel_tmp="$LOG_DIR/sync_${RUN_ID}.failkeys.rel.txt"
  awk -v src="s3://${SRC}/" -v dst="s3://${DST}/" -v base="${BASE%/}/" '
    {
      uri=$0
      sub(src,"",uri); sub(dst,"",uri)
      # uri now is like BASE/whatever or some other path
      if (index(uri, base)==1) {
        rel=substr(uri, length(base)+2)  # skip "base/" (add 1) and 1-based index
        if (rel != "") print rel
      } else {
        # keys outside BASE (should be rare), still print something
        print uri
      }
    }' "$tmp_fail_keys" > "$rel_tmp"

  # Depth aggregations
  {
    echo "---- Failures by first-level prefix ----"
    awk -F'/' '{c[$1]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$rel_tmp" | sort -nr
    echo
    echo "---- Failures by first two levels ----"
    awk -F'/' '{k=$1; if(NF>=2) k=k"/"$2; c[k]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$rel_tmp" | sort -nr
    echo
    echo "---- Failures by first three levels ----"
    awk -F'/' '{k=$1; if(NF>=2) k=k"/"$2; if(NF>=3) k=k"/"$3; c[k]++} END{for(k in c) printf "%8d  %s\n", c[k], k}' "$rel_tmp" | sort -nr
  } > "$prefix_report"
fi

# --- Write summary ------------------------------------------------------------
duration=$(( end_ts - start_ts ))
{
  echo "Run ID:            $RUN_ID"
  echo "Started:           $(date -d @"$start_ts" "+%F %T" 2>/dev/null || date -r "$start_ts")"
  echo "Finished:          $(date -d @"$end_ts"   "+%F %T" 2>/dev/null || date -r "$end_ts")"
  echo "Duration (s):      $duration"
  echo "Source:            $SRC_URI"
  echo "Destination:       $DST_URI"
  echo
  echo "Source objects (pre):        $src_before_objs"
  echo "Dest objects (pre):          $dst_before_objs"
  echo "Dest objects (post):         $dst_after_objs"
  echo "New/updated objects copied:  $delta_copied"
  echo "Failures (unique keys):      $fail_count"
  echo
  echo "Full log:    $FULL_LOG"
  echo "Error log:   $ERR_LOG"
  if [[ $fail_count -gt 0 ]]; then
    echo "Failure breakdown: $prefix_report"
  fi
  echo
  echo "Exit code from sync: $sync_rc"
} | tee "$SUM_LOG"

# If there were failures, show a short on-screen breakdown (top 20 lines each)
if [[ $fail_count -gt 0 ]]; then
  echo
  echo "---- Failure breakdown (top lines) ----"
  head -n 20 "$prefix_report" || true
fi

# Propagate the sync exit code so pipelines/automation can react
exit "$sync_rc"
