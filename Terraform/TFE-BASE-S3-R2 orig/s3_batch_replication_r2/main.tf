// *********************** S3 Batch Replication (existing objects) ***********************

locals {
  src_id_split  = split(":", var.source_bucket_arn)
  dst_id_split  = split(":", var.destination_bucket_arn)
  source_id     = local.src_id_split[length(local.src_id_split) - 1]         # bucket-name
  destination_id= local.dst_id_split[length(local.dst_id_split) - 1]         # bucket-name

  replication_id = "${var.app_code}-${var.env_number}-batch-replication"

  report_bucket_arn = coalesce(var.report_bucket_arn, var.destination_bucket_arn)
}

data "aws_caller_identity" "current" {}

# ---- IAM role trusted by S3 Batch Operations -----------------------------------------
module "aws_iam_role" {
  source             = "git::https://github.crit.theocc.net/platform-engineering-org/tf-modules-base.git//aws/security/iam/role?ref=master"
  name               = local.replication_id
  description        = "IAM role for S3 Batch Replication (existing objects)"
  is_third_party     = false
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BatchOpsAssumeRole",
      "Effect": "Allow",
      "Principal": { "Service": "batchoperations.s3.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

# ---- Policy with the exact S3/KMS permissions (mirrors your replication policy) ------
resource "aws_iam_policy" "batch_policy" {
  name        = "${local.replication_id}-policy"
  description = "S3 Batch Replication Policy for ${local.replication_id}"
  policy      = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [ "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey" ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetReplicationConfiguration",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [ "${var.source_bucket_arn}" ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging",
        "s3:GetObjectRetention",
        "s3:GetObjectLegalHold",
        "s3:GetObject",
        "s3:ReplicateTags",
        "s3:GetObjectAttributes"
      ],
      "Resource": [ "${var.source_bucket_arn}/*" ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags",
        "s3:ObjectOwnerOverrideToBucketOwner",
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:PutObjectVersionAcl"
      ],
      "Resource": [ "${var.destination_bucket_arn}/*" ]
    },
    {
      "Effect": "Allow",
      "Action": [ "s3:GetBucketVersioning", "s3:PutBucketVersioning", "s3:ListBucket" ],
      "Resource": [ "${var.destination_bucket_arn}" ]
    },
    {
      "Effect": "Allow",
      "Action": [ "s3:PutObject" ],
      "Resource": [ "${local.report_bucket_arn}/*" ]
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = module.aws_iam_role.name
  policy_arn = aws_iam_policy.batch_policy.arn
}

# ---- Start the Batch Replication job (service-managed manifest for "eligible objects")
# We deliberately use the AWS CLI via local-exec to avoid provider version drift.
# Requires AWS CLI available in the execution environment.
resource "null_resource" "start_batch_replication" {
  count = var.create_job ? 1 : 0

  # Re-run only if the inputs change
  triggers = {
    account_id       = data.aws_caller_identity.current.account_id
    source_bucket_arn= var.source_bucket_arn
    destination_arn  = var.destination_bucket_arn
    report_bucket_arn= local.report_bucket_arn
    job_priority     = tostring(var.job_priority)
    manifest_prefix  = var.manifest_prefix
    report_prefix    = var.report_prefix
    role_arn         = module.aws_iam_role.arn
  }

  provisioner "local-exec" {
    interpreter = ["bash","-lc"]
    command = <<EOC
set -euo pipefail

aws s3control create-job \
  --account-id ${data.aws_caller_identity.current.account_id} \
  --priority ${var.job_priority} \
  --role-arn ${module.aws_iam_role.arn} \
  --description "Batch replication of existing objects from ${local.source_id} to ${local.destination_id}" \
  --operation '{"S3ReplicateObject":{}}' \
  --manifest-generator '{
    "S3JobManifestGenerator": {
      "ExpectedBucketOwner": "${data.aws_caller_identity.current.account_id}",
      "SourceBucket": "${var.source_bucket_arn}",
      "Filter": { "EligibleForReplication": true },
      "ManifestOutputLocation": {
        "S3Bucket": "${local.report_bucket_arn}",
        "ManifestPrefix": "${var.manifest_prefix}"
      }
    }
  }' \
  --report '{
    "Bucket": "${local.report_bucket_arn}",
    "Format": "Report_CSV_20180820",
    "Enabled": true,
    "ReportScope": "AllTasks",
    "Prefix": "${var.report_prefix}"
  }' \
  --query 'JobId' --output text | tee /dev/stderr
EOC
  }
}
