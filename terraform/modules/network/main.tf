###############################################################################
# Network module
#
# A dedicated VPC for the health-check Lambda. The function runs in private
# subnets with no route to the internet at all: DynamoDB is reached over a
# Gateway VPC endpoint, so no NAT Gateway is needed (that also the cheapest
# option).
###############################################################################

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# The default security group is left with no rules at all: nothing should ever
# attach to it. Cannot be deleted.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-default-sg-do-not-use" })
}

resource "aws_subnet" "private" {
  for_each = { for idx, az in var.availability_zones : az => idx }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, var.subnet_newbits, each.value)

  # Lambda ENIs never need a public IP.
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-subnet-${each.key}" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# Gateway VPC endpoint for DynamoDB (no hourly charge, no data processing fee)
###############################################################################

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  # Endpoint policy: only the health-check table, only the actions the function
  # actually performs. This is a second, network-level guard on top of the IAM
  # role attached to the function.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowHealthCheckTableWritesOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["dynamodb:PutItem", "dynamodb:DescribeTable"]
        Resource  = [var.dynamodb_table_arn]
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-dynamodb-endpoint" })
}

###############################################################################
# Security group for the Lambda ENIs
###############################################################################

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Egress-only security group for the health check Lambda ENIs"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-lambda-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# No ingress rules exist: nothing initiates a connection to a Lambda ENI.
# Egress is restricted to the DynamoDB prefix list, so even if the function
# were compromised it has no route to anything else.
data "aws_prefix_list" "dynamodb" {
  name = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
}

resource "aws_vpc_security_group_egress_rule" "dynamodb" {
  security_group_id = aws_security_group.lambda.id
  description       = "HTTPS to DynamoDB via the gateway VPC endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.dynamodb.id
}

###############################################################################
# VPC Flow Logs -> CloudWatch (network forensics / audit trail)
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}-flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.name_prefix}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${var.partition}:ec2:${data.aws_region.current.name}:${var.account_id}:vpc-flow-log/*" }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.name_prefix}-vpc-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteFlowLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
      }
    ]
  })
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  max_aggregation_interval = 600

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc-flow-log" })
}
