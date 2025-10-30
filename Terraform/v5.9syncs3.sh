#!/usr/bin/env bash
set -euo pipefail

# v5.9syncs3.sh
# - Per-P1 dispatcher with background jobs and per-P1 up-to-date detection
# - Supports BASE like: "", "staged/", "staged/2025-10-01/", or "staged/2025-10-*/"
# - Prints a single [plan] line, accurate "Already up‑to‑date P1s", and a clean summary
#
# EXPECTS (from ./awshelper.sh):
#   SRC="in2-sdp-integration-s3-bucket-ncz"
#   DST="nc-dev-00-aog-data-sdp-s3-integration"
#
# Optional: FILTER="substring" to match P1 text after any BASE P0

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-./logs/$RUN_ID}"
mkdir -p "$LOG_DIR"
RAW_LOG="$LOG_DIR/sync_${RUN_ID}_<pfx>.raw.log"
ERR_LOG="$LOG_DIR/sync_${RUN_ID}_<pfx>.err.log"
MASTER_CSV="$LOG_DIR/sync_${RUN_ID}_deltas.csv"
START_TS="$(date +%s)"

# Kill stray children on any exit so we never hang
trap 'jobs -pr | xargs -r kill 2>/dev/null || true' EXIT

# --- colors (TTY only) -------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN="$(tput setaf 2 || true)"; RED="$(tput setaf 1 || true)"; YEL="$(tput setaf 3 || true)"
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
else
  GREEN=""; RED=""; YEL=""; BOLD=""; RESET=""
fi

# --- preflight ---------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "[ERROR] aws CLI not found" >&2; exit 127; }
[[ -f ./awshelper.sh ]] || { echo "[ERROR] awshelper.sh not found" >&2; exit 1; }
# shellcheck disable=SC1091
source ./awshelper.sh

[[ -n "${SRC:-}" && -n "${DST:-}" ]] || { echo "[ERROR] SRC and DST must be set (awshelper.sh)" >&2; exit 1; }

KEEPALIVE="/projects/dev-file/scripts/helper-scripts/vault_keepalive.sh"
[[ -x "$KEEPALIVE" ]] || { echo "[ERROR] $KEEPALIVE not found or not executable" >&2; exit 1; }

# --- helpers -----------------------------------------------------------------
trim_slashes(){ local s="${1:-}"; s="${s#/}"; echo "${s%/}"; }
human_bytes(){
  awk -v b="${1:-0}" 'BEGIN{
    u[1]="B";u[2]="KiB";u[3]="MiB";u[4]="GiB";u[5]="TiB";
    n=1; while (b>=1024 && n<5){b/=1024;n++}
    if (n==1) printf "%.0f %s", b, u[n]; else printf "%.2f %s", b, u[n];
  }'
}
summarize_count_bytes(){ # prints "<objs> <bytes>"
  local uri="$1" out cnt bytes
  out="$(aws s3 ls "$uri" --recursive --summarize 2>/dev/null || true)"
  cnt="$(awk '/Total Objects:/ {print $3}' <<<"$out")"
  bytes="$(awk '/Total Size:/ {print $3}'  <<<"$out")"
  echo "${cnt:-0} ${bytes:-0}"
}

# --- parse BASE into P0 and optional P1 pattern ------------------------------
BASE="${BASE:-}"
BASE="$(trim_slashes "${BASE}")"      # e.g., "", "staged", "staged/2025-10-01", "staged/2025-10-*"
P0=""; P1_GLOB=""
if [[ -n "$BASE" ]]; then
  IFS='/' read -r p0 maybe_p1 <<<"$BASE"
  P0="$p0"
  P1_GLOB="${maybe_p1:-}"             # may be "", exact, or wildcard like 2025-10-*
fi

FILTER="${FILTER:-}"                   # substring match on P1 (after glob)

