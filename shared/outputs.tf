output "state_bucket" {
  description = "Put this in env/*.backend.hcl as `bucket`."
  value       = aws_s3_bucket.state.id
}

output "state_lock_table" {
  description = "Put this in env/*.backend.hcl as `dynamodb_table`."
  value       = aws_dynamodb_table.state_lock.name
}

output "deploy_role_arns" {
  description = "Per-environment deployment role ARNs. Store as the AWS_DEPLOY_ROLE_ARN_* GitHub secrets."
  value       = { for env, mod in module.deploy_role : env => mod.role_arn }
}

output "ci_user_arn" {
  description = "ARN of the CI IAM user."
  value       = aws_iam_user.ci.arn
}

output "ci_access_key_id" {
  description = "Store as the AWS_ACCESS_KEY_ID GitHub secret."
  value       = try(aws_iam_access_key.ci[0].id, null)
}

output "ci_secret_access_key" {
  description = "Store as the AWS_SECRET_ACCESS_KEY GitHub secret. Read it with: terraform output -raw ci_secret_access_key"
  value       = try(aws_iam_access_key.ci[0].secret, null)
  sensitive   = true
}

output "backend_config_staging" {
  description = "Ready-to-paste contents for terraform/env/staging.backend.hcl."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.id}"
    key            = "staging/health-check/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.state_lock.name}"
    encrypt        = true
  EOT
}

output "backend_config_prod" {
  description = "Ready-to-paste contents for terraform/env/prod.backend.hcl."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.id}"
    key            = "prod/health-check/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.state_lock.name}"
    encrypt        = true
  EOT
}
