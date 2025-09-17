data "aws_caller_identity" "this" {}

locals {
  account_id          = data.aws_caller_identity.this.account_id
  src_bucket_arn      = "arn:aws:s3:::${var.src_bucket_name}"
  dst_bucket_arn      = "arn:aws:s3:::${var.dst_bucket_name}"
  replication_role_arn= "arn:aws:iam::${local.account_id}:role/${var.replication_role_name}"
}
