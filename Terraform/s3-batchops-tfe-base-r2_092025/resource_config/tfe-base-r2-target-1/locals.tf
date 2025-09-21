data "aws_caller_identity" "acct" {}


locals {
  account_id          = data.aws_caller_identity.this.account_id
  bucket_name     =   "tfe-base-r2-target-092125-1"
}