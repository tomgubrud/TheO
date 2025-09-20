#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./print_tf.sh aws/storage/s3_bucket/*.tf aws/storage/s3_replication/*.tf
#
# Prints files to stdout with line numbers and visible whitespace, ideal for screenshots.

num=0
for pattern in "$@"; do
  for f in $(ls -1 $pattern 2>/dev/null || true); do
    num=$((num+1))
    printf "\n%s\n" "$(printf '=%.0s' {1..160})"
    echo "[$num]  $f"
    printf "%s\n" "$(printf '=%.0s' {1..160})"
    n=0
    while IFS= read -r line; do
      n=$((n+1))
      # Show tabs/ trailing spaces as visible glyphs
      vis="${line//$'\t'/↹}"
      if [[ "$line" =~ [[:space:]]+$ ]]; then
        trail="${BASH_REMATCH[0]}"
        dots=$(printf "%${#trail}s" | tr ' ' '·')
        vis="${vis%$trail}$dots"
      fi
      printf "%5d: %s\n" "$n" "$vis"
    done < "$f"
    echo
    read -p "Press Enter for next file (screenshot now)..." _ </dev/tty || true
  done
done
