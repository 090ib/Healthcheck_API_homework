# Backend configuration for production.
#   terraform init -reconfigure -backend-config=env/prod.backend.hcl
#
# Same bucket, different key: the staging deployment role is only granted
# s3:GetObject/PutObject under "staging/*", so it cannot read this state.

bucket         = "healthcheck-api-tfstate-<ACCOUNT_ID>"
key            = "prod/health-check/terraform.tfstate"
region         = "eu-central-1"
dynamodb_table = "healthcheck-api-tfstate-lock"
encrypt        = true
