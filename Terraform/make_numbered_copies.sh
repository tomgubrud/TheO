#!/usr/bin/env bash
# make_numbered_copies.sh — generate fast, local, numbered copies for screenshots
# Usage examples:
#   ./make_numbered_copies.sh                          # defaults to aws/storage/s3_bucket and s3_replication
#   ./make_numbered_copies.sh aws/storage/s3_bucket aws/storage/s3_replication
#   ./make_numbered_copies.sh aws/storage/s3_bucket/*.tf
set -euo pipefail
shopt -s nullglob

OUTDIR="_numbered"
mkdir -p "$OUTDIR"

args=("$@")
if [[ ${#args[@]} -eq 0 ]]; then
  args=( "aws/storage/s3_bucket" "aws/storage/s3_replication" )
fi

gather() {
  local a="$1"
  if [[ -d "$a" ]]; then
    find "$a" -maxdepth 1 -type f -name '*.tf' | sort
  else
    local expanded=( $a )
    for f in "${expanded[@]}"; do
      [[ -f "$f" ]] && echo "$f"
    done
  fi
}

count=0
for a in "${args[@]}"; do
  while IFS= read -r f; do
    rel="$f"
    # create mirrored path under _numbered with .num.txt extension
    out="$OUTDIR/$rel.num.txt"
    mkdir -p "$(dirname "$out")"
    awk '{printf "%5d: %s\n", NR, $0}' "$f" > "$out"
    echo "[OK] $out"
    count=$((count+1))
  done < <(gather "$a")
done

echo "[DONE] Numbered $count files into $OUTDIR/ (open these in VS Code and screenshot)."
