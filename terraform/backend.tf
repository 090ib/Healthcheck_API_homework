###############################################################################
# Remote state
#
# Deliberately a *partial* configuration: the bucket, key and lock table are
# supplied at init time so the same root module serves both environments
# without duplicated code and without workspace surprises.
#
#   terraform init -backend-config=env/staging.backend.hcl
#   terraform init -reconfigure -backend-config=env/prod.backend.hcl
#
# The bucket, lock table and their encryption are created once by the
# shared/ stack.
###############################################################################

terraform {
  backend "s3" {
    encrypt = true
  }
}
