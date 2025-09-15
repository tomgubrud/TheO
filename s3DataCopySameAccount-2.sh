#!/bin/bash
# s3DataCopySameAccount.sh
# One-time copy of all objects from SRC bucket → TGT bucket
# Supports optional prefix-based copy, progress display (even in dry-run), and optional size check

set -euo pipefail

LOGDIR="./logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/s3_copy_$(date +%Y%m%d_%H%M%S).log"
SRC_COUNT_FILE="$LOGDIR/src_count.tmp"

exec > >(tee -a "$LOGFILE") 2>&1

echo "=== AWS S3 One-Time Copy with Re-Encryption ==="

# --- Secure credential prompts ---
read -s -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
echo
echo "Access Key ID entered (last 5 chars): ${AWS_ACCESS_KEY_ID: -5}"

read -s -p "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
echo
echo "Secret Key entered (last 5 chars): ${AWS_SECRET_ACCESS_KEY: -5}"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

# Verify credentials with STS
echo
echo ">>> Verifying credentials via STS..."
AWS_IDENTITY=$(aws sts get-caller-identity --output text --query 'Account')
AWS_ARN=$(aws sts get-caller-identity --output text --query 'Arn')

if [[ -z "$AWS_IDENTITY" ]]; then
  echo "ERROR: Unable to validate credentials with STS."
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  exit 1
fi

echo "Authenticated as: $AWS_ARN"
echo "Account ID      : $AWS_IDENTITY"
echo

# --- Prompts ---
read -p "Source bucket name: " SRC_BUCKET
read -p "Target bucket name: " TGT_BUCKET
read -p "Optional source prefix (e.g. tmp/ or blank for whole bucket): " SRC_PREFIX
read -p "Optional target prefix (e.g. tmp-test/ or blank to preserve source path): " TGT_PREFIX
read -p "Do you want to do a dry-run first? (y/n): " DRYRUN
read -p "Enable progress indicator during copy? (y/n): " PROGRESS_CHOICE
read -p "Progress update interval in seconds [30]: " PROGRESS_INTERVAL
PROGRESS_INTERVAL=${PROGRESS_INTERVAL:-30}
echo
read -p "Perform size comparison? (y/n) [Note: may be slow on very large buckets]: " SIZE_CHECK

# Normalize prefixes (strip leading '/', add trailing '/' if non-empty)
SRC_PREFIX="${SRC_PREFIX#/}"
TGT_PREFIX="${TGT_PREFIX#/}"
[[ -n "$SRC_PREFIX" && "${SRC_PREFIX: -1}" != "/" ]] && SRC_PREFIX="$SRC_PREFIX/"
[[ -n "$TGT_PREFIX" && "${TGT_PREFIX: -1}" != "/" ]] && TGT_PREFIX="$TGT_PREFIX/"

echo
echo ">>> Validating buckets..."

if aws s3api head-bucket --bucket "$SRC_BUCKET" >/dev/null 2>&1; then
  echo "Source bucket verification... Completed"
else
  echo "ERROR: Source bucket '$SRC_BUCKET' not accessible"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  exit 1
fi

if aws s3api head-bucket --bucket "$TGT_BUCKET" >/dev/null 2>&1; then
  echo "Target bucket verification... Completed"
else
  echo "ERROR: Target bucket '$TGT_BUCKET' not accessible"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  exit 1
fi

# --- Gather KMS Keys automatically ---
echo
echo ">>> Fetching KMS keys from bucket encryption configs..."

