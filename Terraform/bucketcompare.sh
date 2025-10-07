#!/usr/bin/env bash
# s3_compare_counts.sh — parallel current-object count compare (SRC vs DEST)
# Prompts for: source bucket, destination bucket, optional prefix
# Prints only mismatched shards; totals at the end.

set -euo pipefail

MAX_PROCS="${MAX_PROCS:-$(/usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

hr(){ printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }
ask(){ local p="$1" v="$2" d="${3:-}"; read -rp "$p${d:+ [$d]}: " "$v"; [[ -z "${!v}" && -n "$d" ]] && eval "$v=\"$d\""; }

# Filesystem-safe ID for shard filenames
hash_id(){
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | base64 | tr '/+=\n' '_.-_'
  fi
}

# Count *current* objects under bucket/prefix via paginated ListObjectsV2
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

# Discover immediate child “folders” to shard on
discover_children(){
  local bucket="$1" base="$2"
  aws s3api list-objects-v2 --bucket "$bucket" --prefix "$base" --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true
}

# Fallback fan-out by first character for flat prefixes
fallback_shards(){
  local base="$1" chars="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-=%/"
  local out=()
  for ((i=0;i<${#chars};i++)); do out+=("${base}${chars:i:1}"); done
  printf '%s\n' "${out[@]}"
}

process_shard(){
  local shard="$1" src="$2" dest="$3" tmp="$4"
  local src_cnt dest_cnt fn
  src_cnt=$(count_objects "$src" "$shard")
  dest_cnt=$(count_objects "$dest" "$shard")
  fn="$tmp/$(hash_id "$shard").tsv"
  printf "%s\t%d\t%d\n" "$shard" "$src_cnt" "$dest_cnt" > "$fn"
}

wait_for_slot(){ while (( $(jobs -r | wc -l | tr -d ' ') >= MAX_PROCS )); do if wait -n 2>/dev/null; then :; else sleep 0.2; fi; done; }

echo "S3 object count comparer (parallel)."
ask "Source bucket" SRC_BUCKET
ask "Destination bucket" DEST_BUCKET
ask "Source prefix (optional, e.g., input/ or input/ods/)" SRC_PREFIX ""

# normalize prefix
[[ -n "$SRC_PREFIX" && "${SRC_PREFIX: -1}" != "/" ]] && SRC_PREFIX="${SRC_PREFIX}/"

hr
echo "Source:      s3://$SRC_BUCKET/${SRC_PREFIX}"
echo "Destination: s3://$DEST_BUCKET/${SRC_PREFIX}"
echo "Concurrency: $MAX_PROCS workers"
hr

echo "Discovering child prefixes under s3://$SRC_BUCKET/${SRC_PREFIX} ..."
mapfile -t SHARDS < <(discover_children "$SRC_BUCKET" "$SRC_PREFIX")

# if few/no children, still parallelize via first-character sharding
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
