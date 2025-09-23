terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.67" # v5 is fine too; we only use common resources
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.1"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  job_name        = "${var.app_code}-${var.env_number}-batchcopy"
  dst_bucket_name = replace(var.destination_bucket_arn, "arn:${data.aws_partition.current.partition}:s3:::", "")
  src_bucket_name = replace(var.source_bucket_arn,       "arn:${data.aws_partition.current.partition}:s3:::", "")

  # Files we write on the runner (Jenkins/TFE VM)
  op_json   = "/tmp/${local.job_name}-op.json"
  rep_json  = "/tmp/${local.job_name}-rep.json"
  mgen_json = "/tmp/${local.job_name}-mgen.json"

  # Where AWS will write the generated manifest and the report (in S3)
  manifest_prefix = trimsuffix(var.manifest_prefix, "/")
  report_prefix   = trimsuffix(var.report_prefix,   "/")
}

# ---------- IAM for the S3 Batch job ----------
resource "aws_iam_role" "batch_role" {
  name = "${local.job_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = [
          "batchoperations.s3.amazonaws.com",
          "s3.amazonaws.com"
        ]
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "batch_policy" {
  name        = "${local.job_name}-policy"
  description = "Allow S3 Batch Operations to read source, write destination; KMS decrypt/encrypt"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read source objects
      {
        Effect   = "Allow"
        Action   = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:GetObjectVersionTagging",
          "s3:ListBucket"
        ]
        Resource = [
          var.source_bucket_arn,
          "${var.source_bucket_arn}/*"
        ]
      },
      # Write destination objects
      {
        Effect   = "Allow"
        Action   = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:PutObjectTagging",
          "s3:AbortMultipartUpload",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.destination_bucket_arn,
          "${var.destination_bucket_arn}/*"
        ]
      },
      # KMS on source (decrypt) + destination (encrypt)
      {
        Effect   = "Allow"
        Action   = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.source_kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = [
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = var.destination_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.batch_role.name
  policy_arn = aws_iam_policy.batch_policy.arn
}

# ---------- Create the S3 Batch job via AWS CLI ----------
# We intentionally do NOT use ${JOB}/${OP_JSON} shell vars to avoid Terraform interpolation errors.
resource "null_resource" "create_job" {
  count      = var.enable_batch_copy ? 1 : 0
  depends_on = [aws_iam_role_policy_attachment.attach]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail

      # 1) Operation JSON (copy -> dst bucket, SSE-KMS)
      cat > "${local.op_json}" <<JSON
      {
        "S3PutObjectCopy": {
          "TargetResource": "${var.destination_bucket_arn}",
          "CannedAccessControlList": "bucket-owner-full-control",
          "MetadataDirective": "COPY",
          "BucketKeyEnabled": true,
          "SSEAwsKmsKeyId": "${var.destination_kms_key_arn}"
        }
      }
      JSON

      # 2) Report JSON (CSV report written to destination bucket)
      cat > "${local.rep_json}" <<JSON
      {
        "Bucket": "${var.destination_bucket_arn}",
        "Format": "Report_CSV_20180820",
        "Enabled": true,
        "Prefix": "${local.report_prefix}/${local.job_name}/",
        "ReportScope": "AllTasks"
      }
      JSON

      # 3) Manifest Generator JSON (have AWS enumerate source bucket)
      cat > "${local.mgen_json}" <<JSON
      {
        "S3JobManifestGenerator": {
          "ExpectedBucketOwner": "${data.aws_caller_identity.current.account_id}",
          "SourceBucket": "${var.source_bucket_arn}",
          "ManifestOutputLocation": {
            "ExpectedManifestBucketOwner": "${data.aws_caller_identity.current.account_id}",
            "Bucket": "${var.destination_bucket_arn}",
            "ManifestEncryption": { "SSEKMS": { "KeyId": "${var.destination_kms_key_arn}" } },
            "ManifestFormat": "S3InventoryReport_CSV_20211130",
            "ManifestPrefix": "${local.manifest_prefix}/${local.job_name}/"
          },
          "Filter": {}
        }
      }
      JSON

      # 4) Create the job
      aws s3control create-job \
        --region "${var.region}" \
        --account-id "${data.aws_caller_identity.current.account_id}" \
        --priority ${var.job_priority} \
        --role-arn "${aws_iam_role.batch_role.arn}" \
        --client-request-token "${local.job_name}" \
        --description "${var.purpose}" \
        --operation "file://${local.op_json}" \
        --report    "file://${local.rep_json}" \
        --manifest-generator "file://${local.mgen_json}" \
        >/tmp/${local.job_name}-create.out

      echo "Batch job created (or idempotent). Details:"
      cat /tmp/${local.job_name}-create.out
    EOT
  }
}

output "batch_job_role_arn" {
  value = aws_iam_role.batch_role.arn
}

output "batch_job_name" {
  value = local.job_name
}
