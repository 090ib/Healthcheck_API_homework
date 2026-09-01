variable "name_prefix" {
  description = "Environment prefix, e.g. \"staging\" -> staging-requests-db."
  type        = string
}

variable "table_name" {
  description = "Table name without the environment prefix."
  type        = string
  default     = "requests-db"
}

variable "billing_mode" {
  description = "PAY_PER_REQUEST or PROVISIONED."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "read_capacity" {
  description = "Read capacity units (PROVISIONED billing only)."
  type        = number
  default     = 1
}

variable "write_capacity" {
  description = "Write capacity units (PROVISIONED billing only)."
  type        = number
  default     = 1
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used for server-side encryption."
  type        = string
}

variable "point_in_time_recovery_enabled" {
  description = "Enable point-in-time recovery (adds cost; recommended for prod)."
  type        = bool
  default     = false
}

variable "deletion_protection_enabled" {
  description = "Block accidental table deletion (recommended for prod)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the table."
  type        = map(string)
  default     = {}
}
