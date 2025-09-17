# Trust: S3 + Batch Ops
data "aws_iam_policy_document" "replication_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com", "batchoperations.s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = var.replication_role_name
  assume_role_policy = data.aws_iam_policy_document.replication_trust.json
}

# Allows:
# - Source bucket-level for Manifest Generator
# - Source object reads (incl. KMS/retention/hold)
# - Destination object writes for replication
# - Write Batch Ops report files under prefix in DEST
data "aws_iam_policy_document" "replication_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutInventoryConfiguration",
      "s3:GetInventoryConfiguration",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation"
    ]
    resources = [local.src_bucket_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObjectVersion",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectRetention",
      "s3:GetObjectLegalHold"
    ]
    resources = ["${local.src_bucket_arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
      "s3:ObjectOwnerOverrideToBucketOwner",
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectTagging"
    ]
    resources = ["${local.dst_bucket_arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.dst_bucket_arn}/${var.batch_report_prefix}*"]
  }
}

resource "aws_iam_role_policy" "replication_inline" {
  name   = "s3-replication"
  role   = aws_iam_role.replication.id
  policy = data.aws_iam_policy_document.replication_permissions.json
}
