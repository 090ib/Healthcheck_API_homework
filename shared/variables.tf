variable "project" {
  description = "Project slug used to name the account-level resources."
  type        = string
  default     = "healthcheck-api"
}

variable "aws_region" {
  description = "Region the state backend and deployment roles live in."
  type        = string
  default     = "eu-central-1"
}

variable "environments" {
  description = "Environments to create a deployment role for."
  type        = list(string)
  default     = ["staging", "prod"]
}

variable "deploy_role_external_id" {
  description = "Shared secret required on sts:AssumeRole. Store it as the AWS_DEPLOY_EXTERNAL_ID GitHub secret."
  type        = string
  default     = null
  sensitive   = true
}

variable "create_ci_access_key" {
  description = "Create the CI user's access key here. The secret then lives in this stack's local state; set to false and create the key with the AWS CLI if that is unacceptable."
  type        = bool
  default     = true
}

variable "manage_apigateway_account_role" {
  description = "Manage the account-wide API Gateway CloudWatch role. Set to false if another stack already owns it."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged into the shared tag set."
  type        = map(string)
  default     = {}
}
