locals {
  job_name = "${var.app_code}-${var.env_number}-batchcopy"
  manifest_prefix = coalesce(var.manifest_prefix, var.report_prefix)
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ------- IAM role the job will assume -------
resource "aws_iam_role" "batch_role" {
  name               = "${local.job_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "batchoperations.s3.amazonaws.com" }
      Action   = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "batch_policy" {
  name   = "${local.job_name}-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read from source
      {
        Effect   = "Allow"
        Action   = [
          "s3:GetObject*",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.source_bucket_arn,
          "${var.source_bucket_arn}/*"
        ]
      },
      # Write to destination
      {
        Effect   = "Allow"
        Action   = [
          "s3:PutObject",
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ObjectOwnerOverrideToBucketOwner",
          "s3:AbortMultipartUpload",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.destination_bucket_arn,
          "${var.destination_bucket_arn}/*"
        ]
      },
      # KMS on both keys (decrypt source, encrypt destination)
      { 
        Effect   = "Allow"
        Action   = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:Encrypt",
        ]
        Resource = [
          var.source_kms_key_arn,
          var.destination_kms_key_arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.batch_role.name
  policy_arn = aws_iam_policy.batch_policy.arn
}

# ------- Create the Batch Ops job via AWS CLI -------
resource "null_resource" "create_job" {
  count = var.enable_batch_copy ? 1 : 0

  # re-run if inputs change
  triggers = {
    job       = local.job_name
    src       = var.source_bucket_arn
    dst       = var.destination_bucket_arn
    dstkms    = var.destination_kms_key_arn
    priority  = tostring(var.priority)
    purpose   = var.purpose
    region    = var.region
    role_arn  = aws_iam_role.batch_role.arn
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-lc"]
    command     = <<-BASH
      set -euo pipefail

      JOB="${local.job_name}"
      REGION="${var.region}"
      ACCOUNT="${data.aws_caller_identity.current.account_id}"
      SRC="${var.source_bucket_arn}"
      DST="${var.destination_bucket_arn}"
      DKMS="${var.destination_kms_key_arn}"
      ROLE="${aws_iam_role.batch_role.arn}"
      PRIORITY="${var.priority}"
      PURPOSE="${var.purpose}"
      PREFIX="${var.report_prefix}"

      TMPDIR="${path.module}/.tmp"
      mkdir -p "$TMPDIR"
      OP_JSON="$TMPDIR/${local.job_name}-op.json"

      # Build the CreateJob request using ManifestGenerator (no pre-uploaded manifest)
      cat > "$OP_JSON" <<JSON
      {
        "AccountId": "$ACCOUNT",
        "Operation": {
          "S3PutObjectCopy": {
            "TargetResource": "$DST",
            "MetadataDirective": "COPY",
            "SSEAwsKmsKeyId": "$DKMS"
          }
        },
        "ManifestGenerator": {
          "S3JobManifestGenerator": {
            "SourceBucket": "$SRC",
            "Filter": { "EligibleForReplication": true },
            "EnableManifestOutput": true,
            "ManifestOutputLocation": {
              "Bucket": "$DST",
              "Prefix": "${local.manifest_prefix}",
              "ManifestFormat": "S3InventoryReport_CSV_20211130",
              "ExpectedBucketOwner": "$ACCOUNT",
              "ManifestEncryption": { "SSEKMS": { "KeyId": "$DKMS" } }
            }
          }
        },
        "Priority": $PRIORITY,
        "RoleArn": "$ROLE",
        "Report": {
          "Enabled": true,
          "Bucket": "$DST",
          "Prefix": "$PREFIX/$JOB",
          "ReportScope": "AllTasks"
        },
        "ClientRequestToken": "$JOB",
        "Description": "$PURPOSE"
      }
      JSON

      # Create the job; token makes this idempotent
      aws s3control create-job \
        --region "$REGION" \
        --cli-input-json "file://$OP_JSON" >/dev/null

      echo "Created S3 Batch Operations job '$JOB' in $REGION"
    BASH
  }
}
