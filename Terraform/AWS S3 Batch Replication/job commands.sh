JOB_ID="<paste JobId here>"

# Check status
aws s3control describe-job \
  --region "$AWS_REGION" \
  --account-id "$ACCOUNT_ID" \
  --job-id "$JOB_ID" \
  --query 'Job.Status'

# List recent jobs
aws s3control list-jobs --region "$AWS_REGION" --account-id "$ACCOUNT_ID" --max-results 20

# Cancel if needed
aws s3control update-job-status \
  --region "$AWS_REGION" \
  --account-id "$ACCOUNT_ID" \
  --job-id "$JOB_ID" \
  --requested-job-status Cancelled
