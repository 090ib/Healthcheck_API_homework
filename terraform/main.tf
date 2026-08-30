###############################################################################
# Health check API -- root module
#
# Wires the five reusable modules together for one environment. Which
# environment is decided entirely by the -var-file passed at plan/apply time:
#
#   terraform apply -var-file="env/staging.tfvars"
###############################################################################

###############################################################################
# Customer-managed KMS key -- one per environment, used everywhere
###############################################################################

data "aws_iam_policy_document" "kms" {
  # Without this statement the key becomes unmanageable: AWS requires the
  # account root to retain administrative access, and it is what allows IAM
  # policies (rather than only the key policy) to grant use of the key.
  statement {
    sid       = "EnableIamPoliciesForAccount"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts log data with the key on our behalf.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "${local.name_prefix} health check: DynamoDB, logs, Lambda env vars and artifacts"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = data.aws_iam_policy_document.kms.json

  tags = merge(local.tags, { Name = "${local.name_prefix}-health-check-key" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${local.name_prefix}-health-check-key"
  target_key_id = aws_kms_key.this.key_id
}

###############################################################################
# Data store
###############################################################################

module "dynamodb" {
  source = "./modules/dynamodb"

  name_prefix = local.name_prefix
  table_name  = var.dynamodb_table_name
  kms_key_arn = aws_kms_key.this.arn

  billing_mode                   = var.dynamodb_billing_mode
  read_capacity                  = var.dynamodb_read_capacity
  write_capacity                 = var.dynamodb_write_capacity
  point_in_time_recovery_enabled = var.dynamodb_point_in_time_recovery
  deletion_protection_enabled    = var.dynamodb_deletion_protection

  tags = local.tags
}

###############################################################################
# Network -- the Lambda's own VPC, with a DynamoDB gateway endpoint
###############################################################################

module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  subnet_newbits     = var.subnet_newbits

  dynamodb_table_arn      = module.dynamodb.table_arn
  kms_key_arn             = aws_kms_key.this.arn
  flow_log_retention_days = var.log_retention_days

  account_id = local.account_id
  partition  = local.partition
  tags       = local.tags
}

###############################################################################
# Compute
###############################################################################

module "lambda" {
  source = "./modules/lambda"

  name_prefix    = local.name_prefix
  function_name  = var.lambda_function_name
  source_dir     = "${path.module}/../src/lambda"
  source_version = var.source_version

  runtime              = var.lambda_runtime
  memory_size          = var.lambda_memory_size
  timeout              = var.lambda_timeout
  reserved_concurrency = var.lambda_reserved_concurrency
  log_level            = var.lambda_log_level
  log_retention_days   = var.log_retention_days
  item_ttl_days        = var.item_ttl_days
  max_payload_bytes    = var.max_payload_bytes
  tracing_mode         = var.lambda_tracing_mode

  dynamodb_table_name = module.dynamodb.table_name
  dynamodb_table_arn  = module.dynamodb.table_arn
  kms_key_arn         = aws_kms_key.this.arn

  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.private_subnet_ids
  subnet_arns        = [for id in module.network.private_subnet_ids : "arn:${local.partition}:ec2:${local.region}:${local.account_id}:subnet/${id}"]
  security_group_id  = module.network.lambda_security_group_id
  security_group_arn = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:security-group/${module.network.lambda_security_group_id}"

  artifacts_bucket_name   = var.artifacts_bucket_name
  artifacts_force_destroy = var.artifacts_force_destroy
  artifact_retention_days = var.artifact_retention_days

  account_id = local.account_id
  partition  = local.partition
  tags       = local.tags
}

###############################################################################
# Edge
###############################################################################

module "api_gateway" {
  source = "./modules/api_gateway"

  name_prefix = local.name_prefix
  api_name    = var.api_name
  route_path  = var.route_path
  stage_name  = var.environment

  lambda_invoke_arn    = module.lambda.invoke_arn
  lambda_function_name = module.lambda.function_name
  lambda_alias_name    = module.lambda.alias_name

  throttling_rate_limit  = var.api_throttling_rate_limit
  throttling_burst_limit = var.api_throttling_burst_limit

  enable_usage_plan       = var.api_enable_usage_plan
  usage_plan_rate_limit   = var.api_usage_plan_rate_limit
  usage_plan_burst_limit  = var.api_usage_plan_burst_limit
  usage_plan_quota_limit  = var.api_usage_plan_quota_limit
  usage_plan_quota_period = var.api_usage_plan_quota_period

  logging_level        = var.api_logging_level
  xray_tracing_enabled = var.api_xray_tracing_enabled
  log_retention_days   = var.log_retention_days
  kms_key_arn          = aws_kms_key.this.arn

  tags = local.tags
}

###############################################################################
# Alarms
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-health-check-lambda-errors"
  alarm_description   = "Health check function returned errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.lambda_error_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = module.lambda.function_name
    Resource     = "${module.lambda.function_name}:${module.lambda.alias_name}"
  }

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-health-check-api-5xx"
  alarm_description   = "Health check API returned 5xx responses"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.api_5xx_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = "${local.name_prefix}-${var.api_name}"
    Stage   = var.environment
  }

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.tags
}

# A sustained wall of 429s means the throttle is doing its job -- but it is
# also how a volumetric attack looks, so it is worth an alarm.
resource "aws_cloudwatch_metric_alarm" "api_throttled" {
  count = var.enable_alarms ? 1 : 0

  alarm_name          = "${local.name_prefix}-health-check-api-throttling"
  alarm_description   = "Sustained request throttling on the health check API"
  namespace           = "AWS/ApiGateway"
  metric_name         = "4XXError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.api_4xx_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = "${local.name_prefix}-${var.api_name}"
    Stage   = var.environment
  }

  alarm_actions = var.alarm_sns_topic_arns
  tags          = local.tags
}
