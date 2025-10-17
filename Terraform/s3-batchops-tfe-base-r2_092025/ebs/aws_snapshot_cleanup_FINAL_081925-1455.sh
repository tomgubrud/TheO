#!/bin/bash

################################################################################
# AWS Snapshot Cleanup Script (Pro Alternative, Final)
# ------------------------------------------------------------------------------
# Purpose:
#   • Discover EBS snapshots created in a specific year across ALL regions
#   • Exclude DLM-managed and AMI-backed snapshots (owner-agnostic)
#   • Verify delete permissions via --dry-run
#   • Perform deletions in batches (or do a dry-run) with robust logging
#   • Optional background run for LIVE deletes after a dry-run
#
# Requirements:
#   - Basic Linux (bash, awk, sed, grep, sort, coreutils)
#   - AWS CLI v2 in PATH
#   - IAM perms: DescribeRegions, DescribeSnapshots, DescribeImages, DeleteSnapshot
#
# Notes:
#   - No jq or Python required.
#   - Prompts ONLY for Access Key and Secret (no STS token).
################################################################################

set -euo pipefail

# ===== Constants & Files =====
BATCH_SIZE=50
LOG_DIR="logs"; 
TMP_DIR="tmp"
mkdir -p "$LOG_DIR" "$TMP_DIR"
LOG_FILE="$LOG_DIR/snapshot_cleanup_$(date +%Y%m%d_%H%M%S).log"; : >"$LOG_FILE"
DELETE_FILE="$LOG_DIR/snapshot_deletes_$(date +%Y%m%d_%H%M%S).txt"; : >"$DELETE_FILE"
FAILURE_LOG="$LOG_DIR/snapshot_failures_$(date +%Y%m%d_%H%M%S).log"; : >"$FAILURE_LOG"
EXCLUDED_LOG="$LOG_DIR/snapshot_excluded_$(date +%Y%m%d_%H%M%S).log"; : >"$EXCLUDED_LOG"
DLM_LOG="$LOG_DIR/snapshot_dlm_excluded_$(date +%Y%m%d_%H%M%S).log"; : >"$DLM_LOG"
RAW_FILE="$TMP_DIR/snapshots_raw_$(date +%s).txt"; : >"$RAW_FILE"
FILTERED_FILE="$TMP_DIR/snapshots_filtered_$(date +%s).txt"; : >"$FILTERED_FILE"
FINAL_FILE="$TMP_DIR/snapshots_final_$(date +%s).txt"; : >"$FINAL_FILE"

# ===== 1. Dry-run Prompt =====
read -p "Enable dry-run mode (no actual deletions)? (y/n): " DRY_RUN
MODE=$( [[ "$DRY_RUN" =~ ^[Yy]$ ]] && echo "DRY-RUN" || echo "LIVE" )
echo "[$(date)] Mode: $MODE" | tee -a "$LOG_FILE"

# ===== 2. AWS Credentials & Account ID =====
read -s -p "Enter AWS Access Key ID: " AWS_ACCESS_KEY_ID; echo
read -s -p "Enter AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY; echo
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>>"$LOG_FILE" || true)
if [[ -z "${ACCOUNT_ID:-}" || "$ACCOUNT_ID" == "None" ]]; then
  echo "ERROR: Unable to validate credentials via STS get-caller-identity." | tee -a "$LOG_FILE"
  exit 1
fi
echo "[$(date)] AWS Account ID: $ACCOUNT_ID" | tee -a "$LOG_FILE"

# ===== 3. Target Year =====
read -p "Enter snapshot creation year (YYYY): " YEAR
START_DATE="$YEAR-01-01"
END_DATE="$(($YEAR + 1))-01-01"
echo "[$(date)] Targeting snapshots from $START_DATE to $END_DATE" | tee -a "$LOG_FILE"

# ===== 4. Fetch Regions =====
echo "[$(date)] Fetching AWS regions..." | tee -a "$LOG_FILE"
REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>>"$LOG_FILE" | awk '{print $4}' |grep us-)

