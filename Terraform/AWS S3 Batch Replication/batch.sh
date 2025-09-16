#!/bin/bash

# --- config you can edit ---
export AWS_REGION=us-east-2
SRC_BUCKET="dev-sdp-repl-source-1-s3-bucket-ncz"
DST_BUCKET="dev-sdp-repl-target-1-s3-bucket-ncz"
REPORT_PREFIX="batch-replication-reports/"
ROLE_NAME="sdp-19-s3-replication"   # <-- your replication role name

# --- derive values ---
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

# --- create the Batch Replication job ---
aws s3control create-job \
  --region "$AWS_REGION" \
  --account-id "$ACCOUNT_ID" \
  --priority 10 \
  --role-arn "$ROLE_ARN" \
  --description "Backfill existing objects from $SRC_BUCKET to $DST_BUCKET" \
  --operation '{"S3ReplicateObject":{}}' \
  --manifest-generator "{
      \"S3JobManifestGenerator\":{
        \"ExpectedBucketOwner\":\"$ACCOUNT_ID\",
        \"SourceBucket\":\"arn:aws:s3:::$SRC_BUCKET\",
        \"Filter\": {\"ObjectReplicationStatuses\":[\"NONE\"]}
      }
    }" \
  --report "{
      \"Bucket\":\"arn:aws:s3:::$DST_BUCKET\",
      \"Format\":\"Report_CSV_20180820\",
      \"Enabled\":true,
      \"Prefix\":\"$REPORT_PREFIX\",
      \"ReportScope\":\"AllTasks\"
    }"
