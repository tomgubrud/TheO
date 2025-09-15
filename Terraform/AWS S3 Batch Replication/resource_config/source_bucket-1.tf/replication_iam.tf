data "aws_iam_policy_document" "replication_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["batchoperations.s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  name               = var.replication_role_name
  assume_role_policy = data.aws_iam_policy_document.replication_trust.json
}

data "aws_iam_policy_document" "replication_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:GetBucketVersioning"
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
      "s3:GetObjectLegalHold",
      "s3:GetObjectRetention"
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
    actions   = ["kms:Decrypt","kms:DescribeKey"]
    resources = [local.src_kms_key_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Encrypt","kms:GenerateDataKey*","kms:DescribeKey"]
    resources = [var.dst_kms_key_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${local.dst_bucket_arn}/${var.batch_report_prefix}*"]
  }
}

resource "aws_iam_policy" "replication" {
  name   = "${var.replication_role_name}-policy"
  policy = data.aws_iam_policy_document.replication_permissions.json
}

resource "aws_iam_role_policy_attachment" "replication_attach" {
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}
