#!/usr/bin/env bash
# bucketcompare.sh — parallel current-object count compare (SRC vs DEST)
# Usage:
#   ./bucketcompare.sh -f jobs.csv       # each line: SRC_BUCKET,DEST_BUCKET,PREFIX
#   ./bucketcompare.sh SRC DEST [PREFIX] # single job (no file)
#   ./bucketcompare.sh                   # prompts
#
# Optional helper: ./awshelper.sh (sourced if present) to set defaults, profile, etc.

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
ask(){ local p="$1" v="$2" d="${3:-}" a rc
  while :; do IFS= read -r -p "${p}${d:+ [$d]}: " a; rc=$?
    ((rc!=0)) && { [[ -n "$d" ]] && eval "$v=\"\$d\"" || { echo "Input aborted."; exit 1; }; break; }
    [[ -z "$a" && -n "$d" ]] && { eval "$v=\"\$d\""; break; }
    [[ -n "$a" ]] && { eval "$v=\"\$a\""; break; }
    echo "Please enter a value."
  done
}
hash_id(){
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'
  else printf '%s' "$1" | base64 | tr '/+=\n' '_.-_'
  fi
}
count_objects(){ # current versions only
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
  local out=(); for ((i=0;i<${#chars};i++)); do out+=("${base}${chars:i:1}"); done
  printf '%s\n' "${out[@]}"
}
process_shard(){
  local shard="$1" src="$2" dest="$3" out="$4"
  local s d fn tmp
  s="$(count_objects "$src" "$shard")"
  d="$(count_objects "$dest" "$shard")"
  mkdir -p "$out"
  fn="$out/$(hash_id "$shard").tsv"
  tmp="$fn.$$"
  printf "%s\t%d\t%d\n" "$shard" "$s" "$d" > "$tmp"
  mv -f "$tmp" "$fn"
}

run_one_compare(){ # args: SRC DEST PREFIX
  local SRC_BUCKET="$1" DEST_BUCKET="$2" SRC_PREFIX="${3:-}"
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

  # ---- launch workers with PID-based throttling ----
  local -a PIDS=()
  local idx=0
  for shard in "${SHARDS[@]}"; do
    process_shard "$shard" "$SRC_BUCKET" "$DEST_BUCKET" "$OUTDIR" &
    PIDS+=("$!")
    ((idx++))
    if (( ${#PIDS[@]} >= MAX_PROCS )); then
      wait "${PIDS[0]}" 2>/dev/null || true
      PIDS=("${PIDS[@]:1}")
    fi
    (( idx % 20 == 0 )) && echo "  ...launched $idx/${#SHARDS[@]} shards"
  done
  # wait remaining
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

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

# -------- CLI parsing --------
INFILE=""
if [[ "${1-}" == "-f" || "${1-}" == "--file" ]]; then
  INFILE="${2-}"; shift 2 || true
fi

if [[ -n "$INFILE" ]]; then
  if [[ ! -f "$INFILE" ]]; then echo "Input file not found: $INFILE" >&2; exit 1; fi
  echo "Reading jobs from: $INFILE"
  while IFS=, read -r SRC DEST PFX || [[ -n "${SRC:-}" ]]; do
    # skip empty/comment lines
    [[ -z "${SRC// }" || "${SRC:0:1}" == "#" ]] && continue
    run_one_compare "$SRC" "$DEST" "${PFX:-}"
  done < "$INFILE"
  exit 0
fi

# single job (args or prompts)
SRC_BUCKET="${1:-${SRC_DEFAULT-}}"
DEST_BUCKET="${2:-${DEST_DEFAULT-}}"
SRC_PREFIX="${3:-${PREFIX_DEFAULT-}}"
[[ -z "${SRC_BUCKET:-}"  ]] && ask "Source bucket" SRC_BUCKET
[[ -z "${DEST_BUCKET:-}" ]] && ask "Destination bucket" DEST_BUCKET
[[ -z "${SRC_PREFIX:-}"  ]] && ask "Source prefix (optional, e.g., input/ or input/ods/)" SRC_PREFIX ""
run_one_compare "$SRC_BUCKET" "$DEST_BUCKET" "$SRC_PREFIX"
