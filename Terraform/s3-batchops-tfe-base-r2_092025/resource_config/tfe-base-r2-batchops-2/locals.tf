locals {
  acct_id  = data.aws_caller_identity.current.account_id
  job_name = "tfe-${var.app_code}-${var.env_number}-batchops-${var.purpose}"

  # deterministic token unless caller passes one
  crt      = coalesce(var.client_request_token,
              md5(join("|", [var.source_bucket_arn, var.destination_bucket_arn, var.purpose])))
}
