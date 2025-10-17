#!/bin/bash
# list_ami_snapshot_usage.sh
# Shows snapshot creation date, AMI usage, AMI state, last time used, and if it appears safe to deregister.

REGIONS="us-east-2 us-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OUTFILE="snapshot_ami_usage_${ACCOUNT_ID}_$(date +%Y%m%d_%H%M%S).csv"

read -p "Only include snapshots created before which year (YYYY)? " YEAR
CUTOFF="${YEAR}-01-01T00:00:00Z"

echo "Region,SnapshotId,SnapshotStartTime,AMIId,AMIState,LastLaunchTime,SafeToDeregister" > "$OUTFILE"

for R in $REGIONS; do
  echo "Checking region: $R..."

  # Get all snapshots older than the cutoff
  SNAP_LIST=$(aws ec2 describe-snapshots \
      --region "$R" \
      --owner-ids "$ACCOUNT_ID" \
      --query "Snapshots[?StartTime<'$CUTOFF'].[SnapshotId,StartTime]" \
      --output text)

  # Build map of AMI usage (SnapshotId -> AMI info)
  declare -A SNAP_TO_AMI
  while read -r AMI_ID SNAP_ID; do
    SNAP_TO_AMI["$SNAP_ID"]="$AMI_ID"
  done < <(aws ec2 describe-images \
      --region "$R" \
      --owners self \
      --query "Images[].{AMI:ImageId,SNAPS:BlockDeviceMappings[].Ebs.SnapshotId}" \
      --output text | awk '{ami=$1; for (i=2;i<=NF;i++) print ami,$i}')

  # Build map of AMI last launch time
  declare -A AMI_LAUNCH_TIME
  while read -r IMGID LTIME; do
    [[ -n "$IMGID" && "$IMGID" != "None" ]] && AMI_LAUNCH_TIME["$IMGID"]="$LTIME"
  done < <(aws ec2 describe-instances \
      --region "$R" \
      --query "Reservations[].Instances[].[ImageId,LaunchTime]" \
      --output text | sort -k2 | uniq -w 10)

  # Walk snapshots and write CSV line
  while read -r SNAP_ID SNAP_START; do
    AMI_ID="${SNAP_TO_AMI[$SNAP_ID]:-}"
    if [[ -n "$AMI_ID" ]]; then
      AMI_STATE=$(aws ec2 describe-images --region "$R" --image-ids "$AMI_ID" \
                  --query "Images[0].State" --output text 2>/dev/null || echo "deregistered")
      LAST_LAUNCH="${AMI_LAUNCH_TIME[$AMI_ID]:-never}"
      if [[ "$LAST_LAUNCH" == "never" ]]; then
        SAFE="YES"
      else
        SAFE="NO"
      fi
      echo "$R,$SNAP_ID,$SNAP_START,$AMI_ID,$AMI_STATE,$LAST_LAUNCH,$SAFE" >> "$OUTFILE"
    else
      echo "$R,$SNAP_ID,$SNAP_START,,,,," >> "$OUTFILE"
    fi
  done <<< "$SNAP_LIST"

done

echo "Report written to $OUTFILE"
