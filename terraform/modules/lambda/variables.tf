variable "name_prefix" {
  description = "Environment prefix, e.g. \"staging\"."
  type        = string
}

variable "function_name" {
  description = "Function name without the environment prefix."
  type        = string
  default     = "health-check-function"
}

variable "source_dir" {
  description = "Directory containing the Lambda source to package."
  type        = string
}

variable "source_version" {
  description = "Version identifier stamped on the artifact and function (git SHA in CI)."
  type        = string
  default     = "local"
}

variable "handler" {
  description = "Lambda handler entry point."
  type        = string
  default     = "handler.lambda_handler"
}

variable "runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.12"
}

variable "memory_size" {
  description = "Memory in MB allocated to the function."
  type        = number
  default     = 256

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB."
  }
}

variable "timeout" {
  description = "Function timeout in seconds."
  type        = number
  default     = 10

  validation {
    condition     = var.timeout > 0 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions. Caps blast radius and cost; -1 disables the cap."
  type        = number
  default     = 20
}

variable "alias_name" {
  description = "Name of the alias API Gateway invokes."
  type        = string
  default     = "live"
}

variable "log_level" {
  description = "Log level passed to the function."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARNING, ERROR."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the function log group."
  type        = number
  default     = 30
}

variable "item_ttl_days" {
  description = "How long stored request items live before DynamoDB TTL removes them."
  type        = number
  default     = 30
}

variable "max_payload_bytes" {
  description = "Maximum accepted request body size in bytes."
  type        = number
  default     = 8192
}

variable "tracing_mode" {
  description = "X-Ray tracing mode: Active or PassThrough."
  type        = string
  default     = "PassThrough"

  validation {
    condition     = contains(["Active", "PassThrough"], var.tracing_mode)
    error_message = "tracing_mode must be Active or PassThrough."
  }
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table the function writes to."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table the function writes to."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key used for logs, env vars and artifacts."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the function's ENIs."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group attached to the function's ENIs."
  type        = string
}

variable "artifacts_bucket_name" {
  description = "Artifact bucket name without env prefix or account suffix."
  type        = string
  default     = "health-check-artifacts"
}

variable "artifacts_force_destroy" {
  description = "Allow Terraform to delete a non-empty artifact bucket (staging convenience)."
  type        = bool
  default     = false
}

variable "artifact_retention_days" {
  description = "How long superseded artifact versions are kept in S3."
  type        = number
  default     = 90
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary attached to the execution role."
  type        = string
  default     = null
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "partition" {
  description = "AWS partition."
  type        = string
  default     = "aws"
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
