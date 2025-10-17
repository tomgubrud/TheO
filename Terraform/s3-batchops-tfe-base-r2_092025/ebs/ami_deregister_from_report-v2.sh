#!/bin/bash
# ami_deregister_from_report.sh (v2)
# ------------------------------------------------------------------------
# Deregister AMIs based on the CSV produced by list_ami_snapshot_usage.sh
# CSV columns expected:
#   Region,SnapshotId,SnapshotStartTime,AMIId,AMIState,LastLaunchTime,SafeToDeregister
#
# Flow:
#   1) Run list_ami_snapshot_usage.sh (with cutoff), review CSV.
#   2) Run this script to DEREGISTER AMIs where SafeToDeregister == YES.
#   3) Run your FULL snapshot cleanup script to delete newly-orphaned snapshots.
#
# Safety:
#   - Dry-run mode (no changes).
#   - Skips AMIs referenced by Launch Templates or Auto Scaling Launch Configs
#     unless --force is supplied.
#
# Usage:
#   ./ami_deregister_from_report.sh [--force] [--regions "us-east-2 us-west-2"]
# ------------------------------------------------------------------------

set -euo pipefail

# ===== Configuration =====
REGIONS_DEFAULT="us-east-2 us-west-2"
LOG_DIR="logs"
TMP_DIR="tmp"
mkdir -p "$LOG_DIR" "$TMP_DIR"

DATE_TAG="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/ami_deregister_${DATE_TAG}.log"; : >"$LOG_FILE"
DRY_FILE="$LOG_DIR/ami_deregister_cmds_${DATE_TAG}.log"; : >"$DRY_FILE"
FAIL_FILE="$LOG_DIR/ami_deregister_fail_${DATE_TAG}.log"; : >"$FAIL_FILE"
SKIP_FILE="$LOG_DIR/ami_deregister_skipped_${DATE_TAG}.log"; : >"$SKIP_FILE"

# ===== Flags =====
FORCE_NOREFS="N"   # If Y, deregister even if references found
REGIONS="$REGIONS_DEFAULT"

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE_NOREFS="Y"; shift ;;
    --regions) shift; REGIONS="${1:-$REGIONS_DEFAULT}"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ===== Prompt for dry-run =====
read -p "Enable dry-run mode (no actual deregistration)? (y/n): " DRY_RUN
MODE=$([[ "$DRY_RUN" =~ ^[Yy] ]] && echo "DRY-RUN" || echo "LIVE")
echo "[$(date)] Mode: $MODE" | tee -a "$LOG_FILE"

# ===== Prompt for CSV file =====
read -p "Path to CSV from list_ami_snapshot_usage.sh: " CSV
if [[ ! -f "$CSV" ]]; then
  echo "ERROR: CSV not found: $CSV" | tee -a "$LOG_FILE"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>>"$LOG_FILE" || echo "unknown")
echo "[$(date)] AWS Account: $ACCOUNT_ID" | tee -a "$LOG_FILE"
echo "[$(date)] Regions: $REGIONS" | tee -a "$LOG_FILE"

# ===== CSV Summary (per your request) =====
YES_ROWS=$(awk -F',' 'NR>1 && toupper($7) ~ /YES/' "$CSV" | wc -l | awk '{print $1}')
YES_UNIQUE_AMIS=$(awk -F',' 'NR>1 && toupper($7) ~ /YES/ && $4 != "" {print $4}' "$CSV" | sort -u | wc -l | awk '{print $1}')
echo "[$(date)] YES rows in CSV (per-snapshot): $YES_ROWS" | tee -a "$LOG_FILE"
echo "[$(date)] Unique AMIs eligible by CSV (pre-check): $YES_UNIQUE_AMIS" | tee -a "$LOG_FILE"

# ===== Extract candidate AMIs (SafeToDeregister == YES) =====
CANDIDATES="$TMP_DIR/ami_candidates_${DATE_TAG}.txt"; : >"$CANDIDATES"
# Skip header; pick lines with YES; capture Region and AMIId; de-dup per AMI per region
awk -F',' 'NR>1 && toupper($7) ~ /YES/ && $4 != "" {gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$4); print $1" "$4}' "$CSV" \
  | sort -u > "$CANDIDATES"

TOTAL=$(wc -l < "$CANDIDATES" | awk '{print $1}')
if [[ "$TOTAL" -eq 0 ]]; then
  echo "[$(date)] No AMIs flagged SafeToDeregister=YES found in CSV. Exiting." | tee -a "$LOG_FILE"
  exit 0
fi

echo "[$(date)] Found $TOTAL candidate AMIs to deregister (pre-checks)." | tee -a "$LOG_FILE"

