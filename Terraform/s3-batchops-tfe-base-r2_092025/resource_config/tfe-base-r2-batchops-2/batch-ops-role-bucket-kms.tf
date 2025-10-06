terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.67"
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
  src_bucket_name = replace(var.source_bucket_arn, "arn:${data.aws_partition.current.partition}:s3:::", "")
  
  op_json   = "/tmp/${local.job_name}-op.json"
  rep_json  = "/tmp/${local.job_name}-rep.json"
  mgen_json = "/tmp/${local.job_name}-mgen.json"
  
  manifest_prefix = trimsuffix(var.manifest_prefix, "/")
  report_prefix   = trimsuffix(var.report_prefix, "/")
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

# ---------- Fetch existing destination bucket policy ----------
data "aws_s3_bucket_policy" "destination" {
  bucket = local.dst_bucket_name
}

locals {
  # Parse existing policy and prepare updated version
  existing_bucket_policy = jsondecode(data.aws_s3_bucket_policy.destination.policy)
  
  # Update existing deny statements to exclude batch role
  updated_bucket_statements = [
    for stmt in local.existing_bucket_policy.Statement : 
    merge(stmt, 
      # Add ArnNotEquals condition if this is a deny statement about KMS
      contains(["DenyKeyOtherThanAWS:KMS", "DenyEncryptionOtherthanAWS:KMS"], lookup(stmt, "Sid", "")) ? {
        Condition = merge(
          lookup(stmt, "Condition", {}),
          {
            ArnNotEquals = merge(
              lookup(lookup(stmt, "Condition", {}), "ArnNotEquals", {}),
              {
                "aws:PrincipalArn" = aws_iam_role.batch_role.arn
              }
            )
          }
        )
      } : {}
    )
  ]
}

# ---------- Update destination bucket policy ----------
resource "aws_s3_bucket_policy" "destination_updated" {
  bucket = local.dst_bucket_name
  
  policy = jsonencode({
    Version = local.existing_bucket_policy.Version
    Statement = local.updated_bucket_statements
  })
  
  depends_on = [aws_iam_role.batch_role]
}

# ---------- Fetch existing destination KMS key policy ----------
data "aws_kms_key" "destination" {
  key_id = var.destination_kms_key_arn
}

locals {
  existing_kms_policy = jsondecode(data.aws_kms_key.destination.policy)
  
  # Add new statement for batch operations role
  batch_kms_statement = {
    Sid    = "AllowS3BatchOperations"
    Effect = "Allow"
    Principal = {
      AWS = aws_iam_role.batch_role.arn
    }
    Action = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    Resource = "*"
  }
  
  updated_kms_statements = concat(
    local.existing_kms_policy.Statement,
    [local.batch_kms_statement]
  )
}

# ---------- Update destination KMS key policy ----------
resource "aws_kms_key_policy" "destination_updated" {
  key_id = var.destination_kms_key_arn
  
  policy = jsonencode({
    Version = local.existing_kms_policy.Version
    Statement = local.updated_kms_statements
  })
  
  depends_on = [aws_iam_role.batch_role]
}

# ---------- Outputs ----------
output "batch_role_arn" {
  value       = aws_iam_role.batch_role.arn
  description = "ARN of the S3 Batch Operations role"
}

output "batch_role_name" {
  value       = aws_iam_role.batch_role.name
  description = "Name of the S3 Batch Operations role"
}