data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # stable, idempotent client token / job id
  job_id = "${var.app_code}-${tostring(var.env_number)}-${var.purpose}-batch"

  manifest_prefix = var.manifest_prefix
  report_prefix   = var.report_prefix
}
