#!/bin/bash
# ebs_snapshot_delete_from_report.sh
# ------------------------------------------------------------------------
# Delete EBS snapshots that were flagged SafeToDeregister by
# ebs-snapshot-ami-usage.sh after AMIs have been handled by
# ami_deregister_from_report-v2.sh. Every action is logged for audit.
# ------------------------------------------------------------------------

set -euo pipefail

REGIONS_DEFAULT="us-east-2 us-west-2"
LOG_DIR="logs"
TMP_DIR="tmp"
mkdir -p "$LOG_DIR" "$TMP_DIR"

DATE_TAG="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/snapshot_delete_${DATE_TAG}.log"; : >"$LOG_FILE"
DRY_FILE="$LOG_DIR/snapshot_delete_cmds_${DATE_TAG}.log"; : >"$DRY_FILE"
FAIL_FILE="$LOG_DIR/snapshot_delete_fail_${DATE_TAG}.log"; : >"$FAIL_FILE"
SKIP_FILE="$LOG_DIR/snapshot_delete_skipped_${DATE_TAG}.log"; : >"$SKIP_FILE"
SUCCESS_FILE="$LOG_DIR/snapshot_delete_success_${DATE_TAG}.log"; : >"$SUCCESS_FILE"

FORCE_DELETE="N"
REGIONS="$REGIONS_DEFAULT"
CSV_PATH=""

log(){
  local message="$1"
  echo "$message"
  printf '%s\n' "$message" >>"$LOG_FILE"
}

usage() {
  cat <<EOF
Usage: $0 [--csv PATH] [--regions "us-east-2 us-west-2" | --regions ALL] [--force]
  --csv PATH     Path to CSV produced by ebs-snapshot-ami-usage.sh (prompts if omitted)
  --regions LIST Space-separated AWS regions to act on (default: "$REGIONS_DEFAULT")
  --regions ALL  Process every region found in the CSV
  --force        Delete even if the snapshot still shows as referenced by an AMI
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --csv" >&2
        exit 1
      fi
      CSV_PATH="$1"
      shift
      ;;
    --regions)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --regions" >&2
        exit 1
      fi
      REGIONS="$1"
      shift
      ;;
    --force)
      FORCE_DELETE="Y"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

read -p "Enable dry-run mode (no actual deletions)? (y/n): " DRY_RUN
MODE=$([[ "$DRY_RUN" =~ ^[Yy] ]] && echo "DRY-RUN" || echo "LIVE")
log "[$(date)] Mode: $MODE"

if [[ -z "$CSV_PATH" ]]; then
  read -p "Path to CSV from ebs-snapshot-ami-usage.sh: " CSV_PATH
fi
if [[ ! -f "$CSV_PATH" ]]; then
  log "ERROR: CSV not found: $CSV_PATH"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>>"$LOG_FILE" || echo "unknown")
log "[$(date)] AWS Account: $ACCOUNT_ID"
log "[$(date)] Using CSV: $CSV_PATH"

SAFE_ROWS=$(awk -F',' 'NR>1 && toupper($7) ~ /YES/' "$CSV_PATH" | wc -l | awk '{print $1}')
SAFE_UNIQUE=$(awk -F',' 'NR>1 && toupper($7) ~ /YES/ && $2 != "" {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' "$CSV_PATH" | sort -u | wc -l | awk '{print $1}')
log "[$(date)] CSV rows with SafeToDeregister=YES: $SAFE_ROWS"
log "[$(date)] Unique snapshots flagged in CSV: $SAFE_UNIQUE"

