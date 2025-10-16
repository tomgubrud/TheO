#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# bucket_compare.sh
# ------------------------------------------------------------------------------
# Compares object COUNTS and BYTES for a set of prefixes between two S3 buckets.
# - Sources ./awshelper.sh for SRC, DST, and optional BASE
# - Prompts user for a substring to filter the next-level prefixes
# - Launches ONE background job per prefix (no sharding)
# - Prints colored results; writes logs + machine-readable CSV
# - Adds "Missing in DST" summary with total objects and total GiB
#
# Output (under ./logs):
#   compare_<RUN_ID>.log           : human-readable mismatches/errors + missing-in-dst list
#   compare_<RUN_ID>.results.csv   : prefix,src_count,src_bytes,dst_count,dst_bytes,match
# ------------------------------------------------------------------------------

# --- Config -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-./logs}"
CONCURRENCY="${CONCURRENCY:-8}"   # max background compares; set 0 to disable limiting
mkdir -p "$LOG_DIR"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/compare_${RUN_ID}.log"
CSV_FILE="$LOG_DIR/compare_${RUN_ID}.results.csv"
TMP_DIR="$(mktemp -d -t compare_${RUN_ID}.XXXX)"

# --- Colors -------------------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN="$(tput setaf 2 || true)"; RED="$(tput setaf 1 || true)"; YEL="$(tput setaf 3 || true)"
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
else
  GREEN=""; RED=""; YEL=""; BOLD=""; RESET=""
fi

say()   { printf "%s\n" "$*"; }
warn()  { printf "%s[WARN]%s %s\n" "$YEL" "$RESET" "$*"; }
err()   { printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*" >&2; }

# --- Safety checks ------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { err "aws CLI not found"; exit 127; }

if [[ ! -f ./awshelper.sh ]]; then
  err "awshelper.sh not found. Place it next to this script."
  exit 1
fi
# shellcheck disable=SC1091
source ./awshelper.sh

if [[ -z "${SRC:-}" || -z "${DST:-}" ]]; then
  err "SRC and DST must be set by awshelper.sh (or your environment)."
  exit 1
fi

# Normalize BASE (optional)
trim_slashes() { local s="${1:-}"; s="${s#/}"; s="${s%/}"; echo "$s"; }
BASE="$(trim_slashes "${BASE:-}")"

# Paths for listing next-level prefixes
if [[ -n "$BASE" ]]; then
  SRC_BASE_URI="s3://${SRC}/${BASE}/"
  DST_BASE_URI="s3://${DST}/${BASE}/"
  MODE="BASE=${BASE}"
else
  SRC_BASE_URI="s3://${SRC}/"
  DST_BASE_URI="s3://${DST}/"
  MODE="FULL BUCKET"
fi

# --- Header -------------------------------------------------------------------
cat <<HDR
------------------------------------------------------------
 Compare: ${SRC}  ->  ${DST}
 Mode:    ${MODE}
 Logs:    $LOG_FILE
 CSV:     $CSV_FILE
------------------------------------------------------------
HDR

# Prompt for filter substring
read -rp "Enter any part of the next-level prefix to compare (e.g., 2021, myfolder): " FILTER
FILTER="${FILTER:-}"

# --- Helpers ------------------------------------------------------------------
human_bytes() {
  # Binary units
  local b="${1:-0}"
  awk -v b="$b" 'function p(x,u){printf "%.2f %s",x,u}
    b<1024{p(b,"B");exit}
    b<1048576{p(b/1024,"KiB");exit}
    b<1073741824{p(b/1048576,"MiB");exit}
    b<1099511627776{p(b/1073741824,"GiB");exit}
    {p(b/1099511627776,"TiB")}'
}
bytes_to_gib() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.3f", b/1073741824}'
}

safe_number() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

# Returns "count bytes" (two numbers) for a URI using summarize.
# On error, returns "0 0" and logs stderr.
summarize_objects_and_bytes() {
  local uri="$1" out rc objs bytes
  set +e
  out=$(aws s3 ls "$uri" --recursive --summarize 2>"$TMP_DIR/.err.$$")
  rc=$?
  set -e
  if (( rc != 0 )); then
    warn "Failed to summarize: $uri (treating as 0). Details in $LOG_FILE"
    sed -e "s/^/[aws stderr] /" "$TMP_DIR/.err.$$" >> "$LOG_FILE" || true
    echo "0 0"
    return
  fi
  objs=$(awk '/Total Objects:/ {print $3}' <<<"$out" | tail -n1)
  bytes=$(awk '/Total Size:/ {print $3}'   <<<"$out" | tail -n1)
  echo "$(safe_number "$objs") $(safe_number "$bytes")"
}

# Limit background concurrency (if CONCURRENCY>0)
bg_gate() {
  if (( CONCURRENCY > 0 )); then
    while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do sleep 0.2; done
  fi
}

# List NEXT-LEVEL prefixes (folder names with trailing slash)
list_next_level_prefixes() {
  local base_uri="$1"
  aws s3 ls "$base_uri" | awk '/ PRE /{print $2}'
}

