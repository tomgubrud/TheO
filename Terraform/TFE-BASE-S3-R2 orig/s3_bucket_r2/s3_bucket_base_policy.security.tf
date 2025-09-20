data "aws_iam_policy_document" "bucket_policy" {
  source_json = var.policy
  // using source_json instead of override_json so these statement cannot be overridden

  statement {
    sid     = "DenyKeyArnOtherThanAWS:KMS"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["arn:aws:s3:::${var.bucket_name}/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }

  statement {
    sid     = "DenyEncryptionOtherThanAWS:KMS"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["arn:aws:s3:::${var.bucket_name}/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid     = "DenyNonSSLTraffic"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    resources = ["arn:aws:s3:::${var.bucket_name}/*"]

    condition {
      test     = "Bool"
      values   = ["false"]
      variable = "aws:SecureTransport"
    }
  }

  statement {
    sid     = "AllowElasticaRole"
    effect  = "Allow"
    actions = [
      "s3:Get*",
      "s3:List*",
      "s3:PutObject*",
      "s3:PutBucketNotification"
    ]

    resources = [
      "arn:aws:s3:::${var.bucket_name}/*",
      "arn:aws:s3:::${var.bucket_name}"
    ]

    principals {
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/elastica-cloudtrail-role"]
      type        = "AWS"
    }
  }
}

data "aws_caller_identity" "current" {}
