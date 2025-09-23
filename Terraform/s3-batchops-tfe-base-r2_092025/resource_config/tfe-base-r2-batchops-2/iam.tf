data "aws_caller_identity" "current" {}

# Role trusted by S3 Batch Operations
module "batchops_role" {
  source       = "git::https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/security/iam/role?ref=master"
  name         = local.job_name
  description  = "IAM role for S3 Batch Ops ${local.job_name}"
  is_third_party = false
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "batchoperations.s3.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
POLICY
}

# Minimal, explicit permissions for copy (SSE-KMS -> SSE-KMS)
resource "aws_iam_policy" "batchops_policy" {
  name        = "${local.job_name}-policy"
  description = "S3 BatchOps copy ${local.job_name}"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # Read source objects
      {
        Effect   = "Allow",
        Action   = [
          "s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectTagging",
          "s3:ListBucket", "s3:GetBucketLocation"
        ],
        Resource = [
          var.source_bucket_arn,
          "${var.source_bucket_arn}/*"
        ]
      },
      # Write destination objects (replicate semantics incl. tags/owner override)
      {
        Effect   = "Allow",
        Action   = [
          "s3:PutObject", "s3:PutObjectAcl", "s3:PutObjectTagging",
          "s3:ObjectOwnerOverrideToBucketOwner",
          "s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags",
          "s3:ListBucket", "s3:GetBucketLocation",
          "s3:AbortMultipartUpload", "s3:ListBucketMultipartUploads"
        ],
        Resource = [
          var.destination_bucket_arn,
          "${var.destination_bucket_arn}/*"
        ]
      },
      # KMS on source (decrypt) & destination (encrypt)
      {
        Effect   = "Allow",
        Action   = ["kms:Decrypt"],
        Resource = var.source_kms_key_arn
      },
      {
        Effect   = "Allow",
        Action   = ["kms:Encrypt", "kms:GenerateDataKey*", "kms:Decrypt"],
        Resource = var.destination_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = module.batchops_role.name
  policy_arn = aws_iam_policy.batchops_policy.arn
}