# --- Prepare logs -------------------------------------------------------------
echo "prefix,src_count,src_bytes,dst_count,dst_bytes,match" > "$CSV_FILE"
: > "$LOG_FILE"

# --- Build prefix list --------------------------------------------------------
say "Scanning prefixes under: ${SRC_BASE_URI}"
mapfile -t ALL_PREFIXES < <(list_next_level_prefixes "$SRC_BASE_URI")

FILTERED=()
for p in "${ALL_PREFIXES[@]}"; do
  if [[ -z "$FILTER" || "${p,,}" == *"${FILTER,,}"* ]]; then
    FILTERED+=("${p%/}")  # strip trailing slash
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

# --- Per-prefix compare (background) -----------------------------------------
TOTAL_SRC_OBJS=0
TOTAL_DST_OBJS=0
TOTAL_SRC_BYTES=0
TOTAL_DST_BYTES=0

MISS_DST_PREFIXES=0
MISS_DST_OBJS=0
MISS_DST_BYTES=0

RES_FILE="$TMP_DIR/results.csv"
: > "$RES_FILE"

for PFX in "${FILTERED[@]}"; do
  bg_gate
  {
    if [[ -n "$BASE" ]]; then
      SRC_URI="s3://${SRC}/${BASE}/${PFX}"
      DST_URI="s3://${DST}/${BASE}/${PFX}"
    else
      SRC_URI="s3://${SRC}/${PFX}"
      DST_URI="s3://${DST}/${PFX}"
    fi

    # summarize counts+bytes
    read -r SRC_COUNT SRC_BYTES <<<"$(summarize_objects_and_bytes "$SRC_URI")"
    read -r DST_COUNT DST_BYTES <<<"$(summarize_objects_and_bytes "$DST_URI")"

    # Decide match status & terminal line
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

    # Special case: present in SRC but zero in DST
    if [[ "$SRC_COUNT" -gt 0 && "$DST_COUNT" -eq 0 ]]; then
      printf "[missing-in-dst] %s  SRC=%s  objs=%s  bytes=%s\n" \
        "$PFX" "$SRC_URI" "$SRC_COUNT" "$SRC_BYTES" >> "$LOG_FILE"
      MATCH="missing_in_dst"
    fi

    # Print to screen
    printf "%s\n" "$LINE"

    # Emit CSV row
    printf "%s,%s,%s,%s,%s,%s\n" "$PFX" "$SRC_COUNT" "$SRC_BYTES" "$DST_COUNT" "$DST_BYTES" "$MATCH" >> "$RES_FILE"
  } &
done

wait

# --- Aggregate totals ---------------------------------------------------------
while IFS=',' read -r pfx sc sb dc db m; do
  [[ "$pfx" == "prefix" ]] && continue
  [[ "$sc" =~ ^[0-9]+$ ]] && (( TOTAL_SRC_OBJS += sc ))
  [[ "$dc" =~ ^[0-9]+$ ]] && (( TOTAL_DST_OBJS += dc ))
  [[ "$sb" =~ ^[0-9]+$ ]] && (( TOTAL_SRC_BYTES += sb ))
  [[ "$db" =~ ^[0-9]+$ ]] && (( TOTAL_DST_BYTES += db ))

  if [[ "$m" == "missing_in_dst" ]]; then
    (( MISS_DST_PREFIXES += 1 ))
    (( MISS_DST_OBJS += sc ))
    (( MISS_DST_BYTES += sb ))
  fi
done < "$RES_FILE"

# Append results to main CSV
cat "$RES_FILE" >> "$CSV_FILE"

# --- Summary -----------------------------------------------------------------
echo
printf "%sGrand Totals%s\n" "$BOLD" "$RESET"
printf "  SRC objects: %12d   (%s)\n" "$TOTAL_SRC_OBJS" "$(human_bytes "$TOTAL_SRC_BYTES")"
printf "  DST objects: %12d   (%s)\n" "$TOTAL_DST_OBJS" "$(human_bytes "$TOTAL_DST_BYTES")"

# Missing in DST block
if (( MISS_DST_PREFIXES > 0 )); then
  echo
  printf "%sMissing in DST%s\n" "$BOLD" "$RESET"
  printf "  Prefixes:  %d\n" "$MISS_DST_PREFIXES"
  printf "  Objects:   %d\n" "$MISS_DST_OBJS"
  printf "  Size:      %s (%s GiB)\n" "$(human_bytes "$MISS_DST_BYTES")" "$(bytes_to_gib "$MISS_DST_BYTES")"
  printf "  Details:   %s (search for 'missing-in-dst')\n" "$LOG_FILE"
else
  echo
  printf "%sNo prefixes were present in SRC with zero in DST.%s\n" "$GREEN" "$RESET"
fi

printf "\nCSV:  %s\nLOG:  %s\n" "$CSV_FILE" "$LOG_FILE"

# Cleanup
rm -rf "$TMP_DIR"
