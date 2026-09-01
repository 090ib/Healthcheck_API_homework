###############################################################################
# Production
#
#   terraform init  -reconfigure -backend-config=env/prod.backend.hcl
#   terraform plan  -var-file=env/prod.tfvars
#   terraform apply -var-file=env/prod.tfvars
#
# Applied only after the manual approval gate in the GitHub Actions
# "production" environment. Durability and retention are turned up; the
# throttles are higher but still bounded.
###############################################################################

environment = "prod"
aws_region  = "eu-central-1"

availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
vpc_cidr           = "10.30.0.0/16"

# --- Data ------------------------------------------------------------------
dynamodb_billing_mode           = "PAY_PER_REQUEST"
dynamodb_point_in_time_recovery = true
dynamodb_deletion_protection    = true
item_ttl_days                   = 90

# --- Compute ---------------------------------------------------------------
lambda_memory_size          = 512
lambda_timeout              = 15
lambda_reserved_concurrency = 100
lambda_log_level            = "INFO"
lambda_tracing_mode         = "Active"

# --- Edge ------------------------------------------------------------------
api_throttling_rate_limit   = 200
api_throttling_burst_limit  = 400
api_enable_usage_plan       = true
api_usage_plan_rate_limit   = 100
api_usage_plan_burst_limit  = 200
api_usage_plan_quota_limit  = 5000000
api_usage_plan_quota_period = "MONTH"
api_logging_level           = "ERROR"
api_xray_tracing_enabled    = true

# --- Housekeeping ----------------------------------------------------------
log_retention_days       = 90
artifacts_force_destroy  = false
artifact_retention_days  = 365
kms_deletion_window_days = 30

enable_alarms = true
# Populate with the ARN of the on-call SNS topic once it exists, e.g.
# alarm_sns_topic_arns = ["arn:aws:sns:eu-central-1:123456789012:prod-oncall"]
alarm_sns_topic_arns = []

additional_tags = {
  CostCentre = "engineering-prod"
  DataClass  = "confidential"
}
