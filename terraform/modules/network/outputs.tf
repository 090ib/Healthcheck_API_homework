output "vpc_id" {
  description = "ID of the VPC hosting the Lambda function."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets the Lambda ENIs are attached to."
  value       = [for s in aws_subnet.private : s.id]
}

output "lambda_security_group_id" {
  description = "ID of the egress-only security group for the Lambda ENIs."
  value       = aws_security_group.lambda.id
}

output "dynamodb_vpc_endpoint_id" {
  description = "ID of the DynamoDB gateway VPC endpoint."
  value       = aws_vpc_endpoint.dynamodb.id
}

output "flow_log_group_name" {
  description = "CloudWatch log group receiving VPC flow logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