SRC_BASE_URI="s3://${SRC}/"
DST_BASE_URI="s3://${DST}/"
if [[ -n "$P0" ]]; then
  SRC_BASE_URI="s3://${SRC}/${P0}/"
  DST_BASE_URI="s3://${DST}/${P0}/"
fi

# --- header ------------------------------------------------------------------
echo "----------------------------------------------------------------"
echo "Sync dispatcher"
echo "Source:       ${SRC_BASE_URI}"
echo "Destination:  ${DST_BASE_URI}"
if [[ -n "$BASE" ]]; then
  echo "Mode:         BASE=${BASE}"
else
  echo "Mode:         FULL BUCKET (all P1s)"
fi
echo "Logs:         ${RAW_LOG}  /  ${ERR_LOG}"
echo "Master CSV:   ${MASTER_CSV}"
echo "----------------------------------------------------------------"

# --- list P1 candidates ------------------------------------------------------
echo "[scan] Listing P1 under: ${SRC_BASE_URI}"
mapfile -t ALL_P1 < <(
  aws s3api list-objects-v2 \
    --bucket "$SRC" \
    --prefix "${P0:+$P0/}" \
    --delimiter '/' \
  | jq -r '.CommonPrefixes[].Prefix' 2>/dev/null \
  | sed -e 's#^'"$P0"'/##' -e 's#/$##' \
  | sort
)

CAND=()
shopt -s extglob nullglob
for p in "${ALL_P1[@]}"; do
  # If P1_GLOB provided, enforce it as a pattern
  if [[ -n "$P1_GLOB" ]]; then
    [[ "$p" == $P1_GLOB ]] || continue
  fi
  # If FILTER provided, require substring
  if [[ -n "$FILTER" ]]; then
    [[ "$p" == *"$FILTER"* ]] || continue
  fi
  CAND+=("$p")
done
shopt -u extglob nullglob

