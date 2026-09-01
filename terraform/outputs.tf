output "environment" {
  description = "Environment this state represents."
  value       = var.environment
}

output "health_endpoint" {
  description = "Full URL of the deployed /health endpoint."
  value       = module.api_gateway.health_endpoint
}

output "api_invoke_url" {
  description = "Base invoke URL of the API stage."
  value       = module.api_gateway.invoke_url
}

output "rest_api_id" {
  description = "ID of the REST API."
  value       = module.api_gateway.rest_api_id
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function."
  value       = module.lambda.function_name
}

output "lambda_function_version" {
  description = "Numbered Lambda version published by this apply."
  value       = module.lambda.function_version
}

output "lambda_alias_arn" {
  description = "ARN of the alias API Gateway invokes."
  value       = module.lambda.alias_arn
}

output "lambda_source_code_hash" {
  description = "Base64 SHA-256 of the deployed package."
  value       = module.lambda.source_code_hash
}

output "lambda_artifact" {
  description = "S3 location of the deployed artifact."
  value       = "s3://${module.lambda.artifacts_bucket}/${module.lambda.artifact_key}"
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table storing requests."
  value       = module.dynamodb.table_name
}

output "lambda_execution_role_arn" {
  description = "ARN of the Lambda execution role."
  value       = module.lambda.role_arn
}

output "kms_key_arn" {
  description = "ARN of the environment's customer-managed KMS key."
  value       = aws_kms_key.this.arn
}

output "vpc_id" {
  description = "ID of the VPC the function runs in."
  value       = module.network.vpc_id
}

output "log_groups" {
  description = "CloudWatch log groups created by this stack."
  value = {
    lambda        = module.lambda.log_group_name
    api_access    = module.api_gateway.access_log_group_name
    vpc_flow_logs = module.network.flow_log_group_name
  }
}

output "curl_example_post" {
  description = "Ready-to-run smoke test for the deployed endpoint."
  value       = "curl -sS -X POST '${module.api_gateway.health_endpoint}' -H 'Content-Type: application/json' -d '{\"payload\":{\"source\":\"manual-smoke-test\"}}'"
}
