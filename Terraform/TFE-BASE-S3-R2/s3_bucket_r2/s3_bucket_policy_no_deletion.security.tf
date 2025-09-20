data "aws_iam_policy_document" "bucket_policy_no_deletion" {
  source_json = data.aws_iam_policy_document.bucket_policy.json

  //Update to prevent bucket deletion
  statement {
    sid       = "DoNotDeleteBucket"
    effect    = "Deny"
    actions   = ["s3:DeleteBucket"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["arn:aws:s3:::${var.bucket_name}"]
  }
}
