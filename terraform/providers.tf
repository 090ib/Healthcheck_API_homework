###############################################################################
# Provider configuration
#
# Credentials are never written here. The pipeline exports AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY for the CI user (requirement: "AWS authentication via
# API key") and this provider immediately trades them for a short-lived session
# on the environment's deployment role.
#
# Leaving deploy_role_arn empty (the default for a local plan) simply uses
# whatever credentials the caller already has.
###############################################################################

provider "aws" {
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.deploy_role_arn == null ? [] : [var.deploy_role_arn]

    content {
      role_arn     = assume_role.value
      session_name = "terraform-${var.environment}-${var.source_version}"
      external_id  = var.deploy_role_external_id
    }
  }

  # Belt and braces: refuse to run against the wrong account.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.repository
    }
  }
}
