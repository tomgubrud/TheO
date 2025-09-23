output "role_arn"   { value = module.batchops_role.arn }
output "policy_arn" { value = aws_iam_policy.batchops_policy.arn }
output "job_id"     { value = try(aws_s3control_job.copy_existing[0].job_id, "") }