SRC_KEY=$(aws s3api get-bucket-encryption --bucket "$SRC_BUCKET"   --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID'   --output text 2>/dev/null || echo "")

TGT_KEY=$(aws s3api get-bucket-encryption --bucket "$TGT_BUCKET"   --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID'   --output text 2>/dev/null || echo "")

echo "Source bucket KMS key: ${SRC_KEY:-<none>}"
echo "Target bucket KMS key: ${TGT_KEY:-<none>}"
echo

# Count target objects before copy
TGT_COUNT_BEFORE=$(aws s3 ls "s3://$TGT_BUCKET/$TGT_PREFIX" --recursive 2>>"$LOGFILE" | wc -l || echo 0)
echo ">>> Target bucket object count : $TGT_COUNT_BEFORE (before copy)"
echo

# Build copy command
CMD="aws s3 cp s3://$SRC_BUCKET/$SRC_PREFIX s3://$TGT_BUCKET/$TGT_PREFIX --recursive --only-show-errors"

if [[ -n "$TGT_KEY" && "$TGT_KEY" != "None" ]]; then
  CMD="$CMD --sse aws:kms --sse-kms-key-id $TGT_KEY"
else
  CMD="$CMD --sse AES256" # fallback
fi

if [[ "$DRYRUN" =~ ^[Yy]$ ]]; then
  CMD="$CMD --dryrun"
fi

# --- Background source count (guarantee file even if 0) ---
rm -f "$SRC_COUNT_FILE"
(
  COUNT=$(aws s3 ls "s3://$SRC_BUCKET/$SRC_PREFIX" --recursive 2>>"$LOGFILE" | wc -l || echo 0)
  echo "$COUNT" > "$SRC_COUNT_FILE"
) &

# Wait until src_count.tmp exists (or timeout after 15s)
for i in {1..15}; do
  [[ -f "$SRC_COUNT_FILE" ]] && break
  sleep 1
done

TOTAL=$(cat "$SRC_COUNT_FILE" 2>/dev/null || echo "")

# --- Progress indicator ---
if [[ "$PROGRESS_CHOICE" =~ ^[Yy]$ ]]; then
  (
    echo "[Progress] monitor started..." | tee -a "$LOGFILE"
    # Print once immediately
    COPIED=$(aws s3 ls "s3://$TGT_BUCKET/$TGT_PREFIX" --recursive | wc -l)
    echo "[Progress] $COPIED / ${TOTAL:-??} objects copied" | tee -a "$LOGFILE"

    while true; do
      COPIED=$(aws s3 ls "s3://$TGT_BUCKET/$TGT_PREFIX" --recursive | wc -l)
      if [[ -n "$TOTAL" && "$TOTAL" -gt 0 ]]; then
        if (( COPIED >= TOTAL )); then
          echo "[Progress] $COPIED / $TOTAL objects copied (100%)" | tee -a "$LOGFILE"
          break
        fi
        PCT=$(( COPIED * 100 / TOTAL ))
        echo "[Progress] $COPIED / $TOTAL objects copied (${PCT}%)" | tee -a "$LOGFILE"
      else
        echo "[Progress] $COPIED / ?? objects copied" | tee -a "$LOGFILE"
      fi
      sleep $PROGRESS_INTERVAL
    done
  ) &
  PROGRESS_PID=$!
  trap "kill $PROGRESS_PID 2>/dev/null || true" EXIT
else
  PROGRESS_PID=""
fi

echo ">>> Running command:"
echo "$CMD"
echo

if [[ "$DRYRUN" =~ ^[Yy]$ ]]; then
  eval $CMD 2>&1 | grep -v '(dryrun) copy:'
  # Give monitor a chance to print once before cleanup
  sleep 5
else
  eval $CMD
fi

# Kill progress indicator if running (after sleep if dryrun)
if [[ -n "${PROGRESS_PID:-}" ]]; then
  kill $PROGRESS_PID 2>/dev/null || true
fi

# Ensure source count finishes
SRC_COUNT=$(cat "$SRC_COUNT_FILE" 2>/dev/null || echo "??")

# Count objects again
TGT_COUNT_AFTER=$(aws s3 ls "s3://$TGT_BUCKET/$TGT_PREFIX" --recursive | wc -l)

# --- Optional Size Comparison Section ---
if [[ "$SIZE_CHECK" =~ ^[Yy]$ ]]; then
  echo ">>> Calculating total size for source and target (this may take a while)..."
  SRC_SIZE=$(aws s3 ls "s3://$SRC_BUCKET/$SRC_PREFIX" --recursive | awk '{sum+=$3} END {print sum}')
  TGT_SIZE=$(aws s3 ls "s3://$TGT_BUCKET/$TGT_PREFIX" --recursive | awk '{sum+=$3} END {print sum}')
else
  SRC_SIZE="(skipped)"
  TGT_SIZE="(skipped)"
fi

echo
echo "=== Summary ==="
echo "Account ID                : $AWS_IDENTITY"
echo "Source bucket             : $SRC_BUCKET/${SRC_PREFIX:-}"
echo "Target bucket             : $TGT_BUCKET/${TGT_PREFIX:-}"
echo "Objects in source         : $SRC_COUNT"
echo "Objects in target before  : $TGT_COUNT_BEFORE"
echo "Objects in target after   : $TGT_COUNT_AFTER"
echo "Total size in source (B)  : $SRC_SIZE"
echo "Total size in target (B)  : $TGT_SIZE"
echo
echo "Log file saved to: $LOGFILE"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
echo "AWS credentials cleared from environment."
