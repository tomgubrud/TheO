output "job_client_token" {
  description = "Idempotent client token we used when creating the job."
  value       = local.job_id
}

output "batch_ops_role_arn" {
  description = "Role used by S3 Batch Operations."
  value       = aws_iam_role.batch_ops_role.arn
}
