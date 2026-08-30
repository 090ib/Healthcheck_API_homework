variable "name_prefix" {
  description = "Environment prefix, e.g. \"staging\"."
  type        = string
}

variable "api_name" {
  description = "API name without the environment prefix."
  type        = string
  default     = "health-check-api"
}

variable "route_path" {
  description = "Path part of the route, without a leading slash."
  type        = string
  default     = "health"
}

variable "stage_name" {
  description = "Stage name. Kept equal to the environment so URLs read /staging/health."
  type        = string
}

variable "lambda_invoke_arn" {
  description = "Invoke ARN of the Lambda alias backing the route."
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the Lambda function to grant invoke permission on."
  type        = string
}

variable "lambda_alias_name" {
  description = "Alias qualifier for the invoke permission."
  type        = string
}

variable "integration_timeout_ms" {
  description = "How long API Gateway waits for the Lambda response."
  type        = number
  default     = 15000

  validation {
    condition     = var.integration_timeout_ms >= 50 && var.integration_timeout_ms <= 29000
    error_message = "integration_timeout_ms must be between 50 and 29000."
  }
}

variable "authorization" {
  description = "Method authorization type. NONE keeps the health endpoint public; AWS_IAM locks it down."
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "AWS_IAM", "CUSTOM", "COGNITO_USER_POOLS"], var.authorization)
    error_message = "authorization must be NONE, AWS_IAM, CUSTOM or COGNITO_USER_POOLS."
  }
}

variable "api_key_required" {
  description = "Require an API key on the method (used together with a usage plan)."
  type        = bool
  default     = false
}

# --- Throttling ------------------------------------------------------------

variable "throttling_rate_limit" {
  description = "Steady-state requests per second allowed for the stage."
  type        = number
  default     = 20
}

variable "throttling_burst_limit" {
  description = "Burst capacity (token bucket size) for the stage."
  type        = number
  default     = 40
}

variable "enable_usage_plan" {
  description = "Create a usage plan for a second, per-client throttling tier."
  type        = bool
  default     = false
}

variable "usage_plan_rate_limit" {
  description = "Usage plan steady-state requests per second."
  type        = number
  default     = 10
}

variable "usage_plan_burst_limit" {
  description = "Usage plan burst capacity."
  type        = number
  default     = 20
}

variable "usage_plan_quota_limit" {
  description = "Usage plan request quota per period."
  type        = number
  default     = 100000
}

variable "usage_plan_quota_period" {
  description = "Quota period: DAY, WEEK or MONTH."
  type        = string
  default     = "MONTH"

  validation {
    condition     = contains(["DAY", "WEEK", "MONTH"], var.usage_plan_quota_period)
    error_message = "usage_plan_quota_period must be DAY, WEEK or MONTH."
  }
}

# --- Observability ---------------------------------------------------------

variable "logging_level" {
  description = "Execution logging level: OFF, ERROR or INFO."
  type        = string
  default     = "ERROR"

  validation {
    condition     = contains(["OFF", "ERROR", "INFO"], var.logging_level)
    error_message = "logging_level must be OFF, ERROR or INFO."
  }
}

variable "xray_tracing_enabled" {
  description = "Enable X-Ray tracing on the stage."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for the access log group."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the access log group."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