# ===== 5. Gather Snapshots (one line per snapshot; tags flattened) =====
echo "[$(date)] Gathering snapshots..." | tee -a "$LOG_FILE"
: >"$RAW_FILE"
for R in $REGIONS; do
  echo "[$(date)] Scanning $R" | tee -a "$LOG_FILE"
  aws ec2 describe-snapshots --region "$R" \
    --owner-ids "$ACCOUNT_ID"     \
    --query "Snapshots[?StartTime>=\`$START_DATE\` && StartTime<\`$END_DATE\`].[SnapshotId,StartTime,Description,(Tags && join(';', Tags[].join('=', [Key, Value]))) || '']"     \
    --output text 2>>"$LOG_FILE" | sed "s|^|$R |" >> "$RAW_FILE"
done
TOT_SNAP_COUNT=$(wc -l < "$RAW_FILE")

# ===== 6. Filter DLM Snapshots =====
echo "[$(date)] Excluding DLM snapshots..." | tee -a "$LOG_FILE"

# RAW_FILE lines: Region SnapshotId StartTime Description Tags(flat)
# Keep non-DLM lines; if none match, create empty file (no error).
grep -v 'aws:dlm:lifecycle-policy-id' "$RAW_FILE" > "$FILTERED_FILE" || : 

DLM_COUNT=$(comm -3 <(cut -d' ' -f2 "$RAW_FILE" | sort -u) <(cut -d' ' -f2 "$FILTERED_FILE" | sort -u) | wc -l | awk '{print $1}')
echo "[$(date)] Filtering out DLM-managed snapshots..." | tee -a "$LOG_FILE"
grep -v 'aws:dlm:lifecycle-policy-id' "$RAW_FILE" > "$FILTERED_FILE" || true
grep 'aws:dlm:lifecycle-policy-id' "$RAW_FILE" > "$DLM_LOG" || true
DLM_COUNT=$(wc -l < "$DLM_LOG")

# ===== 7. Exclude AMI-backed Snapshots (owner-agnostic, per-region) =====
echo "[$(date)] Excluding AMI-backed snapshots (owner-agnostic)..." | tee -a "$LOG_FILE"
: > "$FINAL_FILE"

