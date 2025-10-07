#!/usr/bin/env bash
# bucketcompare.sh — parallel current-object count compare (SRC vs DEST)
# Usage:
#   ./bucketcompare.sh                       # prompts
#   ./bucketcompare.sh SRC_BUCKET DEST_BUCKET [PREFIX]  # no prompts
#
# Optional helper: ./awshelper.sh (sourced if present) — can export defaults like:
#   export SRC_DEFAULT=in2-sdp-encore-s3-bucket-ncz
#   export DEST_DEFAULT=nc-dev-00-aog-data-sdp-s3-encore
#   export PREFIX_DEFAULT=input/
#   export AWS_PROFILE=...
#   export AWS_REGION=...

set -euo pipefail

# ---------- helper (optional) ----------
HELPER_SCRIPT="./awshelper.sh"
if [[ -f "$HELPER_SCRIPT" ]]; then
  echo "Loading AWS configuration from ${HELPER_SCRIPT}..."
  # shellcheck source=/dev/null
  source "$HELPER_SCRIPT"
  echo "AWS configuration loaded."
  echo
fi

# ---------- config ----------
MAX_PROCS="${MAX_PROCS:-$({ /usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; } 2>/dev/null)}"

hr(){ printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }

ask(){
  # robust prompt that won't exit under set -e/-u
  local prompt="$1" var="$2" default="${3:-}" ans rc
  while :; do
    IFS= read -r -p "${prompt}${default:+ [$default]}: " ans; rc=$?
    if (( rc != 0 )); then
      if [[ -n "$default" ]]; then eval "$var=\"\$default\""; return 0; fi
      echo "Input aborted for '$prompt'." >&2; exit 1
    fi
    if [[ -z "$ans" && -n "$default" ]]; then eval "$var=\"\$default\""; return 0; fi
    if [[ -n "$ans" ]]; then eval "$var=\"\$ans\""; return 0; fi
    echo "Please enter a value."
  done
}

hash_id(){
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | base64 | tr '/+=\n' '_.-_'
  fi
}

count_objects(){
  local bucket="$1" prefix="$2" token="" total=0 kc nct
  while :; do
    if [[ -z "$token" ]]; then
      read kc nct < <(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --max-keys 1000 \
                      --query '{kc:KeyCount,nct:NextContinuationToken}' --output text 2>/dev/null || echo "0 None")
    else
      read kc nct < <(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --max-keys 1000 --continuation-token "$token" \
                      --query '{kc:KeyCount,nct:NextContinuationToken}' --output text 2>/dev/null || echo "0 None")
    fi
    [[ "$kc" == "None" || -z "$kc" ]] && kc=0
    total=$(( total + kc ))
    [[ "$nct" == "None" || -z "$nct" ]] && break
    token="$nct"
  done
  echo "$total"
}

discover_children(){
  local bucket="$1" base="$2"
  aws s3api list-objects-v2 --bucket "$bucket" --prefix "$base" --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true
}

fallback_shards(){
  local base="$1" chars='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-=%/'
  local out=(); for ((i=0;i<${#chars};i++)); { out+=("${base}${chars:i:1}"); }
  printf '%s\n' "${out[@]}"
}

process_shard(){
  local shard="$1" src="$2" dest="$3" tmp="$4"
  local src_cnt dest_cnt fn
  src_cnt="$(count_objects "$src" "$shard")"
  dest_cnt="$(count_objects "$dest" "$shard")"
  fn="$tmp/$(hash_id "$shard").tsv"
  printf "%s\t%d\t%d\n" "$shard" "$src_cnt" "$dest_cnt" > "$fn"
}

wait_for_slot(){
  while (( $(jobs -r | wc -l | tr -d ' ') >= MAX_PROCS )); do
    if wait -n 2>/dev/null; then :; else sleep 0.2; fi
  done
}

# ---------- args + prompts ----------
SRC_BUCKET="${1:-${SRC_DEFAULT-}}"
DEST_BUCKET="${2:-${DEST_DEFAULT-}}"
SRC_PREFIX="${3:-${PREFIX_DEFAULT-}}"

if [[ -z "${SRC_BUCKET:-}" ]];  then ask "Source bucket" SRC_BUCKET;  fi
if [[ -z "${DEST_BUCKET:-}" ]]; then ask "Destination bucket" DEST_BUCKET; fi
if [[ -z "${SRC_PREFIX:-}" ]]; then ask "Source prefix (optional, e.g., input/ or input/ods/)" SRC_PREFIX ""; fi
[[ -n "$SRC_PREFIX" && "${SRC_PREFIX: -1}" != "/" ]] && SRC_PREFIX="${SRC_PREFIX}/"

hr
echo "Source:      s3://$SRC_BUCKET/${SRC_PREFIX}"
echo "Destination: s3://$DEST_BUCKET/${SRC_PREFIX}"
echo "Concurrency: $MAX_PROCS workers"
hr

# ---------- shard & run ----------
echo "Discovering child prefixes under s3://$SRC_BUCKET/${SRC_PREFIX} ..."
mapfile -t SHARDS < <(discover_children "$SRC_BUCKET" "$SRC_PREFIX")
if (( ${#SHARDS[@]} <= 1 )); then
  echo "Few/no child prefixes; using first-character sharding."
  mapfile -t SHARDS < <(fallback_shards "$SRC_PREFIX")
fi
echo "Shard count: ${#SHARDS[@]} (processing in parallel)"

TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

i=0
for shard in "${SHARDS[@]}"; do
  wait_for_slot
  process_shard "$shard" "$SRC_BUCKET" "$DEST_BUCKET" "$TMPDIR" &
  ((i++)); (( i % 20 == 0 )) && echo "  ...launched $i/${#SHARDS[@]} shards"
done
wait

# ---------- collate ----------
MISMATCHES=0; MATCHES=0; TOTAL_SRC=0; TOTAL_DEST=0
printf "\n"; hr; printf "Mismatched shards (Source vs Dest counts):\n"; hr
for f in "$TMPDIR"/*.tsv; do
  [[ -e "$f" ]] || continue
  IFS=$'\t' read -r shard s_cnt d_cnt < "$f"
  TOTAL_SRC=$(( TOTAL_SRC + s_cnt ))
  TOTAL_DEST=$(( TOTAL_DEST + d_cnt ))
  if [[ "$s_cnt" -ne "$d_cnt" ]]; then
    printf "%s\tSRC=%d\tDEST=%d\n" "$shard" "$s_cnt" "$d_cnt"
    ((MISMATCHES++))
  else
    ((MATCHES++))
  fi
done | sort

hr
printf "Shards matched:   %d\n" "$MATCHES"
printf "Shards mismatched:%d\n" "$MISMATCHES"
printf "TOTAL (current objects)\n  Source:      %d\n  Destination: %d\n" "$TOTAL_SRC" "$TOTAL_DEST"
hr
echo "Done."
