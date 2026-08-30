variable "name_prefix" {
  description = "Environment prefix, e.g. \"staging\"."
  type        = string
}

variable "role_name" {
  description = "Role name without the environment prefix."
  type        = string
  default     = "health-check-deploy-role"
}

variable "trusted_principal_arns" {
  description = "Principals allowed to assume this role (the CI IAM user)."
  type        = list(string)

  validation {
    condition     = length(var.trusted_principal_arns) > 0
    error_message = "At least one trusted principal ARN is required."
  }
}

variable "external_id" {
  description = "Optional sts:ExternalId required on AssumeRole."
  type        = string
  default     = null
  sensitive   = true
}

variable "max_session_duration" {
  description = "Maximum assumed-session length in seconds."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the deployment role."
  type        = string
  default     = null
}

variable "state_bucket" {
  description = "Name of the S3 bucket holding Terraform state."
  type        = string
}

variable "state_lock_table" {
  description = "Name of the DynamoDB table used for state locking."
  type        = string
}

variable "artifacts_bucket_name" {
  description = "Artifact bucket name without env prefix or account suffix."
  type        = string
  default     = "health-check-artifacts"
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
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
