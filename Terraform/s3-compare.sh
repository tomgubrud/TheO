#!/bin/bash
# S3 Bucket Object Count Comparison Tool
# Requires: AWS CLI v2

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "================================================================================"
echo "S3 Bucket Object Count Comparison Tool"
echo "================================================================================"

# Get inputs
read -p "Source bucket name: " SOURCE_BUCKET
read -p "Destination bucket name: " DEST_BUCKET
read -p "Source prefix to check (press Enter for entire bucket): " SOURCE_PREFIX

# Add trailing slash if prefix provided and doesn't have one
if [[ -n "$SOURCE_PREFIX" ]] && [[ "$SOURCE_PREFIX" != */ ]]; then
    SOURCE_PREFIX="${SOURCE_PREFIX}/"
fi

# Validate AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI not found. Please install AWS CLI v2."
    exit 1
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

TEMP_DIR=$(mktemp -d)

SOURCE_FILE="${TEMP_DIR}/source_counts.txt"
DEST_FILE="${TEMP_DIR}/dest_counts.txt"
SOURCE_PREFIXES="${TEMP_DIR}/source_prefixes.txt"
DEST_PREFIXES="${TEMP_DIR}/dest_prefixes.txt"

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Function to get all prefixes (directories) under a path
get_prefixes() {
    local bucket=$1
    local prefix=$2
    local output_file=$3
    
    echo "Scanning prefixes in ${bucket}/${prefix}..."
    
    aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --prefix "$prefix" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text | tr '\t' '\n' > "$output_file"
    
    # If no prefixes found, just count the prefix itself
    if [[ ! -s "$output_file" ]]; then
        echo "$prefix" > "$output_file"
    fi
}

# Function to count objects for a specific prefix
count_objects() {
    local bucket=$1
    local prefix=$2
    
    aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --prefix "$prefix" \
        --query 'length(Contents)' \
        --output text 2>/dev/null || echo "0"
}

# Function to count objects in parallel for all prefixes
count_all_parallel() {
    local bucket=$1
    local prefix=$2
    local output_file=$3
    local prefix_file=$4
    
    echo "Counting objects in ${bucket}/${prefix}..."
    
    > "$output_file"
    
    local count=0
    local total=$(wc -l < "$prefix_file")
    
    # Process prefixes in parallel (max 20 at a time)
    export -f count_objects
    export bucket
    
    cat "$prefix_file" | parallel -j 20 --line-buffer --tagstring '{}' \
        "echo {}::\$(count_objects $bucket {})" >> "$output_file" 2>/dev/null || {
        # Fallback if parallel not available - do sequential with background jobs
        echo "Warning: 'parallel' command not found, using slower sequential processing..."
        while IFS= read -r pfx; do
            (
                cnt=$(count_objects "$bucket" "$pfx")
                echo "${pfx}::${cnt}" >> "$output_file"
            ) &
            
            # Limit to 20 concurrent jobs
            if [[ $(jobs -r -p | wc -l) -ge 20 ]]; then
                wait -n
            fi
            
            ((count++))
            if ((count % 10 == 0)) || ((count == total)); then
                echo "  Progress: ${count}/${total} prefixes counted"
            fi
        done < "$prefix_file"
        wait
    }
    
    echo "Completed counting ${bucket}"
}

# Get prefixes for both buckets in parallel
get_prefixes "$SOURCE_BUCKET" "$SOURCE_PREFIX" "$SOURCE_PREFIXES" &
PID1=$!
get_prefixes "$DEST_BUCKET" "$SOURCE_PREFIX" "$DEST_PREFIXES" &
PID2=$!
wait $PID1 $PID2

echo ""

# Count objects in both buckets in parallel
count_all_parallel "$SOURCE_BUCKET" "$SOURCE_PREFIX" "$SOURCE_FILE" "$SOURCE_PREFIXES" &
PID1=$!
count_all_parallel "$DEST_BUCKET" "$SOURCE_PREFIX" "$DEST_FILE" "$DEST_PREFIXES" &
PID2=$!
wait $PID1 $PID2

echo ""
echo "================================================================================"
echo "RESULTS"
echo "================================================================================"
echo ""

# Parse results and compare
declare -A source_counts
declare -A dest_counts

if [[ -f "$SOURCE_FILE" ]]; then
    while IFS='::' read -r prefix count; do
        [[ -n "$prefix" ]] && source_counts["$prefix"]=$count
    done < "$SOURCE_FILE"
fi

if [[ -f "$DEST_FILE" ]]; then
    while IFS='::' read -r prefix count; do
        [[ -n "$prefix" ]] && dest_counts["$prefix"]=$count
    done < "$DEST_FILE"
fi

# Get all unique prefixes
all_prefixes=$(printf '%s\n' "${!source_counts[@]}" "${!dest_counts[@]}" | sort -u)

matches=0
mismatches=0
total_source=0
total_dest=0

MISMATCH_FILE="${TEMP_DIR}/mismatches.txt"
> "$MISMATCH_FILE"

while IFS= read -r pfx; do
    src_count=${source_counts[$pfx]:-0}
    dst_count=${dest_counts[$pfx]:-0}
    
    ((total_source += src_count))
    ((total_dest += dst_count))
    
    if [[ $src_count -ne $dst_count ]]; then
        echo "${pfx}::${src_count}::${dst_count}" >> "$MISMATCH_FILE"
        ((mismatches++))
    else
        ((matches++))
    fi
done <<< "$all_prefixes"

# Display mismatches
if [[ $mismatches -gt 0 ]]; then
    echo -e "${RED}MISMATCHED PREFIXES:${NC}"
    echo "--------------------------------------------------------------------------------"
    printf "%-60s %-15s %-15s\n" "Prefix" "Source" "Destination"
    echo "--------------------------------------------------------------------------------"
    
    while IFS='::' read -r prefix src dst; do
        printf "%-60s %-15s %-15s\n" "$prefix" "$(printf "%'d" $src)" "$(printf "%'d" $dst)"
    done < "$MISMATCH_FILE"
    
    echo ""
    echo -e "Total mismatches: ${RED}${mismatches}${NC}"
else
    echo -e "${GREEN}✓ No mismatches found!${NC}"
fi

echo ""
echo "Matching prefixes: ${matches}"

echo ""
echo "================================================================================"
printf "Total objects in %s/%s: %'d\n" "$SOURCE_BUCKET" "$SOURCE_PREFIX" "$total_source"
printf "Total objects in %s/%s: %'d\n" "$DEST_BUCKET" "$SOURCE_PREFIX" "$total_dest"
printf "Difference: %'d\n" "$((total_source > total_dest ? total_source - total_dest : total_dest - total_source))"
echo "================================================================================"
echo ""