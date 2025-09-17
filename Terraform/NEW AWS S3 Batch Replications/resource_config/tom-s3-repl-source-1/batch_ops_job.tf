# Optional backfill via S3 Batch Ops (CLI). Controlled by var.enable_batch_job.

locals {
  manifest_generator_json = jsonencode({
    S3JobManifestGenerator = {
      ExpectedBucketOwner = local.account_id
      SourceBucket        = local.src_bucket_arn
      Filter = {
        EligibleForReplication    = true
        ObjectReplicationStatuses = ["NONE"]
      }
      EnableManifestOutput = false
    }
  })
  report_json = jsonencode({
    Bucket      = local.dst_bucket_arn
    Format      = "Report_CSV_20180820"
    Enabled     = true
    Prefix      = var.batch_report_prefix
    ReportScope = "AllTasks"
  })
  operation_json = jsonencode({ S3ReplicateObject = {} })
  client_token = md5(join("|", [
    var.src_bucket_name, var.dst_bucket_name, var.replication_role_name,
    var.batch_report_prefix, local.manifest_generator_json, local.report_json, local.operation_json
  ]))
}

resource "null_resource" "batch_precheck" {
  count = var.enable_batch_job ? 1 : 0
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command     = "command -v aws >/dev/null 2>&1 || { echo 'AWS CLI not found' >&2; exit 1; }"
  }
}

resource "null_resource" "s3_batch_backfill" {
  count = var.enable_batch_job ? 1 : 0

  triggers = {
    token     = local.client_token
    region    = var.aws_region
    manifest  = local.manifest_generator_json
    report    = local.report_json
    operation = local.operation_json
  }

  depends_on = [
    aws_iam_role.replication,
    aws_iam_role_policy.replication_inline,
    aws_kms_grant.src_decrypt,
    aws_kms_grant.dst_encrypt,
    aws_s3_bucket_replication_configuration.this
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOT
      set -euo pipefail
      aws s3control create-job \
        --region "${var.aws_region}" \
        --account-id "${local.account_id}" \
        --priority 10 \
        --role-arn "${local.replication_role_arn}" \
        --description "Backfill existing objects from ${var.src_bucket_name} to ${var.dst_bucket_name}" \
        --client-request-token "${self.triggers.token}" \
        --operation '${local.operation_json}' \
        --manifest-generator '${local.manifest_generator_json}' \
        --report '${local.report_json}' \
        --no-cli-pager --query JobId --output text
    EOT
  }
}
