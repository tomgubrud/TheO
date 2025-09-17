locals {
  src_bucket_arn = "arn:aws:s3:::${var.src_bucket_name}"
  dst_bucket_arn = "arn:aws:s3:::${var.dst_bucket_name}"
}

data "aws_caller_identity" "this" {}

locals {
  account_id     = data.aws_caller_identity.this.account_id
  repl_role_arn  = "arn:aws:iam::${local.account_id}:role/${var.replication_role_name}"

  # Manifest Generator JSON (no saved manifest; we only use reports)
  manifest_generator_json = jsonencode({
    S3JobManifestGenerator = {
      ExpectedBucketOwner = local.account_id
      SourceBucket        = local.src_bucket_arn
      # Only items eligible for replication and not yet replicated
      Filter = {
        EligibleForReplication     = true
        ObjectReplicationStatuses  = ["NONE"]
      }
      EnableManifestOutput = false
    }
  })

  # Report JSON (reports land in DEST bucket/prefix)
  report_json = jsonencode({
    Bucket      = local.dst_bucket_arn
    Format      = "Report_CSV_20180820"
    Enabled     = true
    Prefix      = var.batch_report_prefix
    ReportScope = "AllTasks"
  })

  # Operation JSON – replicate objects
  operation_json = jsonencode({ S3ReplicateObject = {} })

  # A stable token so the request is idempotent when config is unchanged
  client_token = md5(join("|", [
    var.src_bucket_name,
    var.dst_bucket_name,
    var.replication_role_name,
    var.batch_report_prefix,
    local.manifest_generator_json,
    local.report_json,
    local.operation_json
  ]))
}

# Optional tiny sanity check that the AWS CLI exists
resource "null_resource" "precheck_cli" {
  count = var.enable_batch_job ? 1 : 0
  provisioner "local-exec" {
    command = "command -v aws >/dev/null 2>&1 || { echo 'ERROR: aws CLI not found on runner' >&2; exit 1; }"
    interpreter = ["/bin/bash", "-lc"]
  }
}

# Submit the S3 Batch Operations job
resource "null_resource" "s3_batch_backfill" {
  count = var.enable_batch_job ? 1 : 0

  # Re-run if anything in the payload changes (idempotent via client token)
  triggers = {
    token        = local.client_token
    region       = var.aws_region
    manifest     = local.manifest_generator_json
    report       = local.report_json
    operation    = local.operation_json
    src_bucket   = var.src_bucket_name
    dst_bucket   = var.dst_bucket_name
    role_arn     = local.repl_role_arn
  }

  # Make sure perms/policies are applied first if those resources exist in your stack
  depends_on = [
    # aws_s3_bucket_policy.dst,            # uncomment if defined in same plan
    # aws_kms_grant.dst_encrypt_for_replication,
    # aws_s3_bucket_replication_configuration.this
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOT
      set -euo pipefail

      aws s3control create-job \
        --region "${var.aws_region}" \
        --account-id "${local.account_id}" \
        --priority 10 \
        --role-arn "${local.repl_role_arn}" \
        --description "Backfill existing objects from ${var.src_bucket_name} to ${var.dst_bucket_name}" \
        --client-request-token "${self.triggers.token}" \
        --operation '${local.operation_json}' \
        --manifest-generator '${local.manifest_generator_json}' \
        --report '${local.report_json}' \
        --no-cli-pager \
        --query JobId --output text

      echo "Batch Ops backfill submitted successfully."
    EOT
  }
}
