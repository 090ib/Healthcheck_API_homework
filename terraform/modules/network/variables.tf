variable "name_prefix" {
  description = "Environment-scoped prefix applied to every resource name (e.g. \"staging\")."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with dashes, 2-21 characters."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "Availability zones to place private subnets in. Two or more is recommended."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 1
    error_message = "At least one availability zone is required."
  }
}

variable "subnet_newbits" {
  description = "Additional netmask bits used when carving subnets out of vpc_cidr."
  type        = number
  default     = 4
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table the VPC endpoint policy is scoped to."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the VPC flow log group."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Retention in days for VPC flow logs."
  type        = number
  default     = 30
}

variable "account_id" {
  description = "AWS account ID, used to scope the flow-log role trust policy."
  type        = string
}

variable "partition" {
  description = "AWS partition (aws, aws-cn, aws-us-gov)."
  type        = string
  default     = "aws"
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
