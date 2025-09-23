resource "aws_iam_role" "batch_ops_role" {
  name = "${local.job_id}-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = {
          Service = [
            "batchoperations.s3.amazonaws.com",
            "s3.amazonaws.com" # allows the manifest generator to call into this role
          ]
        }
      }
    ]
  })
}

resource "aws_iam_policy" "batch_ops_policy" {
  name        = "${local.job_id}-policy"
  description = "Policy for S3 Batch Operations (${local.job_id})"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow managing/reading the job itself
      {
        Sid    = "S3Control"
        Effect = "Allow"
        Action = [
          "s3:CreateJob",
          "s3:DescribeJob",
          "s3:ListJobs",
          "s3:UpdateJobPriority",
          "s3:UpdateJobStatus"
        ]
        Resource = "*"
      },

      # Read from SOURCE
      {
        Sid    = "ReadSource"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:GetObjectVersionTagging",
          "s3:GetObjectAcl",
          "s3:GetObjectVersionAcl",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning"
        ]
        Resource = [
          var.source_bucket_arn,
          "${var.source_bucket_arn}/*"
        ]
      },

      # Write to DESTINATION (copied objects + BO owner override)
      {
        Sid    = "WriteDestination"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging",
          "s3:PutObjectAcl",
          "s3:ObjectOwnerOverrideToBucketOwner"
        ]
        Resource = [
          "${var.destination_bucket_arn}/*"
        ]
      },

      # Allow writing reports and generated manifests to DESTINATION
      {
        Sid    = "WriteReportsAndManifests"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = [
          "${var.destination_bucket_arn}/${local.report_prefix}/*",
          "${var.destination_bucket_arn}/${local.manifest_prefix}/*"
        ]
      },

      # KMS on source (decrypt)
      {
        Sid      = "KMSSource"
        Effect   = "Allow"
        Action   = [ "kms:Decrypt" ]
        Resource = var.source_kms_key_arn
      },

      # KMS on destination (encrypt)
      {
        Sid      = "KMSDestination"
        Effect   = "Allow"
        Action   = [ "kms:Encrypt", "kms:GenerateDataKey" ]
        Resource = var.destination_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.batch_ops_role.name
  policy_arn = aws_iam_policy.batch_ops_policy.arn
}
