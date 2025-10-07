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

# Check for input file
if [[ -f "testinput" ]]; then
    echo "Reading configuration from testinput file..."
    
    # Check if comma-separated or newline-separated
    if grep -q ',' testinput; then
        IFS=',' read -r SOURCE_BUCKET DEST_BUCKET SOURCE_PREFIX < testinput
    else
        SOURCE_BUCKET=$(sed -n '1p' testinput)
        DEST_BUCKET=$(sed -n '2p' testinput)
        SOURCE_PREFIX=$(sed -n '3p' testinput)
    fi
    
    # Trim whitespace
    SOURCE_BUCKET=$(echo "$SOURCE_BUCKET" | xargs)
    DEST_BUCKET=$(echo "$DEST_BUCKET" | xargs)
    SOURCE_PREFIX=$(echo "$SOURCE_PREFIX" | xargs)
    
    echo "Loaded: Source=$SOURCE_BUCKET, Dest=$DEST_BUCKET, Prefix=$SOURCE_PREFIX"
else
    read -p "Source bucket name: " SOURCE_BUCKET
    read -p "Destination bucket name: " DEST_BUCKET
    read -p "Source prefix to check (press Enter for entire bucket): " SOURCE_PREFIX
fi

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
    
    echo "DEBUG: Running list-objects-v2 on bucket=$bucket prefix=$prefix" >&2
    
    local result=$(aws s3api list-objects-v2 \
        --bucket "$bucket" \
        --prefix "$prefix" \
        --delimiter "/" \
        --query 'CommonPrefixes[].Prefix' \
        --output text 2>&1)
    
    echo "DEBUG: Result=$result" >&2
    
    if [[ -n "$result" && "$result" != "None" ]]; then
        echo "$result" | tr '\t' '\n'
    fi
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
echo "DEBUG: Source prefixes found:"
echo "$SOURCE_PREFIXES"
echo ""

if [[ -z "$SOURCE_PREFIXES" ]]; then
    echo "No subprefixes found, using main prefix: $SOURCE_PREFIX"
    SOURCE_PREFIXES="$SOURCE_PREFIX"
fi

echo "Getting prefixes from destination bucket..."
DEST_PREFIXES=$(get_prefixes "$DEST_BUCKET" "$SOURCE_PREFIX")
echo "DEBUG: Dest prefixes found:"
echo "$DEST_PREFIXES"
echo ""

if [[ -z "$DEST_PREFIXES" ]]; then
    echo "No subprefixes found, using main prefix: $SOURCE_PREFIX"
    DEST_PREFIXES="$SOURCE_PREFIX"
fi

# Combine and deduplicate all prefixes
ALL_PREFIXES=$(echo -e "${SOURCE_PREFIXES}\n${DEST_PREFIXES}" | sort -u)

echo ""
echo "Counting objects..."
echo ""

# Debug: show what prefixes we found
echo "DEBUG: Prefixes to process:"
echo "$ALL_PREFIXES"
echo ""

declare -A source_counts
declare -A dest_counts

total_prefixes=$(echo "$ALL_PREFIXES" | grep -c .)
current=0

echo "Total prefixes to process: $total_prefixes"
echo ""

# Process each prefix
while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    
    ((current++))
    echo "[$current/$total_prefixes] Processing: $prefix"
    
    src=$(count_objects "$SOURCE_BUCKET" "$prefix")
    echo "  Source count: $src"
    
    dst=$(count_objects "$DEST_BUCKET" "$prefix")
    echo "  Dest count: $dst"
    
    source_counts["$prefix"]=$src
    dest_counts["$prefix"]=$dst
    
done <<< "$ALL_PREFIXES"

echo ""
echo "Counts collected: ${#source_counts[@]} prefixes"

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