for R in $REGIONS; do
  echo "[$(date)] Gathering AMI references in region $R..." | tee -a "$LOG_FILE"

  # Build CSV of snapshot IDs for this region (from FILTERED_FILE)
  REGION_IDS=$(grep -F "^$R " "$FILTERED_FILE" | awk '{print $2}' | sort -u | paste -sd, - 2>/dev/null)

  # If none in this region, continue
  [[ -z "$REGION_IDS" ]] && continue

  # Which of these IDs are referenced by ANY AMI in this region?
  AMI_USED_IDS=$(aws ec2 describe-images       --region "$R"       --filters "Name=block-device-mapping.snapshot-id,Values=$REGION_IDS"       --query "Images[].BlockDeviceMappings[].Ebs.SnapshotId"       --output text 2>>"$LOG_FILE" | tr '	' '
' | sort -u)

  # Now read ONLY this region’s lines and branch to EXCLUDED or FINAL
  grep -F "^$R " "$FILTERED_FILE" | while read -r L; do
    [[ -z "$L" ]] && continue
    RID=$(printf '%s
' "$L" | awk '{print $1}')
    SID=$(printf '%s
' "$L" | awk '{print $2}')

    # Safety: only process matching region
    [[ "$RID" != "$R" ]] && continue

    if printf '%s
' "$AMI_USED_IDS" | grep -qw -- "$SID"; then
      echo "$L" >> "$EXCLUDED_LOG"
    else
      echo "$L" >> "$FINAL_FILE"
    fi
  done

done

SNAP_COUNT=$(wc -l < "$FINAL_FILE" 2>/dev/null | awk '{print $1}')
EXCL_COUNT=$(wc -l < "$EXCLUDED_LOG" 2>/dev/null | awk '{print $1}')
echo "[$(date)] Eligible after DLM & AMI filters: $SNAP_COUNT | DLM Excluded: $DLM_COUNT | AMI Excluded: $EXCL_COUNT" | tee -a "$LOG_FILE"
echo "[$(date)] Excluding AMI-backed snapshots (any owner)..." | tee -a "$LOG_FILE"
: >"$FINAL_FILE"
for R in $REGIONS; do
  REGION_IDS=$(awk -v r="$R" '$1==r {print $2}' "$FILTERED_FILE" | sort -u | tr '\n' ',' | sed 's/,$//')
  [[ -z "$REGION_IDS" ]] && continue

  AMI_USED_IDS=$(aws ec2 describe-images     \
    --region "$R"     \
    --filters "Name=block-device-mapping.snapshot-id,Values=$REGION_IDS"     \
    --query "Images[].BlockDeviceMappings[].Ebs.SnapshotId"     \
    --output text 2>>"$LOG_FILE" | tr '\t' '\n' | sort -u)

  while read -r L; do
    [[ -z "$L" ]] && continue
    RID=$(echo "$L" | awk '{print $1}')
    SID=$(echo "$L" | awk '{print $2}')
    if [[ "$RID" == "$R" ]] && echo "$AMI_USED_IDS" | grep -qw "$SID"; then
      echo "$L" >> "$EXCLUDED_LOG"
    else
      echo "$L" >> "$FINAL_FILE"
    fi
  done < <(awk -v r="$R" '$1==r' "$FILTERED_FILE")
done

SNAP_COUNT=$(wc -l < "$FINAL_FILE" || echo 0)
EXCL_COUNT=$(wc -l < "$EXCLUDED_LOG" || echo 0)
echo "[$(date)] Eligible after DLM & AMI filters: $SNAP_COUNT | DLM Excluded: $DLM_COUNT | AMI Excluded: $EXCL_COUNT" | tee -a "$LOG_FILE"

# ===== 8. Show List (optional) =====
if [ $SNAP_COUNT -gt 0 ]; then
  read -p "Show eligible list before delete? (y/n): " SHOW
else
  echo "Nothing selected for deletion....exiting......" | tee -a "$LOG_FILE"
  exit 0
fi

if [[ "$SHOW" =~ ^[Yy]$ ]]; then
  cat "$FINAL_FILE" | tee -a "$LOG_FILE"
fi

# ===== 9. Confirm Deletion =====
read -p "Proceed to deletion? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborting." | tee -a "$LOG_FILE"
  exit 0
fi

# ===== 10. Dry-Run Permission Test (sample one) =====
echo "[$(date)] Testing delete-snapshot permission via --dry-run..." | tee -a "$LOG_FILE"
SAMPLE_LINE=$(head -n 1 "$FINAL_FILE" || true)
if [[ -z "${SAMPLE_LINE:-}" ]]; then
  echo "No eligible snapshots to test or delete. Exiting." | tee -a "$LOG_FILE"
  exit 0
fi
RS=$(awk '{print $1}' <<<"$SAMPLE_LINE")
SID=$(awk '{print $2}' <<<"$SAMPLE_LINE")
DRYOUT=$(aws ec2 delete-snapshot --snapshot-id "$SID" --region "$RS" --dry-run 2>&1 || true)
if echo "$DRYOUT" | grep -q "DryRunOperation"; then
  echo "Confirmed delete-snapshot permission via dry-run." | tee -a "$LOG_FILE"
else
  echo "ERROR: Delete-permission test failed." | tee -a "$LOG_FILE"
  echo "$DRYOUT" >> "$FAILURE_LOG"
  read -p "Continue anyway? (y/n): " CONT
  [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
fi

# ===== 11. Delete or Dry-Run in Batches (with runtime AMI check) =====
echo "[$(date)] Executing deletions..." | tee -a "$LOG_FILE"
CNT=0; SUCC=0; FAIL=0; RUNTIME_EXCL=0
DATEPFX="[$(date)]"

while read -r L; do
  R=$(printf '%s
' "$L" | awk '{print $1}')
  S=$(printf '%s
' "$L" | awk '{print $2}')
  [[ -z "$R" || -z "$S" ]] && continue

  # Runtime AMI safety check:
  AMI_ID=$(aws ec2 describe-images       --region "$R"       --filters "Name=block-device-mapping.snapshot-id,Values=$S"       --query "Images[0].ImageId"       --output text 2>>"$LOG_FILE" || true)
  if [[ "$AMI_ID" != "None" && -n "${AMI_ID:-}" ]]; then
    echo "$DATEPFX SKIP (AMI $AMI_ID uses $S in $R)" | tee -a "$LOG_FILE"
    echo "aws ec2 delete-snapshot --snapshot-id $S --region $R => skipped (AMI $AMI_ID)" >> "$EXCLUDED_LOG"
    RUNTIME_EXCL=$((RUNTIME_EXCL+1))
    CNT=$((CNT+1))
    (( CNT % BATCH_SIZE == 0 )) && sleep 1
    continue
  fi

  CMD="aws ec2 delete-snapshot --snapshot-id $S --region $R"
  echo "$CMD" >> "$DRY_RUN_FILE"

  if [[ "$DRY_RUN" =~ ^[Yy]$ ]]; then
    echo "$DATEPFX DRY-RUN: $S from $R" | tee -a "$LOG_FILE"
    SUCC=$((SUCC+1))
  else
    RES=$($CMD 2>&1 || true)
    if echo "$RES" | grep -qiE "in use|InvalidSnapshot.InUse"; then
      echo "$DATEPFX SKIP (in use): $S" | tee -a "$LOG_FILE"
      echo "$CMD => $RES" >> "$EXCLUDED_LOG"
      RUNTIME_EXCL=$((RUNTIME_EXCL+1))
    elif [[ -z "$RES" ]]; then
      echo "$DATEPFX Deleted: $S" | tee -a "$LOG_FILE"
      SUCC=$((SUCC+1))
    else
      if echo "$RES" | grep -qi "error\|Invalid"; then
        echo "$DATEPFX FAIL: $S" | tee -a "$LOG_FILE"
        echo "$CMD => $RES" >> "$FAILURE_LOG"
        FAIL=$((FAIL+1))
      else
        echo "$DATEPFX Deleted: $S" | tee -a "$LOG_FILE"
        SUCC=$((SUCC+1))
      fi
    fi
  fi

  CNT=$((CNT+1))
  (( CNT % BATCH_SIZE == 0 )) && sleep 1
done < "$FINAL_FILE"
echo "[$(date)] Executing deletions..." | tee -a "$LOG_FILE"
CNT=0; SUCC=0; FAIL=0; RUNTIME_EXCL=0
DATEPFX="[$(date)]"
while read -r L; do
  R=$(awk '{print $1}' <<<"$L")
  S=$(awk '{print $2}' <<<"$L")

  AMI_ID=$(aws ec2 describe-images     \
    --region "$R"     \
    --filters "Name=block-device-mapping.snapshot-id,Values=$S"     \
    --query "Images[0].ImageId"     \
    --output text 2>>"$LOG_FILE" || true)

  if [[ "$AMI_ID" != "None" && -n "${AMI_ID:-}" ]]; then
    echo "$DATEPFX SKIP (AMI $AMI_ID uses $S in $R)" | tee -a "$LOG_FILE"
    echo "aws ec2 delete-snapshot --snapshot-id $S --region $R => skipped (AMI $AMI_ID)" >> "$EXCLUDED_LOG"
    RUNTIME_EXCL=$((RUNTIME_EXCL+1))
    CNT=$((CNT+1))
    (( CNT % BATCH_SIZE == 0 )) && sleep 1
    continue
  fi

  CMD="aws ec2 delete-snapshot --snapshot-id $S --region $R"
  echo "$CMD" >> "$DRY_RUN_FILE"

  if [[ "$DRY_RUN" =~ ^[Yy]$ ]]; then
    echo "$DATEPFX DRY-RUN: $S from $R" | tee -a "$LOG_FILE"
    SUCC=$((SUCC+1))
  else
    RES=$($CMD 2>&1 || true)
    if echo "$RES" | grep -qiE "in use|InvalidSnapshot.InUse"; then
      echo "$DATEPFX SKIP (in use): $S" | tee -a "$LOG_FILE"
      echo "$CMD => $RES" >> "$EXCLUDED_LOG"
      RUNTIME_EXCL=$((RUNTIME_EXCL+1))
    elif [[ -z "$RES" ]]; then
      echo "$DATEPFX Deleted: $S" | tee -a "$LOG_FILE"
      SUCC=$((SUCC+1))
    else
      if echo "$RES" | grep -qi "error\|Invalid"; then
        echo "$DATEPFX FAIL: $S" | tee -a "$LOG_FILE"
        echo "$CMD => $RES" >> "$FAILURE_LOG"
        FAIL=$((FAIL+1))
      else
        echo "$DATEPFX Deleted: $S" | tee -a "$LOG_FILE"
        SUCC=$((SUCC+1))
      fi
    fi
  fi

  CNT=$((CNT+1))
  (( CNT % BATCH_SIZE == 0 )) && sleep 1
done < "$FINAL_FILE"

# ===== 12. Post Dry-Run Prompt (optional background LIVE run) =====
if [[ "$DRY_RUN" =~ ^[Yy]$ ]]; then
  read -p "Dry-run complete. Run LIVE deletes now (in background)? (y/n): " RUN_NOW
  if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    echo "[$(date)] Scheduling LIVE deletions in background..." | tee -a "$LOG_FILE"
    (
      echo "[$(date)] LIVE deletion started." | tee -a "$LOG_FILE"
      CNT=0; SUCC=0; FAIL=0; RUNTIME_EXCL=0
      DATEPFX="[$(date)]"
      while read -r L; do
        R=$(awk '{print $1}' <<<"$L")
        S=$(awk '{print $2}' <<<"$L")

        AMI_ID=$(aws ec2 describe-images           --region "$R"           --filters "Name=block-device-mapping.snapshot-id,Values=$S"           --query "Images[0].ImageId"           --output text 2>>"$LOG_FILE" || true)
        if [[ "$AMI_ID" != "None" && -n "${AMI_ID:-}" ]]; then
          echo "$DATEPFX SKIP (AMI $AMI_ID uses $S in $R)" | tee -a "$LOG_FILE"
          echo "aws ec2 delete-snapshot --snapshot-id $S --region $R => skipped (AMI $AMI_ID)" >> "$EXCLUDED_LOG"
          RUNTIME_EXCL=$((RUNTIME_EXCL+1))
          CNT=$((CNT+1))
          (( CNT % BATCH_SIZE == 0 )) && sleep 1
          continue
        fi

        CMD="aws ec2 delete-snapshot --snapshot-id $S --region $R"
        echo "$DATEPFX Deleting $S from $R" | tee -a "$LOG_FILE"
        RES=$($CMD 2>&1 || true)
        if echo "$RES" | grep -qiE "in use|InvalidSnapshot.InUse"; then
          echo "$DATEPFX SKIP (in use): $S" | tee -a "$LOG_FILE"
          echo "$CMD => $RES" >> "$EXCLUDED_LOG"
          RUNTIME_EXCL=$((RUNTIME_EXCL+1))
        elif [[ -z "$RES" ]]; then
          echo "$DATEPFX Deleted: $S" | tee -a "$LOG_FILE"
          SUCC=$((SUCC+1))
        else
          if echo "$RES" | grep -qi "error\|Invalid"; then
            echo "$DATEPFX FAIL: $S" | tee -a "$LOG_FILE"
            echo "$CMD => $RES" >> "$FAILURE_LOG"
            FAIL=$((FAIL+1))
          else
            echo "$DATEPFX Deleted: $S" | tee -a "$LOG_FILE"
            SUCC=$((SUCC+1))
          fi
        fi
        CNT=$((CNT+1))
        (( CNT % BATCH_SIZE == 0 )) && sleep 1
      done < "$FINAL_FILE"
      echo "[$(date)] LIVE deletion complete: Success=$SUCC Failures=$FAIL Skipped(in-use)=$RUNTIME_EXCL" | tee -a "$LOG_FILE"
    ) &
    echo "Background job PID: $!" | tee -a "$LOG_FILE"
    echo "Monitor progress at: $LOG_FILE" | tee -a "$LOG_FILE"
    exit 0
  fi
fi

# ===== 13. Summary & Cleanup =====
echo "------ Summary ------" | tee -a "$LOG_FILE"
echo "Eligible processed: $CNT | Deleted(Simulated if DRY): $SUCC | Failures: $FAIL | DLM Excluded: $DLM_COUNT | Skipped(in-use at runtime): $RUNTIME_EXCL | Pre-filter AMI exclusions: $EXCL_COUNT" | tee -a "$LOG_FILE"
echo "Delete/Dry-run commands: $DELETE_FILE"
if [[ -s "$FAILURE_LOG" ]]; then echo "Failures logged to: $FAILURE_LOG" | tee -a "$LOG_FILE"; fi
if [[ -s "$EXCLUDED_LOG" ]]; then echo "Excluded list: $EXCLUDED_LOG" | tee -a "$LOG_FILE"; fi
if [[ -s "$DLM_LOG" ]]; then echo "Excluded list: $DLM_LOG" | tee -a "$LOG_FILE"; fi

# Cleanup temps (keep logs)
rm -f "$RAW_FILE" "$FILTERED_FILE" "$FINAL_FILE"
