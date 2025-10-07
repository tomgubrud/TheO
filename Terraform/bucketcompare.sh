#!/usr/bin/env bash
# bucketcompare.sh — parallel current-object count compare (SRC vs DEST)
# TROUBLESHOOTING MODE:
#   - Uses MAX_PROCS=48
#   - Reads jobs from file: ./testinput   (CSV: SRC,DEST,PREFIX; empty PREFIX = whole bucket)
#   - Ignores CLI args and prompts
#
# Optional helper: ./awshelper.sh (sourced if present) to set AWS_PROFILE/REGION, etc.

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
MAX_PROCS=48
INFILE="testinput"

hr(){ printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }

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
  local s d fn tmp
  s="$(count_objects "$src" "$shard")"
  d="$(count_objects "$dest" "$shard")"
  mkdir -p "$outdir"
  fn="$outdir/$(hash_id "$shard").tsv"
  tmp="$fn.$$"
  printf "%s\t%d\t%d\n" "$shard" "$s" "$d" > "$tmp"
  mv -f "$tmp" "$fn"
}

# export functions for xargs/bash -c
export -f process_shard count_objects discover_children fallback_shards hash_id

run_one_compare(){ # args: SRC DEST PREFIX
  local SRC_BUCKET="$1" DEST_BUCKET="$2" SRC_PREFIX="${3:-}"

  # trim CR if the file is CRLF
  SRC_BUCKET="${SRC_BUCKET%%$'\r'}"
  DEST_BUCKET="${DEST_BUCKET%%$'\r'}"
  SRC_PREFIX="${SRC_PREFIX%%$'\r'}"

  [[ -n "$SRC_PREFIX" && "${SRC_PREFIX: -1}" != "/" ]] && SRC_PREFIX="${SRC_PREFIX}/"

  hr
  echo "Source bucket:      $SRC_BUCKET"
  echo "Destination bucket: $DEST_BUCKET"
  echo "Source prefix:      ${SRC_PREFIX:-<entire bucket>}"
  echo "Concurrency:        $MAX_PROCS workers"
  hr

  echo "Discovering child prefixes under s3://$SRC_BUCKET/${SRC_PREFIX} ..."
  mapfile -t SHARDS < <(discover_children "$SRC_BUCKET" "$SRC_PREFIX")
  if (( ${#SHARDS[@]} <= 1 )); then
    echo "Few/no child prefixes; using first-character sharding."
    mapfile -t SHARDS < <(fallback_shards "$SRC_PREFIX")
  fi
  echo "Shard count: ${#SHARDS[@]} (processing in parallel)"

  local TMPDIR; TMPDIR="$(mktemp -d -t s3cmp.XXXXXX)"
  local OUTDIR="$TMPDIR/out"; mkdir -p "$OUTDIR"

  # feed shards to xargs with concurrency
  # Using bash -c so we can call our exported function.
  printf '%s\0' "${SHARDS[@]}" | \
    xargs -0 -n1 -P "$MAX_PROCS" bash -c 'process_shard "$0" "$1" "$2" "$3"' \
    "${SRC_BUCKET}" "${DEST_BUCKET}" "${OUTDIR}"

  # ---- collate ----
  local MISMATCHES=0 MATCHES=0 TOTAL_SRC=0 TOTAL_DEST=0
  printf "\n"; hr; printf "Mismatched shards (Source vs Dest counts):\n"; hr
  shopt -s nullglob
  for f in "$OUTDIR"/*.tsv; do
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
  shopt -u nullglob

  hr
  printf "Shards matched:   %d\n" "$MATCHES"
  printf "Shards mismatched:%d\n" "$MISMATCHES"
  printf "TOTAL (current objects)\n  Source:      %d\n  Destination: %d\n" "$TOTAL_SRC" "$TOTAL_DEST"
  hr

  rm -rf "$TMPDIR" || true
}

# -------- run from hardcoded file --------
if [[ ! -f "$INFILE" ]]; then
  echo "Input file '$INFILE' not found. Create it with lines: SRC_BUCKET,DEST_BUCKET,PREFIX" >&2
  exit 1
fi

echo "Reading jobs from: $INFILE"
while IFS=, read -r SRC DEST PFX || [[ -n "${SRC:-}" ]]; do
  # skip blank / comment lines
  [[ -z "${SRC// }" || "${SRC:0:1}" == "#" ]] && continue
  run_one_compare "$SRC" "$DEST" "${PFX:-}"
done < "$INFILE"
