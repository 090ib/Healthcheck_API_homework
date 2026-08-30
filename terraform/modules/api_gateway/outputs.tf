output "rest_api_id" {
  description = "ID of the REST API."
  value       = aws_api_gateway_rest_api.this.id
}

output "stage_name" {
  description = "Deployed stage name."
  value       = aws_api_gateway_stage.this.stage_name
}

output "invoke_url" {
  description = "Base invoke URL for the stage."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "health_endpoint" {
  description = "Full URL of the /health endpoint."
  value       = "${aws_api_gateway_stage.this.invoke_url}/${var.route_path}"
}

output "execution_arn" {
  description = "Execution ARN of the REST API."
  value       = aws_api_gateway_rest_api.this.execution_arn
}

output "access_log_group_name" {
  description = "CloudWatch log group receiving API Gateway access logs."
  value       = aws_cloudwatch_log_group.access_logs.name
}

output "usage_plan_id" {
  description = "ID of the usage plan, when one is created."
  value       = try(aws_api_gateway_usage_plan.this[0].id, null)
}
