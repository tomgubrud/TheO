resource "null_resource" "create_job" {
  count = var.enable_batch_copy ? 1 : 0

  triggers = {
    job_id               = local.job_id
    account_id           = local.account_id
    region               = local.region
    role_arn             = aws_iam_role.batch_ops_role.arn
    source_bucket_arn    = var.source_bucket_arn
    dest_bucket_arn      = var.destination_bucket_arn
    dest_kms_key_arn     = var.destination_kms_key_arn
    report_prefix        = local.report_prefix
    manifest_prefix      = local.manifest_prefix
    job_priority         = tostring(var.job_priority)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOT
      set -euo pipefail

      JOB="${local.job_id}"
      ACCOUNT="${local.account_id}"
      REGION="${local.region}"
      ROLE="${aws_iam_role.batch_ops_role.arn}"

      SRC="${var.source_bucket_arn}"
      DST="${var.destination_bucket_arn}"
      DKMS="${var.destination_kms_key_arn}"
      REPORT_PREFIX="${local.report_prefix}"
      MANIFEST_PREFIX="${local.manifest_prefix}"
      PRIORITY=${var.job_priority}

      # Build JSON payloads into temp files (avoids quoting issues)
      MGEN_JSON="/tmp/${JOB}-mgen.json"
      OP_JSON="/tmp/${JOB}-op.json"
      REP_JSON="/tmp/${JOB}-rep.json"

      cat > "${MGEN_JSON}" <<JSON
{
  "S3JobManifestGenerator": {
    "ExpectedBucketOwner": "${ACCOUNT}",
    "SourceBucket": "${SRC}",
    "EnableManifestOutput": true,
    "ManifestOutputLocation": {
      "Bucket": "${DST}",
      "ManifestPrefix": "${MANIFEST_PREFIX}/${JOB}",
      "ManifestEncryption": { "SSEKMS": { "KeyId": "${DKMS}" } },
      "ManifestFormat": "S3InventoryReport_CSV_20211130"
    }
  }
}
JSON

      cat > "${OP_JSON}" <<JSON
{
  "S3PutObjectCopy": {
    "TargetResource": "${DST}",
    "CannedAccessControlList": "bucket-owner-full-control",
    "SSEAwsKmsKeyId": "${DKMS}"
  }
}
JSON

      cat > "${REP_JSON}" <<JSON
{
  "Bucket": "${DST}",
  "Prefix": "${REPORT_PREFIX}",
  "Format": "Report_CSV_20180820",
  "Enabled": true,
  "ReportScope": "AllTasks"
}
JSON

      # Create the job (idempotent via client request token)
      aws s3control create-job \
        --region "${REGION}" \
        --account-id "${ACCOUNT}" \
        --no-confirmation-required \
        --priority "${PRIORITY}" \
        --description "${var.purpose} ${JOB}" \
        --client-request-token "${JOB}" \
        --role-arn "${ROLE}" \
        --manifest-generator "file://${MGEN_JSON}" \
        --operation "file://${OP_JSON}" \
        --report "file://${REP_JSON}" \
      || echo "Job may already exist for token ${JOB}; continuing."

      rm -f "${MGEN_JSON}" "${OP_JSON}" "${REP_JSON}"
    EOT
  }

  depends_on = [aws_iam_role_policy_attachment.attach]
}