REGION_FILTER="$REGIONS"
if [[ -n "$REGION_FILTER" ]]; then
  REGIONS_COMPACT=$(echo "$REGION_FILTER" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  if [[ "$REGIONS_COMPACT" == "ALL" ]]; then
    REGION_FILTER=""
  fi
fi
if [[ -z "$REGION_FILTER" ]]; then
  log "[$(date)] Region filter: ALL regions in CSV"
else
  log "[$(date)] Region filter: $REGION_FILTER"
fi
log "[$(date)] Force delete on referenced snapshots: $FORCE_DELETE"

CANDIDATES="$TMP_DIR/snapshot_candidates_${DATE_TAG}.txt"; : >"$CANDIDATES"
awk -F',' -v region_filter="$REGION_FILTER" '
BEGIN {
  use_filter = (length(region_filter) > 0)
  if (use_filter) {
    n = split(region_filter, arr, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (arr[i] != "")
        allowed[arr[i]] = 1
    }
  }
}
NR > 1 {
  gsub(/\r/, "", $0)
  reg=$1; gsub(/^[ \t]+|[ \t]+$|"/,"",reg)
  snap=$2; gsub(/^[ \t]+|[ \t]+$|"/,"",snap)
  start=$3; gsub(/^[ \t]+|[ \t]+$|"/,"",start)
  ami=$4; gsub(/^[ \t]+|[ \t]+$|"/,"",ami)
  state=$5; gsub(/^[ \t]+|[ \t]+$|"/,"",state)
  launch=$6; gsub(/^[ \t]+|[ \t]+$|"/,"",launch)
  safe=$7; gsub(/^[ \t]+|[ \t]+$|"/,"",safe)
  if (snap == "" || reg == "")
    next
  if (toupper(safe) != "YES")
    next
  if (use_filter && !(reg in allowed))
    next
  key=reg "|" snap
  if (seen[key]++)
    next
  if (launch == "")
    launch = "never"
  printf "%s|%s|%s|%s|%s|%s|%s\n", reg, snap, start, ami, state, launch, safe
}
' "$CSV_PATH" > "$CANDIDATES"

TOTAL=$(wc -l < "$CANDIDATES" | awk '{print $1}')
if [[ "$TOTAL" -eq 0 ]]; then
  log "[$(date)] No snapshots matched SafeToDeregister=YES under the current filters. Exiting."
  exit 0
fi

log "[$(date)] Candidate snapshots to evaluate: $TOTAL"

CNT=0; SUCC=0; FAIL=0; SKIP=0; REFER=0; STATE_SKIP=0; MISSING=0
while IFS= read -r LINE || [[ -n "${LINE:-}" ]]; do
  LINE="${LINE//$'\r'/}"
  [[ -z "$LINE" ]] && continue
  IFS='|' read -r REGION SNAPSHOT SNAP_START CSV_AMI CSV_AMI_STATE CSV_LAUNCH SAFE_FLAG <<< "$LINE"

  # Trim any stray whitespace that could have slipped through (defensive)
  REGION="${REGION#"${REGION%%[![:space:]]*}"}"; REGION="${REGION%"${REGION##*[![:space:]]}"}"
  SNAPSHOT="${SNAPSHOT#"${SNAPSHOT%%[![:space:]]*}"}"; SNAPSHOT="${SNAPSHOT%"${SNAPSHOT##*[![:space:]]}"}"
  CSV_AMI="${CSV_AMI#"${CSV_AMI%%[![:space:]]*}"}"; CSV_AMI="${CSV_AMI%"${CSV_AMI##*[![:space:]]}"}"
  CSV_AMI_STATE="${CSV_AMI_STATE#"${CSV_AMI_STATE%%[![:space:]]*}"}"; CSV_AMI_STATE="${CSV_AMI_STATE%"${CSV_AMI_STATE##*[![:space:]]}"}"
  CSV_LAUNCH="${CSV_LAUNCH#"${CSV_LAUNCH%%[![:space:]]*}"}"; CSV_LAUNCH="${CSV_LAUNCH%"${CSV_LAUNCH##*[![:space:]]}"}"
  SNAP_START="${SNAP_START#"${SNAP_START%%[![:space:]]*}"}"; SNAP_START="${SNAP_START%"${SNAP_START##*[![:space:]]}"}"

  ((CNT++))
  log "[$(date)] [$CNT/$TOTAL] Snapshot $SNAPSHOT in $REGION (CSV AMI: ${CSV_AMI:-none})"

  SNAP_INFO=""
  if ! SNAP_INFO=$(aws ec2 describe-snapshots \
      --region "$REGION" \
      --snapshot-ids "$SNAPSHOT" \
      --query "Snapshots[0].[State,StartTime,VolumeId,VolumeSize]" \
      --output text 2>>"$LOG_FILE"); then
    log "[$(date)] Snapshot $SNAPSHOT not found or access denied. Skipping."
    echo "$REGION $SNAPSHOT missing_or_denied" >> "$SKIP_FILE"
    ((SKIP++)); ((MISSING++))
    continue
  fi

  read -r SNAP_STATE SNAP_ACTUAL_START SNAP_VOLUME SNAP_SIZE <<< "$SNAP_INFO"
  if [[ "$SNAP_STATE" != "completed" ]]; then
    log "[$(date)] SKIP: Snapshot state is $SNAP_STATE (needs completed)."
    echo "$REGION $SNAPSHOT state:$SNAP_STATE" >> "$SKIP_FILE"
    ((SKIP++)); ((STATE_SKIP++))
    continue
  fi

  AMI_CHECK=$(aws ec2 describe-images \
    --region "$REGION" \
    --filters "Name=block-device-mapping.snapshot-id,Values=$SNAPSHOT" \
    --query "Images[].ImageId" \
    --output text 2>>"$LOG_FILE" || true)
  AMI_CHECK=$(echo "$AMI_CHECK" | tr '\t' '\n' | sed '/^None$/d' | sed '/^$/d' | tr '\n' ' ')
  AMI_CHECK=$(echo "$AMI_CHECK" | sed 's/[[:space:]]*$//')

  if [[ -n "$AMI_CHECK" && "$FORCE_DELETE" != "Y" ]]; then
    log "[$(date)] SKIP: Snapshot is still referenced by AMI(s): $AMI_CHECK"
    echo "$REGION $SNAPSHOT referenced_by:$AMI_CHECK" >> "$SKIP_FILE"
    ((SKIP++)); ((REFER++))
    continue
  fi

  CMD="aws ec2 delete-snapshot --region $REGION --snapshot-id $SNAPSHOT"
  echo "$CMD" >> "$DRY_FILE"

  if [[ "$MODE" == "DRY-RUN" ]]; then
    log "[$(date)] DRY-RUN: Would delete snapshot $SNAPSHOT ($SNAP_SIZE GiB, started $SNAP_ACTUAL_START)."
    echo "$REGION $SNAPSHOT dry-run size:${SNAP_SIZE:-unknown} start:$SNAP_ACTUAL_START" >> "$SUCCESS_FILE"
    ((SUCC++))
    continue
  fi

  if DEL_OUT=$($CMD 2>&1); then
    log "[$(date)] Deleted snapshot $SNAPSHOT ($SNAP_SIZE GiB, started $SNAP_ACTUAL_START)."
    echo "$REGION $SNAPSHOT deleted size:${SNAP_SIZE:-unknown} start:$SNAP_ACTUAL_START" >> "$SUCCESS_FILE"
    ((SUCC++))
  else
    log "[$(date)] FAIL: Could not delete snapshot $SNAPSHOT."
    echo "$CMD => $DEL_OUT" >> "$FAIL_FILE"
    ((FAIL++))
  fi
done < "$CANDIDATES"

log "------ Summary ------"
log "Candidates evaluated: $TOTAL"
log "Deleted (or dry-run ready): $SUCC"
log "Skipped total: $SKIP | - Missing: $MISSING | - State != completed: $STATE_SKIP | - Referenced AMIs: $REFER"
log "Failures: $FAIL"

RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
DEST_DIR="$LOG_DIR/${ACCOUNT_ID}_${RUN_STAMP}_SNAP_DELETE"
mkdir -p "$DEST_DIR"
for f in "$LOG_FILE" "$DRY_FILE" "$FAIL_FILE" "$SKIP_FILE" "$SUCCESS_FILE" "$CANDIDATES" "$CSV_PATH"; do
  [[ -e "$f" ]] || continue
  base="$(basename -- "$f")"
  cp -p "$f" "$DEST_DIR/$base" 2>/dev/null || true
done
echo "Archived artifacts to $DEST_DIR"
