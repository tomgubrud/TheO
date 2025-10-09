#!/usr/bin/env bash
SRC="s3://SOURCE"
DST="s3://DEST"
LOG="s3_sync_progress_$(date +%Y%m%d_%H%M%S).csv"

# Kick off sync in the background
aws s3 sync "$SRC" "$DST" \
  --recursive --exact-timestamps --delete --no-progress --only-show-errors &
SYNC_PID=$!

echo "timestamp,total_bytes,delta_bytes,mb_per_sec" | tee "$LOG"

# Prime the meter
prev_bytes=$(aws s3 ls "$DST" --recursive --summarize | awk '/Total Size:/{print $3}')
prev_ts=$(date +%s)

while kill -0 $SYNC_PID 2>/dev/null; do
  sleep 60
  now_bytes=$(aws s3 ls "$DST" --recursive --summarize | awk '/Total Size:/{print $3}')
  now_ts=$(date +%s)

  delta_b=$(( now_bytes - prev_bytes ))
  delta_s=$(( now_ts - prev_ts ))
  # Guard against zero or negative deltas during eventual consistency
  if [ $delta_s -gt 0 ] && [ $delta_b -ge 0 ]; then
    mbps=$(awk -v b="$delta_b" -v s="$delta_s" 'BEGIN{print (b/1024/1024)/s}')
    printf "%s,%s,%s,%.3f\n" "$(date -Iseconds)" "$now_bytes" "$delta_b" "$mbps" | tee -a "$LOG"
  fi

  prev_bytes=$now_bytes
  prev_ts=$now_ts
done

wait $SYNC_PID
echo "Sync finished. Full log in $LOG"
