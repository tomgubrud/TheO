#!/bin/bash
# S3 Bucket Object Count Comparison Tool
# Requires: AWS CLI v2

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "================================================================================"
echo "S3 Bucket Object Count Comparison Tool"
echo "================================================================================"

read -p "Source bucket name: " SOURCE_BUCKET
read -p "Destination bucket name: " DEST_BUCKET
read -p "Source prefix to check (press Enter for entire bucket): " SOURCE_PREFIX

if [[ -n "$SOURCE_PREFIX" ]] && [[ "$SOURCE_PREFIX" != */ ]]; then
    SOURCE_PREFIX="${SOURCE_PREFIX}/"
fi

# Validate AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found."
    exit 1
fi

# Source AWS helper script if it exists
if [[ -f "./awshelper.sh" ]]; then
    echo "Loading AWS configuration from awshelper.sh..."
    source "./awshelper.sh"
    echo "AWS configuration loaded."
    echo ""
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS credentials not configured or invalid."
    exit 1
fi

echo ""
echo "================================================================================"
echo "Comparing: ${SOURCE_BUCKET}/${SOURCE_PREFIX} -> ${DEST_BUCKET}/${SOURCE_PREFIX}"
echo "================================================================================"
echo ""

# Function to get all top-level prefixes
get_prefixes() {
    local bucket=$1
    local prefix=$2
    
    aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --prefix "$prefix" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>/dev/null | tr '\t' '\n'
}

# Function to count objects for a prefix
count_objects() {
    local bucket=$1
    local prefix=$2
    
    local count=$(aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --prefix "$prefix" \
        --query 'length(Contents)' \
        --output text 2>/dev/null)
    
    echo "${count:-0}"
}

# Get prefixes
echo "Getting prefixes from source bucket..."
SOURCE_PREFIXES=$(get_prefixes "$SOURCE_BUCKET" "$SOURCE_PREFIX")

if [[ -z "$SOURCE_PREFIXES" ]]; then
    SOURCE_PREFIXES="$SOURCE_PREFIX"
fi

echo "Getting prefixes from destination bucket..."
DEST_PREFIXES=$(get_prefixes "$DEST_BUCKET" "$SOURCE_PREFIX")

if [[ -z "$DEST_PREFIXES" ]]; then
    DEST_PREFIXES="$SOURCE_PREFIX"
fi

# Combine and deduplicate all prefixes
ALL_PREFIXES=$(echo -e "${SOURCE_PREFIXES}\n${DEST_PREFIXES}" | sort -u)

echo ""
echo "Counting objects..."
echo ""

declare -A source_counts
declare -A dest_counts

total_prefixes=$(echo "$ALL_PREFIXES" | wc -l)
current=0

# Create temp files for parallel processing
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    
    ((current++))
    
    # Launch both counts in background
    (
        src=$(count_objects "$SOURCE_BUCKET" "$prefix")
        echo "$prefix::$src" >> "$tmpdir/source.txt"
        echo "[$current/$total_prefixes] ✓ Source: $prefix ($src objects)"
    ) &
    
    (
        dst=$(count_objects "$DEST_BUCKET" "$prefix")
        echo "$prefix::$dst" >> "$tmpdir/dest.txt"
        echo "[$current/$total_prefixes] ✓ Dest: $prefix ($dst objects)"
    ) &
    
    # Limit to 10 concurrent prefix pairs (20 total API calls)
    if ((current % 10 == 0)); then
        wait
    fi
    
done <<< "$ALL_PREFIXES"

# Wait for all remaining jobs
wait

echo ""
echo "Parsing results..."

# Read results into arrays
if [[ -f "$tmpdir/source.txt" ]]; then
    while IFS='::' read -r prefix count; do
        [[ -n "$prefix" ]] && source_counts["$prefix"]=$count
    done < "$tmpdir/source.txt"
fi

if [[ -f "$tmpdir/dest.txt" ]]; then
    while IFS='::' read -r prefix count; do
        [[ -n "$prefix" ]] && dest_counts["$prefix"]=$count
    done < "$tmpdir/dest.txt"
fi

echo "Source prefixes found: ${#source_counts[@]}"
echo "Dest prefixes found: ${#dest_counts[@]}"

echo ""
echo "================================================================================"
echo "RESULTS"
echo "================================================================================"
echo ""

matches=0
mismatches=0
total_source=0
total_dest=0

declare -a mismatch_list

while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    
    src=${source_counts[$prefix]:-0}
    dst=${dest_counts[$prefix]:-0}
    
    ((total_source += src))
    ((total_dest += dst))
    
    if [[ $src -ne $dst ]]; then
        mismatch_list+=("$prefix::$src::$dst")
        ((mismatches++))
    else
        ((matches++))
    fi
done <<< "$ALL_PREFIXES"

if [[ $mismatches -gt 0 ]]; then
    echo -e "${RED}MISMATCHED PREFIXES:${NC}"
    echo "--------------------------------------------------------------------------------"
    printf "%-60s %-15s %-15s\n" "Prefix" "Source" "Destination"
    echo "--------------------------------------------------------------------------------"
    
    for item in "${mismatch_list[@]}"; do
        IFS='::' read -r prefix src dst <<< "$item"
        printf "%-60s %-15s %-15s\n" "$prefix" "$src" "$dst"
    done
    
    echo ""
    echo -e "Total mismatches: ${RED}${mismatches}${NC}"
else
    echo -e "${GREEN}✓ No mismatches found!${NC}"
fi

echo ""
echo "Matching prefixes: ${matches}"

echo ""
echo "================================================================================"
printf "Total objects in %s/%s: %s\n" "$SOURCE_BUCKET" "$SOURCE_PREFIX" "$total_source"
printf "Total objects in %s/%s: %s\n" "$DEST_BUCKET" "$SOURCE_PREFIX" "$total_dest"
printf "Difference: %s\n" "$((total_source > total_dest ? total_source - total_dest : total_dest - total_source))"
echo "================================================================================"
echo ""