if ((${#CAND[@]}==0)); then
  echo "[WARN] No P1 prefixes matched under ${SRC_BASE_URI} (BASE='${BASE}', FILTER='${FILTER}'). Exiting."
  echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"
  exit 0
fi

# --- peek + classify (light/med/heavy by SRC object count) -------------------
declare -A SRC_OBJS SRC_BYTES PCLASS
LIGHT=() ; MED=() ; HEAVY=()
TOTAL_SELECTED_OBJS=0; TOTAL_SELECTED_BYTES=0

for p in "${CAND[@]}"; do
  peek_uri="${SRC_BASE_URI}${p}/"
  read -r cnt bytes <<<"$(summarize_count_bytes "$peek_uri")"
  SRC_OBJS["$p"]="$cnt"
  SRC_BYTES["$p"]="$bytes"
  (( TOTAL_SELECTED_OBJS += cnt ))
  (( TOTAL_SELECTED_BYTES += bytes ))
  if   (( cnt < 10 ));  then LIGHT+=("$p"); PCLASS["$p"]="LIGHT"
  elif (( cnt <= 150 )); then MED+=("$p");   PCLASS["$p"]="MEDIUM"
  else                       HEAVY+=("$p"); PCLASS["$p"]="HEAVY"
  fi
done

HEAVY_CONC=${HEAVY_CONC:-5}; MED_CONC=${MED_CONC:-3}; LIGHT_CONC=${LIGHT_CONC:-10}
echo "[plan] ${#CAND[@]} prefix(es); concurrency ${HEAVY_CONC}/${MED_CONC}/${LIGHT_CONC}  (H/M/L)"
for p in "${CAND[@]}"; do echo " - $p"; done

# --- dispatch jobs -----------------------------------------------------------
declare -A PRE_OBJS PRE_BYTES POST_OBJS POST_BYTES COPIED_OBJS COPIED_BYTES RC P2PREFIX
PIDS=()

for p in "${CAND[@]}"; do
  src_p="${SRC_BASE_URI}${p}/"
  dst_p="${DST_BASE_URI}${p}/"

  # pre-count DST
  read -r pre_c pre_b <<<"$(summarize_count_bytes "$dst_p")"
  PRE_OBJS["$p"]="$pre_c"
  PRE_BYTES["$p"]="$pre_b"

  (
    # Run sync under vault keepalive wrapper
    "$KEEPALIVE" aws s3 sync "$src_p" "$dst_p" \
      --exclude '*$folder$' --exact-timestamps --size-only --no-progress --only-show-errors \
      >>"${RAW_LOG/"<pfx>"/$p}" 2>>"${ERR_LOG/"<pfx>"/$p}"
    rc=$?

    # post-count
    read -r post_c post_b <<<"$(summarize_count_bytes "$dst_p")"
    {
      echo "rc=$rc"
      echo "post_c=$post_c"
      echo "post_b=$post_b"
    } > "${LOG_DIR}/.${RUN_ID}.${p}.done"
  ) &

  PIDS+=("$!")
  P2PREFIX["$!"]="$p"
  echo "[run] $p -> $dst_p"
done

# --- wait + collect ----------------------------------------------------------
ALREADY_UP_TO_DATE=0
TOTAL_COPIED_OBJS=0
TOTAL_COPIED_BYTES=0

echo "prefix,class,copied_objs,copied_bytes,rc" > "$MASTER_CSV"

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
  p="${P2PREFIX[$pid]}"
  rc=1 post_c=0 post_b=0
  if [[ -f "${LOG_DIR}/.${RUN_ID}.${p}.done" ]]; then
    # shellcheck disable=SC1090
    source "${LOG_DIR}/.${RUN_ID}.${p}.done"
    rm -f "${LOG_DIR}/.${RUN_ID}.${p}.done"
  fi
  RC["$p"]="$rc"
  POST_OBJS["$p"]="$post_c"
  POST_BYTES["$p"]="$post_b"

  co=$(( post_c - ${PRE_OBJS[$p]:-0} ))
  cb=$(( post_b - ${PRE_BYTES[$p]:-0} ))
  (( co < 0 )) && co=0
  (( cb < 0 )) && cb=0
  COPIED_OBJS["$p"]="$co"
  COPIED_BYTES["$p"]="$cb"

  if (( rc == 0 && co == 0 )); then
    (( ALREADY_UP_TO_DATE++ ))
  fi
  (( TOTAL_COPIED_OBJS  += co ))
  (( TOTAL_COPIED_BYTES += cb ))

  printf "%s,%s,%d,%d,%d\n" "$p" "${PCLASS[$p]}" "$co" "$cb" "$rc" >> "$MASTER_CSV"
done

# --- summary -----------------------------------------------------------------
END_TS="$(date +%s)"
ELAPSED=$(( END_TS - START_TS ))

echo "================ Summary (RUN ${RUN_ID}) ================"
printf " Selected P1 total (SRC peek):   %12d  (%s)\n" \
  "$TOTAL_SELECTED_OBJS" "$(human_bytes "$TOTAL_SELECTED_BYTES")"
printf " Total copied (DST delta):       %12d  (%s)\n" \
  "$TOTAL_COPIED_OBJS" "$(human_bytes "$TOTAL_COPIED_BYTES")"
printf " Already up-to-date P1s:         %12d  / %d\n" \
  "$ALREADY_UP_TO_DATE" "${#CAND[@]}"
printf " Concurrency (H/M/L):            %s/%s/%s\n" "$HEAVY_CONC" "$MED_CONC" "$LIGHT_CONC"
printf " Elapsed:                        %ss\n" "$ELAPSED"
printf " Logs:                           %s  (+ .err.log)\n" "${RAW_LOG/"<pfx>"/"<pfx>"}"
printf " Master CSV:                     %s\n" "$MASTER_CSV"
echo "========================================================="

# final no-op wait (defensive) then clean exit
wait || true
exit 0
