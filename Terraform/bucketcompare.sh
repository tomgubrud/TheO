#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# bucket_compare.sh
# ------------------------------------------------------------------------------
# Compares object COUNTS and BYTES for next-level prefixes between two S3 buckets.
# - Sources ./awshelper.sh (sets SRC, DST, optional BASE)
# - Prompts for a substring to match prefixes
# - One background job per prefix (concurrency-capped)
# - Colored output, CSV, human log
# - Optional per-prefix key diffs:
#     * Missing in DST (SRC − DST)  -> missing_keys_<RUN_ID>_<PID>.log
#     * Extras in DST  (DST − SRC)  -> extra_keys_<RUN_ID>_<PID>.log
# ------------------------------------------------------------------------------

# --- config -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-./logs}"
CONCURRENCY="${CONCURRENCY:-8}"        # 0 = unlimited
LIST_MISSING="${LIST_MISSING:-1}"      # 1 = write keys present in SRC but not in DST
LIST_EXTRAS="${LIST_EXTRAS:-1}"        # 1 = write keys present in DST but not in SRC
mkdir -p "$LOG_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
SELF_PID="$$"

CSV_FILE="$LOG_DIR/compare_${RUN_ID}_${SELF_PID}.results.csv"
LOG_FILE="$LOG_DIR/compare_${RUN_ID}_${SELF_PID}.log"
MISSING_LOG="$LOG_DIR/missing_keys_${RUN_ID}_${SELF_PID}.log"
EXTRAS_LOG="$LOG_DIR/extra_keys_${RUN_ID}_${SELF_PID}.log"

TMP_DIR="$(mktemp -d -t compare_${RUN_ID}_${SELF_PID}.XXXX)"

# --- colors -------------------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN="$(tput setaf 2 || true)"; RED="$(tput setaf 1 || true)"; YEL="$(tput setaf 3 || true)"
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
else
  GREEN=""; RED=""; YEL=""; BOLD=""; RESET=""
fi

