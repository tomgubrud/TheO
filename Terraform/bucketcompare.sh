#!/usr/bin/env bash
# bucketcompare.sh — parallel current-object count compare (SRC vs DEST)
# Usage:
#   ./bucketcompare.sh                          # prompts
#   ./bucketcompare.sh SRC_BUCKET DEST_BUCKET [PREFIX]  # no prompts
#
# Optional helper: ./awshelper.sh (sourced if present) to set defaults:
#   export SRC_DEFAULT=...
#   export DEST_DEFAULT=...
#   export PREFIX_DEFAULT=input/
#   export AWS_PROFILE=... ; export AWS_REGION=...

set -euo pipefail

# -------- optional helper --------
HELPER_SCRIPT="./awshelper.sh"
if [[ -f "$HELPER_SCRIPT" ]]; then
  echo "Loading AWS configuration from ${HELPER_SCRIPT}..."
  # shellcheck source=/dev/null
  source "$HELPER_SCRIPT"
  echo "AWS configuration loaded."
  echo
fi

# -------- config / utils --------
MAX_PROCS="${MAX_PROCS:-$({ /usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; } 2>/dev/null)}"

hr(){ printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }

ask(){
  local prompt="$1" var="$2" def="${3:-}" ans rc
  while :; do
    IFS= read -r -p "${prompt}${def:+ [$def]}: " ans; rc=$?
    if (( rc != 0 )); then
      [[ -n "$def" ]] && { eval "$var=\"\$def\""; return 0; }
      echo "Input aborted for '$prompt'." >&2; exit 1
    fi
    if [[ -z "$ans" && -n "$def" ]]; then eval "$var=\"\$def\""; return 0; fi
    [[ -n "$ans" ]] && { eval "$var=\"\$ans\""; return 0; }
    echo "Please enter a value."
  done
}

hash_id(){
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | base64 | tr '/+=\n' '_.-_'
  fi
}

# Count *current* objects with paginated ListObjectsV2
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

# Discover immediate child "folders" to shard on
discover_children(){
  local bucket="$1" base="$2"
  aws s3api list-objects-v2 --bucket "$bucket" --prefix "$base" --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true
}

# Fallback fan-out by first character for flat trees
fallback_shards(){
  local base="$1" chars='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-=%/'
  local out=(); for ((i=0;i<${#chars};i++)); do out+=("${base}${chars:i:1}"); done
  printf '%s\n' "${out[@]}"
}

# Worker: count src+dest for a shard and write TSV row
process_shard(){
  local shard="$1" src="$2" dest="$3" outdir="$4"
  local src_cnt dest_cnt fn tmpfile
  src_cnt="$(count_objects "$src" "$shard")"
  dest_cnt="$(count_objects "$dest" "$shard")"
  mkdir -p "$outdir"
  fn="$outdir/$(hash_id "$shard").tsv"
  tmpfile="$fn.$$"
  printf "%s\t%d\t%d\n" "$shard" "$src_cnt" "$dest_cnt" > "$tmpfile"
  mv -f "$tmpfile" "$fn"
}

# -------- args / prompts --------
SRC_BUCKET="${1:-${SRC_DEFAULT-}}"
DEST_BUCKET="${2:-${DEST_DEFAULT-}}"
SRC_PREFIX="${3:-${PREFIX_DEFAULT-}}"

[[ -z "${SRC_BUCKET:-}"  ]] && ask "Source bucket" SRC_BUCKET
[[ -z "${DEST_BUCKET:-}" ]] && ask "Destination bucket" DEST_BUCKET
[[ -z "${SRC_PREFIX:-}"  ]] && ask "Source prefix (optional, e.g., input/ or input/ods/)" SRC_PREFIX ""

[[ -n "$SRC_PREFIX" && "${SRC_PREFIX: -1}" != "/" ]] && SRC_PREFIX="${SRC_PREFIX}/"

hr
echo "Source:      s3://$SRC_BUCKET/${SRC_PREFIX}"
echo "Destination: s3://$DEST_BUCKET/${SRC_PREFIX}"
echo "Concurrency: $MAX_PROCS workers"
hr

# -------- build shards --------
echo "Discovering child prefixes under s3://$SRC_BUCKET/${SRC_PREFIX} ..."
mapfile -t SHARDS < <(discover_children "$SRC_BUCKET" "$SRC_PREFIX")
if (( ${#SHARDS[@]} <= 1 )); then
  echo "Few/no child prefixes; using first-character sharding."
  mapfile -t SHARDS < <(fallback_shards "$SRC_PREFIX")
fi
echo "Shard count: ${#SHARDS[@]} (processing in parallel)"

TMPDIR="$(mktemp -d -t s3cmp.XXXXXX)"
OUTDIR="$TMPDIR/out"
mkdir -p "$OUTDIR"

# -------- semaphore (no 'jobs' dependency) --------
SEM="$TMPDIR/sem"
mkfifo "$SEM"
exec 3<> "$SEM"
rm -f "$SEM"
for ((i=0; i<MAX_PROCS; i++)); do printf '.' >&3; done

# -------- launch workers --------
idx=0
for shard in "${SHARDS[@]}"; do
  # acquire a slot
  read -r -u 3 _tok
  {
    process_shard "$shard" "$SRC_BUCKET" "$DEST_BUCKET" "$OUTDIR"
    # release the slot
    printf '.' >&3
  } &
  ((idx++)); (( idx % 20 == 0 )) && echo "  ...launched $idx/${#SHARDS[@]} shards"
done
wait
# close semaphore FD
exec 3>&- 3<&-

# -------- collate --------
MISMATCHES=0; MATCHES=0; TOTAL_SRC=0; TOTAL_DEST=0
printf "\n"; hr; printf "Mismatched shards (Source vs Dest counts):\n"; hr
for f in "$OUTDIR"/*.tsv; do
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

# cleanup
rm -rf "$TMPDIR" || true
echo "Done."
