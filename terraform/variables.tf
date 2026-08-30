###############################################################################
# Identity / environment
###############################################################################

variable "environment" {
  description = "Environment name. Becomes the prefix of every resource name and the API stage."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be either \"staging\" or \"prod\"."
  }
}

variable "project" {
  description = "Project tag applied to every resource."
  type        = string
  default     = "healthcheck-api"
}

variable "repository" {
  description = "Source repository, recorded as a tag for provenance."
  type        = string
  default     = "Healthcheck_API_hw"
}

variable "aws_region" {
  description = "Region the environment is deployed to."
  type        = string
}

variable "allowed_account_ids" {
  description = "Account IDs this configuration may run against. Empty disables the check."
  type        = list(string)
  default     = []
}

variable "deploy_role_arn" {
  description = "Deployment role assumed by the provider. Null uses the caller's own credentials."
  type        = string
  default     = null
}

variable "deploy_role_external_id" {
  description = "sts:ExternalId presented when assuming the deployment role."
  type        = string
  default     = null
  sensitive   = true
}

variable "source_version" {
  description = "Version stamp for the deployed artifact (the git SHA in CI)."
  type        = string
  default     = "local"
}

variable "additional_tags" {
  description = "Extra tags merged into the standard tag set."
  type        = map(string)
  default     = {}
}

###############################################################################
# Encryption
###############################################################################

variable "kms_deletion_window_days" {
  description = "Waiting period before a scheduled KMS key deletion completes."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

###############################################################################
# DynamoDB
###############################################################################

variable "dynamodb_table_name" {
  description = "Table name without the environment prefix."
  type        = string
  default     = "requests-db"
}

variable "dynamodb_billing_mode" {
  description = "PAY_PER_REQUEST or PROVISIONED."
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "dynamodb_read_capacity" {
  description = "Read capacity units (PROVISIONED only)."
  type        = number
  default     = 1
}

variable "dynamodb_write_capacity" {
  description = "Write capacity units (PROVISIONED only)."
  type        = number
  default     = 1
}

variable "dynamodb_point_in_time_recovery" {
  description = "Enable point-in-time recovery."
  type        = bool
  default     = false
}

variable "dynamodb_deletion_protection" {
  description = "Block accidental table deletion."
  type        = bool
  default     = false
}

variable "item_ttl_days" {
  description = "How long stored requests live before TTL removes them."
  type        = number
  default     = 30
}

###############################################################################
# Network
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the environment's VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread the private subnets across."
  type        = list(string)
}

variable "subnet_newbits" {
  description = "Extra netmask bits used when carving subnets from vpc_cidr."
  type        = number
  default     = 4
}

###############################################################################
# Lambda
###############################################################################

variable "lambda_function_name" {
  description = "Function name without the environment prefix."
  type        = string
  default     = "health-check-function"
}

variable "lambda_runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.12"
}

variable "lambda_memory_size" {
  description = "Memory in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout" {
  description = "Timeout in seconds."
  type        = number
  default     = 10
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrent executions; caps cost and blast radius."
  type        = number
  default     = 20
}

variable "lambda_log_level" {
  description = "Log level for the function."
  type        = string
  default     = "INFO"
}

variable "lambda_tracing_mode" {
  description = "X-Ray tracing mode for the function."
  type        = string
  default     = "PassThrough"
}

variable "max_payload_bytes" {
  description = "Maximum accepted request body size."
  type        = number
  default     = 8192
}

variable "artifacts_bucket_name" {
  description = "Artifact bucket name without env prefix or account suffix."
  type        = string
  default     = "health-check-artifacts"
}

variable "artifacts_force_destroy" {
  description = "Allow Terraform to delete a non-empty artifact bucket."
  type        = bool
  default     = false
}

variable "artifact_retention_days" {
  description = "How long superseded artifact versions are retained."
  type        = number
  default     = 90
}

###############################################################################
# API Gateway
###############################################################################

variable "api_name" {
  description = "API name without the environment prefix."
  type        = string
  default     = "health-check-api"
}

variable "route_path" {
  description = "Route path part, without a leading slash."
  type        = string
  default     = "health"
}

variable "api_throttling_rate_limit" {
  description = "Stage-level steady-state requests per second."
  type        = number
  default     = 20
}

variable "api_throttling_burst_limit" {
  description = "Stage-level burst capacity."
  type        = number
  default     = 40
}

variable "api_enable_usage_plan" {
  description = "Create a usage plan for per-client throttling and quotas."
  type        = bool
  default     = false
}

variable "api_usage_plan_rate_limit" {
  description = "Usage plan steady-state requests per second."
  type        = number
  default     = 10
}

variable "api_usage_plan_burst_limit" {
  description = "Usage plan burst capacity."
  type        = number
  default     = 20
}

variable "api_usage_plan_quota_limit" {
  description = "Usage plan request quota per period."
  type        = number
  default     = 100000
}

variable "api_usage_plan_quota_period" {
  description = "Quota period: DAY, WEEK or MONTH."
  type        = string
  default     = "MONTH"
}

variable "api_logging_level" {
  description = "API Gateway execution logging level."
  type        = string
  default     = "ERROR"
}

variable "api_xray_tracing_enabled" {
  description = "Enable X-Ray tracing on the API stage."
  type        = bool
  default     = false
}

###############################################################################
# Observability
###############################################################################

variable "log_retention_days" {
  description = "Retention applied to every CloudWatch log group in the stack."
  type        = number
  default     = 30

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts."
  }
}

variable "enable_alarms" {
  description = "Create CloudWatch alarms for errors, 5xx and sustained throttling."
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arns" {
  description = "SNS topics notified when an alarm fires."
  type        = list(string)
  default     = []
}

variable "lambda_error_alarm_threshold" {
  description = "Lambda errors in a 5-minute window before alarming."
  type        = number
  default     = 5
}

variable "api_5xx_alarm_threshold" {
  description = "API 5xx responses in a 5-minute window before alarming."
  type        = number
  default     = 5
}

variable "api_4xx_alarm_threshold" {
  description = "API 4xx responses per 5-minute window, over two windows, before alarming."
  type        = number
  default     = 100
}
