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

