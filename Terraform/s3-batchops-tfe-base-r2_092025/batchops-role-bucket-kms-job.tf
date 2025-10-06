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
data "aws_region" "current" {}

locals {
  job_name        = "${var.app_code}-${var.env_number}-batchcopy"
  dst_bucket_name = replace(var.destination_bucket_arn, "arn:${data.aws_partition.current.partition}:s3:::", "")
  src_bucket_name = replace(var.source_bucket_arn, "arn:${data.aws_partition.current.partition}:s3:::", "")
  
  op_json   = "/tmp/${local.job_name}-op.json"
  rep_json  = "/tmp/${local.job_name}-rep.json"
  mgen_json = "/tmp/${local.job_name}-mgen.json"
  
  manifest_prefix = "batchops/manifests"
  report_prefix   = "batchops/CompletionReports"
  
  manifest_bucket = local.dst_bucket_name
  report_bucket   = local.dst_bucket_name
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
  existing_bucket_policy = jsondecode(data.aws_s3_bucket_policy.destination.policy)
  
  updated_bucket_statements = [
    for stmt in local.existing_bucket_policy.Statement : 
    merge(stmt, 
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

# ---------- Generate manifest JSON for S3 Batch Operations ----------
resource "local_file" "manifest" {
  filename = local.mgen_json
  content = jsonencode({
    Bucket = local.src_bucket_name
    Format = "S3InventoryReport_CSV_20211130"
  })
}

# ---------- Create S3 Batch Operations Job ----------
resource "null_resource" "create_manifest" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws s3api list-objects-v2 \
        --bucket ${local.src_bucket_name} \
        --query 'Contents[].Key' \
        --output text | tr '\t' '\n' > /tmp/${local.job_name}-objects.txt
      
      # Create CSV manifest
      echo "Bucket,Key" > /tmp/${local.job_name}-manifest.csv
      while read key; do
        echo "${local.src_bucket_name},$key" >> /tmp/${local.job_name}-manifest.csv
      done < /tmp/${local.job_name}-objects.txt
      
      # Upload manifest to S3
      aws s3 cp /tmp/${local.job_name}-manifest.csv \
        s3://${local.manifest_bucket}/${local.manifest_prefix}/manifest.csv \
        --sse aws:kms \
        --sse-kms-key-id ${var.destination_kms_key_arn}
    EOT
  }

  depends_on = [
    aws_iam_role_policy_attachment.attach,
    aws_s3_bucket_policy.destination_updated,
    aws_kms_key_policy.destination_updated
  ]
}

# ---------- Create the batch operation specification ----------
resource "local_file" "batch_operation" {
  filename = local.op_json
  content = jsonencode({
    S3PutObjectCopy = {
      TargetResource                 = var.destination_bucket_arn
      CannedAccessControlList        = var.destination_acl
      StorageClass                   = var.destination_storage_class
      TargetKeyPrefix                = var.destination_prefix
      SSEAwsKmsKeyId                 = var.destination_kms_key_arn
      BucketKeyEnabled               = true
      ObjectLockLegalHoldStatus      = "OFF"
      ObjectLockMode                 = "COMPLIANCE"
      UnModifiedSinceConstraint      = null
    }
  })

  depends_on = [null_resource.create_manifest]
}

resource "local_file" "batch_report" {
  filename = local.rep_json
  content = jsonencode({
    Bucket      = local.report_bucket
    Prefix      = local.report_prefix
    Format      = "Report_CSV_20180820"
    Enabled     = true
    ReportScope = "AllTasks"
  })

  depends_on = [null_resource.create_manifest]
}

# ---------- Create and run S3 Batch Operations job ----------
resource "null_resource" "batch_job" {
  count = var.run_batch_job ? 1 : 0

  triggers = {
    manifest_created = null_resource.create_manifest.id
    role_arn         = aws_iam_role.batch_role.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      JOB_ID=$(aws s3control create-job \
        --account-id ${data.aws_caller_identity.current.account_id} \
        --region ${data.aws_region.current.name} \
        --no-confirmation-required \
        --operation file://${local.op_json} \
        --report file://${local.rep_json} \
        --manifest '{
          "Spec": {
            "Format": "S3BatchOperations_CSV_20180820",
            "Fields": ["Bucket", "Key"]
          },
          "Location": {
            "ObjectArn": "arn:${data.aws_partition.current.partition}:s3:::${local.manifest_bucket}/${local.manifest_prefix}/manifest.csv",
            "ETag": "$(aws s3api head-object --bucket ${local.manifest_bucket} --key ${local.manifest_prefix}/manifest.csv --query ETag --output text | tr -d '\"')"
          }
        }' \
        --role-arn ${aws_iam_role.batch_role.arn} \
        --priority 10 \
        --description "Batch copy from ${local.src_bucket_name} to ${local.dst_bucket_name}" \
        --query 'JobId' \
        --output text)
      
      echo "Created S3 Batch Job: $JOB_ID (auto-started, no confirmation required)"
      echo "$JOB_ID" > /tmp/${local.job_name}-job-id.txt
    EOT
  }

  depends_on = [
    local_file.batch_operation,
    local_file.batch_report,
    null_resource.create_manifest
  ]
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

output "manifest_location" {
  value       = "s3://${local.manifest_bucket}/${local.manifest_prefix}/manifest.csv"
  description = "S3 location of the batch operations manifest"
}

output "report_location" {
  value       = "s3://${local.report_bucket}/${local.report_prefix}/"
  description = "S3 location where completion reports will be written"
}

output "job_id_file" {
  value       = "/tmp/${local.job_name}-job-id.txt"
  description = "Local file containing the S3 Batch Job ID"
}