# ===== Helper: check references =====
check_references() {
  local region="$1"
  local ami="$2"

  # 1) Launch Templates (any version). No direct filter by ImageId, so grep output.
  local lt_ids
  lt_ids=$(aws ec2 describe-launch-templates --region "$region" \
             --query "LaunchTemplates[].LaunchTemplateId" --output text 2>>"$LOG_FILE" | tr '\t' '\n' || true)
  if [[ -n "${lt_ids:-}" ]]; then
    while read -r lt; do
      [[ -z "$lt" ]] && continue
      if aws ec2 describe-launch-template-versions --region "$region" --launch-template-id "$lt" \
           --versions All --output text 2>>"$LOG_FILE" | grep -qw "$ami"; then
        echo "LT:$lt"
        return 0
      fi
    done <<< "$lt_ids"
  fi

  # 2) Autoscaling Launch Configurations referencing the AMI
  local lc_match
  lc_match=$(aws autoscaling describe-launch-configurations --region "$region" \
               --query "LaunchConfigurations[?ImageId=='$ami'].LaunchConfigurationName" \
               --output text 2>>"$LOG_FILE" || true)
  if [[ -n "${lc_match:-}" ]]; then
    echo "LC:$lc_match"
    return 0
  fi

  return 1  # no references found
}

# ===== Process candidates =====
CNT=0; SUCC=0; FAIL=0; SKIP=0; ALREADY=0; REFER=0
while read -r REGION AMI_ID; do
  ((CNT++))
  echo "[$(date)] [$CNT/$TOTAL] Checking $AMI_ID in $REGION ..." | tee -a "$LOG_FILE"

  # Reconfirm AMI exists or is already deregistered
  AMI_STATE=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" \
               --query "Images[0].State" --output text 2>>"$LOG_FILE" || echo "deregistered")

  if [[ "$AMI_STATE" == "None" || "$AMI_STATE" == "deregistered" ]]; then
    echo "[$(date)] AMI $AMI_ID already deregistered or not found. Skipping." | tee -a "$LOG_FILE"
    echo "$REGION $AMI_ID already_deregistered" >> "$SKIP_FILE"
    ((SKIP++)); ((ALREADY++))
    continue
  fi

  # Safety: check if referenced by Launch Templates or Launch Configs
  REF=$(check_references "$REGION" "$AMI_ID" || true)
  if [[ -n "${REF:-}" && "$FORCE_NOREFS" != "Y" ]]; then
    echo "[$(date)] SKIP: $AMI_ID is referenced ($REF). Use --force to override." | tee -a "$LOG_FILE"
    echo "$REGION $AMI_ID referenced:$REF" >> "$SKIP_FILE"
    ((SKIP++)); ((REFER++))
    continue
  fi

  CMD="aws ec2 deregister-image --region $REGION --image-id $AMI_ID"
  echo "$CMD" >> "$DRY_FILE"

  if [[ "$MODE" == "DRY-RUN" ]]; then
    echo "[$(date)] DRY-RUN: $AMI_ID in $REGION" | tee -a "$LOG_FILE"
    ((SUCC++))
  else
    if RES=$($CMD 2>&1); then
      echo "[$(date)] Deregistered: $AMI_ID ($REGION)" | tee -a "$LOG_FILE"
      ((SUCC++))
    else
      echo "[$(date)] FAIL: $AMI_ID ($REGION)" | tee -a "$LOG_FILE"
      echo "$CMD => $RES" >> "$FAIL_FILE"
      ((FAIL++))
    fi
  fi

done < "$CANDIDATES"

echo "------ Summary ------" | tee -a "$LOG_FILE"
echo "CSV YES rows (per-snapshot): $YES_ROWS" | tee -a "$LOG_FILE"
echo "CSV unique AMIs (pre-check): $YES_UNIQUE_AMIS" | tee -a "$LOG_FILE"
echo "Candidates processed (de-duped): $TOTAL" | tee -a "$LOG_FILE"
echo "Deregistered: $SUCC | Skipped: $SKIP | - Already deregistered: $ALREADY | - Referenced (LT/LC): $REFER | Failures: $FAIL" | tee -a "$LOG_FILE"

# ===== Archive all outputs =====
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
DEST_DIR="$LOG_DIR/${ACCOUNT_ID}_${RUN_STAMP}_AMI_DEREG"
mkdir -p "$DEST_DIR"
for f in "$LOG_FILE" "$DRY_FILE" "$FAIL_FILE" "$SKIP_FILE" "$CANDIDATES" "$CSV"; do
  [[ -e "$f" ]] || continue
  base="$(basename -- "$f")"
  cp -p "$f" "$DEST_DIR/$base" 2>/dev/null || true
done
echo "Archived artifacts to $DEST_DIR"
