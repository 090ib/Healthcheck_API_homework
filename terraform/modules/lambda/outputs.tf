output "function_name" {
  description = "Name of the Lambda function."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Unqualified ARN of the Lambda function."
  value       = aws_lambda_function.this.arn
}

output "function_version" {
  description = "Numbered version published by this apply."
  value       = aws_lambda_function.this.version
}

output "alias_name" {
  description = "Alias API Gateway invokes."
  value       = aws_lambda_alias.live.name
}

output "alias_arn" {
  description = "ARN of the alias (the integration target for API Gateway)."
  value       = aws_lambda_alias.live.arn
}

output "invoke_arn" {
  description = "Alias invoke ARN for the API Gateway AWS_PROXY integration."
  value       = aws_lambda_alias.live.invoke_arn
}

output "role_arn" {
  description = "ARN of the execution role."
  value       = aws_iam_role.lambda.arn
}

output "log_group_name" {
  description = "CloudWatch log group for the function."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "artifacts_bucket" {
  description = "S3 bucket holding versioned deployment artifacts."
  value       = aws_s3_bucket.artifacts.id
}

output "artifact_key" {
  description = "S3 key of the artifact currently deployed."
  value       = aws_s3_object.package.key
}

output "source_code_hash" {
  description = "Base64 SHA-256 of the deployed package."
  value       = data.archive_file.package.output_base64sha256
}
