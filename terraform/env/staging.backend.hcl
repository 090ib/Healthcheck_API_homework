# Backend configuration for staging.
#   terraform init -backend-config=env/staging.backend.hcl
#
# Replace <ACCOUNT_ID> with the account the shared/ stack was applied to;
# the bucket name is globally unique so it carries the account suffix.

bucket         = "healthcheck-api-tfstate-164892691535"
key            = "staging/health-check/terraform.tfstate"
region         = "eu-central-1"
dynamodb_table = "healthcheck-api-tfstate-lock"
encrypt        = true
