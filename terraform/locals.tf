data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Every resource name is "<env>-<resource-name>" per the naming convention;
  # name_prefix is the "<env>" half and is threaded through every module.
  name_prefix = var.environment

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "health-check-api"
    },
    var.additional_tags,
  )
}