say()  { printf "%s\n" "$*"; }
warn() { printf "%s[WARN]%s %s\n"  "$YEL" "$RESET" "$*"; }
err()  { printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*" >&2; }

# --- prerequisites ------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { err "aws CLI not found"; exit 127; }
[[ -f ./awshelper.sh ]] || { err "awshelper.sh not found"; exit 1; }
# shellcheck disable=SC1091
source ./awshelper.sh
[[ -n "${SRC:-}" && -n "${DST:-}" ]] || { err "SRC and DST must be set (awshelper.sh)"; exit 1; }

# --- utils --------------------------------------------------------------------
# A tiny screen printer that serializes writes from background jobs
SCREEN_LOCK="$TMP_DIR/.screen.lock"

print_sync() {
  local msg="$1"
  {
    flock 9
    # write directly to the user's TTY so we don't fight with redirected stdout
    printf "%s\n" "$msg" > /dev/tty
  } 9>"$SCREEN_LOCK"
}


trim_slashes() { local s="${1:-}"; s="${s#/}"; s="${s%/}"; echo "$s"; }
human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'function p(x,u){printf "%.2f %s",x,u}
    b<1024{p(b,"B");exit}
    b<1048576{p(b/1024,"KiB");exit}
    b<1073741824{p(b/1048576,"MiB");exit}
    b<1099511627776{p(b/1073741824,"GiB");exit}
    {p(b/1099511627776,"TiB")}'
}
bytes_to_gib() { awk -v b="${1:-0}" 'BEGIN{printf "%.3f", b/1073741824}'; }
safe_number()  { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

# Summarize an S3 URI: "count bytes" (or "0 0" on error, logging details).
summarize_objects_and_bytes() {
  local uri="$1" out rc objs bytes
  set +e
  out=$(aws s3 ls "$uri" --recursive --summarize 2>"$TMP_DIR/.err.$SELF_PID")
  rc=$?
  set -e
  if (( rc != 0 )); then
    warn "Failed to summarize: $uri (treating as 0). Details in $LOG_FILE"
    sed -e "s/^/[aws stderr] /" "$TMP_DIR/.err.$SELF_PID" >> "$LOG_FILE" || true
    echo "0 0"
    return
  fi
  objs=$(awk '/Total Objects:/ {print $3}' <<<"$out" | tail -n1)
  bytes=$(awk '/Total Size:/ {print $3}'   <<<"$out" | tail -n1)
  echo "$(safe_number "$objs") $(safe_number "$bytes")"
}

# Extract normalized keys (one per line) from `aws s3 ls --recursive` output.
# - Strips date/time/size columns
# - Removes leading "./" or "/" if present
# - Drops blank/CRLF lines
# - Outputs clean relative keys suitable for sort/comm
list_keys() {
  local uri="$1"
  aws s3 ls "$uri" --recursive \
  | awk 'NF>=4 { $1=""; $2=""; $3=""; sub(/^ +/, ""); print }' \
  | sed -e 's#^./##' -e 's#^/##' -e 's/\r$//' \
  | grep -v '^[[:space:]]*$'
}

# limit concurrency
bg_gate() {
  if (( CONCURRENCY > 0 )); then
    while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do sleep 0.2; done
  fi
}

# list next-level prefixes under a base uri (trailing slash)
list_next_level_prefixes() {
  local base_uri="$1"
  aws s3 ls "$base_uri" | awk '/ PRE /{print $2}'
}

# --- scope setup --------------------------------------------------------------
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

# --- header -------------------------------------------------------------------
cat <<HDR
------------------------------------------------------------
 Compare: ${SRC}  ->  ${DST}
 Mode:    ${MODE}
 CSV:     $CSV_FILE
 Log:     $LOG_FILE
 Missing: $([[ "$LIST_MISSING" = "1" ]] && echo "$MISSING_LOG" || echo "disabled")
 Extras:  $([[ "$LIST_EXTRAS"  = "1" ]] && echo "$EXTRAS_LOG"  || echo "disabled")
 Run ID:  ${RUN_ID}  (PID ${SELF_PID})
------------------------------------------------------------
HDR

# prompt for filter substring
read -rp "Enter any part of the next-level prefix to compare (e.g., 2021, myfolder): " FILTER
FILTER="${FILTER:-}"

# --- prepare outputs ----------------------------------------------------------
echo "prefix,src_count,src_bytes,dst_count,dst_bytes,match" > "$CSV_FILE"
: > "$LOG_FILE"
: > "$MISSING_LOG"
: > "$EXTRAS_LOG"

# --- build prefix list --------------------------------------------------------
say "Scanning prefixes under: ${SRC_BASE_URI}"
mapfile -t ALL_PREFIXES < <(list_next_level_prefixes "$SRC_BASE_URI")

FILTERED=()
for p in "${ALL_PREFIXES[@]}"; do
  if [[ -z "$FILTER" || "${p,,}" == *"${FILTER,,}"* ]]; then
    FILTERED+=("${p%/}")   # strip trailing slash
  fi
done

if ((${#FILTERED[@]}==0)); then
  warn "No prefixes matched filter '${FILTER}'. Nothing to compare."
  rm -rf "$TMP_DIR"
  exit 0
fi

say "Comparing ${#FILTERED[@]} prefix(es):"
for p in "${FILTERED[@]}"; do echo " - $p"; done
echo

# --- accumulators -------------------------------------------------------------
TOTAL_SRC_OBJS=0
TOTAL_DST_OBJS=0
TOTAL_SRC_BYTES=0
TOTAL_DST_BYTES=0

MISS_DST_PREFIXES=0
MISS_DST_OBJS=0
MISS_DST_BYTES=0

# --- per-prefix worker --------------------------------------------------------
compare_one_prefix() {
  local PFX="$1"
  local SRC_URI DST_URI

  if [[ -n "$BASE" ]]; then
    SRC_URI="s3://${SRC}/${BASE}/${PFX}"
    DST_URI="s3://${DST}/${BASE}/${PFX}"
  else
    SRC_URI="s3://${SRC}/${PFX}"
    DST_URI="s3://${DST}/${PFX}"
  fi

  local SRC_COUNT SRC_BYTES DST_COUNT DST_BYTES
  read -r SRC_COUNT SRC_BYTES <<<"$(summarize_objects_and_bytes "$SRC_URI")"
  read -r DST_COUNT DST_BYTES <<<"$(summarize_objects_and_bytes "$DST_URI")"

  local LINE MATCH
  if [[ "$SRC_COUNT" -eq 0 && "$DST_COUNT" -eq 0 ]]; then
    LINE="${YEL}${BOLD}[empty]${RESET} ${PFX}  SRC: ${SRC_COUNT}/$(human_bytes "$SRC_BYTES")  DST: ${DST_COUNT}/$(human_bytes "$DST_BYTES")"
    MATCH="empty"
  elif [[ "$SRC_COUNT" -eq "$DST_COUNT" && "$SRC_BYTES" -eq "$DST_BYTES" ]]; then
    LINE="${GREEN}${BOLD}[match]${RESET} ${PFX}  SRC: ${SRC_COUNT}/$(human_bytes "$SRC_BYTES")  DST: ${DST_COUNT}/$(human_bytes "$DST_BYTES")"
    MATCH="match"
  else
    LINE="${RED}${BOLD}[DIFF] ${PFX}${RESET}  SRC: ${SRC_COUNT}/$(human_bytes "$SRC_BYTES")  DST: ${DST_COUNT}/$(human_bytes "$DST_BYTES")"
    MATCH="diff"
    printf "[diff] %s  SRC=%s  DST=%s  (SRC=%s objs, %s bytes | DST=%s objs, %s bytes)\n" \
      "$PFX" "$SRC_URI" "$DST_URI" "$SRC_COUNT" "$SRC_BYTES" "$DST_COUNT" "$DST_BYTES" >> "$LOG_FILE"
  fi

  # --- Missing in DST (SRC − DST) with recheck + normalized diff ---------------
  if (( SRC_COUNT > DST_COUNT )) && [[ "$LIST_MISSING" = "1" ]]; then
    # quick recheck to avoid transient mismatch
    read -r re_dc _ <<<"$(summarize_objects_and_bytes "$DST_URI")"
    if (( SRC_COUNT > re_dc )); then
      local SAFE_PFX="${PFX//\//__}"
      local SRC_KEYS="$TMP_DIR/src_keys_${RUN_ID}_${SELF_PID}_${SAFE_PFX}.txt"
      local DST_KEYS="$TMP_DIR/dst_keys_${RUN_ID}_${SELF_PID}_${SAFE_PFX}.txt"
      local MISS_KEYS="$TMP_DIR/miss_keys_${RUN_ID}_${SELF_PID}_${SAFE_PFX}.txt"
      set +e
      list_keys "$SRC_URI" | LC_ALL=C sort -u > "$SRC_KEYS"
      list_keys "$DST_URI" | LC_ALL=C sort -u > "$DST_KEYS"
      comm -23 "$SRC_KEYS" "$DST_KEYS" > "$MISS_KEYS"
      set -e
      if [[ -s "$MISS_KEYS" ]]; then
        MATCH="missing_in_dst"
        {
          echo "=== Missing in DST for prefix: $PFX  (SRC=$SRC_URI  DST=$DST_URI)"
          sed -e "s#^#s3://${SRC}/#" "$MISS_KEYS"
          echo
        } >> "$MISSING_LOG"
        printf "[missing-in-dst] %s  %s missing object(s) listed in %s\n" \
          "$PFX" "$(wc -l < "$MISS_KEYS" | tr -d ' ')" "$MISSING_LOG" >> "$LOG_FILE"
        (( MISS_DST_PREFIXES += 1 ))
        (( MISS_DST_OBJS += SRC_COUNT ))
        (( MISS_DST_BYTES += SRC_BYTES ))
      fi
    fi
  fi

  # --- Extras in DST (DST − SRC) with recheck + normalized diff ----------------
  if (( DST_COUNT > SRC_COUNT )) && [[ "$LIST_EXTRAS" = "1" ]]; then
    read -r re_sc _ <<<"$(summarize_objects_and_bytes "$SRC_URI")"
    if (( DST_COUNT > re_sc )); then
      local SAFE_PFX="${PFX//\//__}"
      local SRC_KEYS="$TMP_DIR/src_keys_${RUN_ID}_${SELF_PID}_${SAFE_PFX}.txt"
      local DST_KEYS="$TMP_DIR/dst_keys_${RUN_ID}_${SELF_PID}_${SAFE_PFX}.txt"
      local EXTRA_KEYS="$TMP_DIR/extra_keys_${RUN_ID}_${SELF_PID}_${SAFE_PFX}.txt"
      set +e
      list_keys "$SRC_URI" | LC_ALL=C sort -u > "$SRC_KEYS"
      list_keys "$DST_URI" | LC_ALL=C sort -u > "$DST_KEYS"
      comm -13 "$SRC_KEYS" "$DST_KEYS" > "$EXTRA_KEYS"
      set -e
      if [[ -s "$EXTRA_KEYS" ]]; then
        {
          echo "=== Extra keys in DST for prefix: $PFX  (SRC=$SRC_URI  DST=$DST_URI)"
          sed -e "s#^#s3://${DST}/#" "$EXTRA_KEYS"
          echo
        } >> "$EXTRAS_LOG"
        # printf "[extra-in-dst] %s  %s extra object(s) listed in %s\n" \
        print_sync "[extra-in-dst] %s  %s extra object(s) listed in %s\n" \
          "$PFX" "$(wc -l < "$EXTRA_KEYS" | tr -d ' ')" "$EXTRAS_LOG" >> "$LOG_FILE"
      fi
    fi
  fi

  # printf "%s\n" "$LINE"
  print_sync "$LINE"

  # per-job CSV
  local SAFE_PFX2="${PFX//\//__}"
  local JOB_OUT="$TMP_DIR/res_${RUN_ID}_${SELF_PID}_${SAFE_PFX2}.csv"
  printf "%s,%s,%s,%s,%s,%s\n" \
    "$PFX" "$SRC_COUNT" "$SRC_BYTES" "$DST_COUNT" "$DST_BYTES" "$MATCH" > "$JOB_OUT"
}

# --- dispatch jobs ------------------------------------------------------------
for PFX in "${FILTERED[@]}"; do
  bg_gate
  # compare_one_prefix "$PFX" &
  compare_one_prefix "$PFX" </dev/null &
done
wait

# --- gather per-job results ---------------------------------------------------
RES_FILE="$TMP_DIR/results_${RUN_ID}_${SELF_PID}.csv"
: > "$RES_FILE"
cat "$TMP_DIR"/res_"${RUN_ID}"_"${SELF_PID}"_*.csv > "$RES_FILE" 2>/dev/null || :

# --- aggregate totals ---------------------------------------------------------
while IFS=',' read -r pfx sc sb dc db m; do
  [[ "${pfx:-}" == "prefix" || -z "${pfx:-}" ]] && continue
  [[ "$sc" =~ ^[0-9]+$ ]] && (( TOTAL_SRC_OBJS += sc ))
  [[ "$dc" =~ ^[0-9]+$ ]] && (( TOTAL_DST_OBJS += dc ))
  [[ "$sb" =~ ^[0-9]+$ ]] && (( TOTAL_SRC_BYTES += sb ))
  [[ "$db" =~ ^[0-9]+$ ]] && (( TOTAL_DST_BYTES += db ))
done < "$RES_FILE"

# append to main CSV (already has header)
cat "$RES_FILE" >> "$CSV_FILE"

# --- summary ------------------------------------------------------------------
echo
printf "%sGrand Totals%s\n" "$BOLD" "$RESET"
printf "  SRC objects: %12d   (%s)\n" "$TOTAL_SRC_OBJS" "$(human_bytes "$TOTAL_SRC_BYTES")"
printf "  DST objects: %12d   (%s)\n" "$TOTAL_DST_OBJS" "$(human_bytes "$TOTAL_DST_BYTES")"

echo
if (( MISS_DST_PREFIXES > 0 )); then
  printf "%sMissing in DST%s\n" "$BOLD" "$RESET"
  printf "  Prefixes (had gaps when checked): %d\n" "$MISS_DST_PREFIXES"
  printf "  SRC-side objects (sum of those prefixes): %d\n" "$MISS_DST_OBJS"
  printf "  SRC-side size (sum of those prefixes):   %s (%s GiB)\n" \
    "$(human_bytes "$MISS_DST_BYTES")" "$(bytes_to_gib "$MISS_DST_BYTES")"
  [[ -s "$MISSING_LOG" ]] && printf "  Keys log:  %s\n" "$MISSING_LOG"
else
  printf "%sNo prefixes were missing in DST at check time.%s\n" "$GREEN" "$RESET"
  [[ "${LIST_MISSING:-1}" = "1" && ! -s "$MISSING_LOG" ]] && rm -f "$MISSING_LOG"
fi

if [[ -s "$EXTRAS_LOG" ]]; then
  printf "  Extras log: %s\n" "$EXTRAS_LOG"
else
  [[ "${LIST_EXTRAS:-1}" = "1" ]] && rm -f "$EXTRAS_LOG"
fi

printf "\nCSV:  %s\nLOG:  %s\n" "$CSV_FILE" "$LOG_FILE"

# --- cleanup ------------------------------------------------------------------
rm -rf "$TMP_DIR"
command -v stty >/dev/null 2>&1 && stty sane || true
