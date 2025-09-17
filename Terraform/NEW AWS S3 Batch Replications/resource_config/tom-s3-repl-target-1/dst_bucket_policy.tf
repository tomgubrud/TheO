# Keep strict Denies, but exempt the replication role and add the Allows it needs.

data "aws_iam_policy_document" "dst_bucket_policy" {

  # Deny non-SSL
  statement {
    sid     = "DenyNonSSLTraffic"
    effect  = "Deny"
    actions = ["s3:*"]
    principals { 
        type = "*" 
        identifiers = ["*"] 
    }
    resources = ["${local.dst_bucket_arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Deny PutObject unless SSE-KMS, EXCEPT the replication role
  statement {
    sid     = "DenyEncryptionOtherThanAWSKMSExceptReplicationRole"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    not_principals {
      type        = "AWS"
      identifiers = [var.replication_role_arn]
    }

    resources = ["${local.dst_bucket_arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }

  # Deny PutObject unless the EXACT KMS key is used, EXCEPT the replication role
  statement {
    sid     = "DenyWrongKMSKeyExceptReplicationRole"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    not_principals {
      type        = "AWS"
      identifiers = [var.replication_role_arn]
    }

    resources = ["${local.dst_bucket_arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.dst_kms_key_arn]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
  }

  # Allow replication role to put replicas/ACL/tags (object-level)
  statement {
    sid    = "SetPermissionsForReplicationObjects"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.replication_role_arn]
    }

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

  # Allow Batch Ops to write report files to the report prefix
  statement {
    sid    = "AllowReplicationRoleWriteReports"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.replication_role_arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${local.dst_bucket_arn}/${var.batch_report_prefix}*"]
  }
}

resource "aws_s3_bucket_policy" "dst" {
  bucket = var.dst_bucket_name
  policy = data.aws_iam_policy_document.dst_bucket_policy.json
}
