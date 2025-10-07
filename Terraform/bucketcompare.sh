#!/usr/bin/env bash
set -euo pipefail

# --------------------------- Config / helpers ---------------------------
MAX_PROCS="${MAX_PROCS:-$(/usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

hr() { printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }

ask() {
  local prompt="$1" var="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " "$var"
    [[ -z "${!var}" ]] && eval "$var=\"$default\""
  else
    read -rp "$prompt: " "$var"
  fi
}

# Count objects under bucket+prefix using list-objects-v2 pagination.
count_objects() {
  local bucket="$1" prefix="$2"
  local token="" total=0 kc nct
  while :; do
    if [[ -z "$token" ]]; then
      read kc nct < <(aws s3api list-objects-v2 \
        --bucket "$bucket" --prefix "$prefix" --max-keys 1000 \
        --query '{kc:KeyCount, nct:NextContinuationToken}' --output text || echo "0 None")
    else
      read kc nct < <(aws s3api list-objects-v2 \
        --bucket "$bucket" --prefix "$prefix" --max-keys 1000 --continuation-token "$token" \
        --query '{kc:KeyCount, nct:NextContinuationToken}' --output text || echo "0 None")
    fi
    [[ "$kc" == "None" || -z "$kc" ]] && kc=0
    total=$(( total + kc ))
    [[ "$nct" == "None" || -z "$nct" ]] && break
    token="$nct"
  done
  echo "$total"
}

# Discover immediate child prefixes (like folders) to shard work.
discover_children() {
  local bucket="$1" base="$2"
  aws s3api list-objects-v2 --bucket "$bucket" --prefix "$base" --delimiter '/' \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' || true
}

# Fallback shard set (fan-out by first char)
fallback_shards() {
  local base="$1" chars="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ._-=%/"
  local c out=()
  for ((i=0; i<${#chars}; i++)); do
    c="${chars:i:1}"
    out+=("${base}${c}")
  done
  printf '%s\n' "${out[@]}"
}

# Worker for a shard: counts src+dest and prints TSV result to a temp file.
process_shard() {
  local shard="$1" src="$2" dest="$3" tmp="$4"
  local src_cnt dest_cnt
  src_cnt=$(count_objects "$src" "$shard")
  dest_cnt=$(count_objects "$dest" "$shard")
  printf "%s\t%d\t%d\n" "$shard" "$src_cnt" "$dest_cnt" > "$tmp/$(echo -n "$shard" | base64).tsv"
}

wait_for_slot() {
  # Limit background jobs to MAX_PROCS
  while (( $(jobs -r | wc -l | tr -d ' ') >= MAX_PROCS )); do
    # 'wait -n' if available, else brief sleep
    if wait -n 2>/dev/null; then :; else sleep 0.2; fi
  done
}

# --------------------------- Prompt for inputs ---------------------------
echo "S3 object count comparer (parallel)."
ask "Source bucket" SRC_BUCKET
ask "Destination bucket" DEST_BUCKET
ask "Source prefix (optional, e.g., input/ or input/ods/)" SRC_PREFIX ""

# Normalize prefix to include trailing slash when provided
if [[ -n "$SRC_PREFIX" && "${SRC_PREFIX: -1}" != "/" ]]; then
  SRC_PREFIX="${SRC_PREFIX}/"
fi

hr
echo "Source:      s3://$SRC_BUCKET/${SRC_PREFIX}"
echo "Destination: s3://$DEST_BUCKET/${SRC_PREFIX}"
echo "Concurrency: $MAX_PROCS workers"
hr

# --------------------------- Build shard list ---------------------------
echo "Discovering child prefixes under s3://$SRC_BUCKET/${SRC_PREFIX} ..."
mapfile -t SHARDS < <(discover_children "$SRC_BUCKET" "$SRC_PREFIX")

if [[ ${#SHARDS[@]} -eq 0 ]]; then
  echo "No immediate children found; falling back to first-character sharding."
  mapfile -t SHARDS < <(fallback_shards "$SRC_PREFIX")
fi

echo "Shard count: ${#SHARDS[@]} (processing in parallel)"
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

# --------------------------- Run parallel counts ------------------------
TOTAL_SRC=0
TOTAL_DEST=0

i=0
for shard in "${SHARDS[@]}"; do
  wait_for_slot
  process_shard "$shard" "$SRC_BUCKET" "$DEST_BUCKET" "$TMPDIR" &
  ((i++))
  # lightweight progress every ~20 shards
  if (( i % 20 == 0 )); then
    echo "  ...launched $i/${#SHARDS[@]} shards"
  fi
done

wait  # all shards done

# --------------------------- Collate & report ---------------------------
MISMATCHES=0
MATCHES=0

printf "\n"
hr
printf "Mismatched shards (Source vs Dest counts):\n"
hr

# Read all per-shard results
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
