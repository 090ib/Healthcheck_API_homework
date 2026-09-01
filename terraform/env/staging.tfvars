###############################################################################
# Staging
#
#   terraform init  -backend-config=env/staging.backend.hcl
#   terraform plan  -var-file=env/staging.tfvars
#   terraform apply -var-file=env/staging.tfvars
#
# Tuned for cheap, disposable iteration: no PITR, no deletion protection, low
# throttles, short log retention.
###############################################################################

environment = "staging"
aws_region  = "eu-central-1"

availability_zones = ["eu-central-1a", "eu-central-1b"]
vpc_cidr           = "10.20.0.0/16"

# --- Data ------------------------------------------------------------------
dynamodb_billing_mode           = "PAY_PER_REQUEST"
dynamodb_point_in_time_recovery = false
dynamodb_deletion_protection    = false
item_ttl_days                   = 7

# --- Compute ---------------------------------------------------------------
lambda_memory_size          = 256
lambda_timeout              = 10
lambda_reserved_concurrency = -1
lambda_log_level            = "INFO"
lambda_tracing_mode         = "PassThrough"

# --- Edge ------------------------------------------------------------------
api_throttling_rate_limit  = 20
api_throttling_burst_limit = 40
api_enable_usage_plan      = false
api_logging_level          = "INFO"
api_xray_tracing_enabled   = false

# --- Housekeeping ----------------------------------------------------------
log_retention_days       = 7
artifacts_force_destroy  = true
artifact_retention_days  = 30
kms_deletion_window_days = 7

enable_alarms = true

additional_tags = {
  CostCentre = "engineering-nonprod"
  DataClass  = "internal"
}
