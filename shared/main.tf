###############################################################################
# Shared stack: applied ONCE per AWS account by an administrator.
#
# Everything here is account-level and must exist before the environment stacks
# can run at all:
#
#   * the S3 bucket + DynamoDB table backing Terraform remote state
#   * the CI IAM user whose access key GitHub Actions authenticates with
#   * one deployment role per environment, which that user assumes
#   * the account-wide CloudWatch role API Gateway needs to write logs
#
# This stack uses local state on purpose: it is what creates the remote state
# backend, so it cannot use it. Apply it from a workstation with admin
# credentials and keep terraform.tfstate somewhere safe (it contains the CI
# secret access key), or re-run it, since every resource here is idempotent.
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id      = data.aws_caller_identity.current.account_id
  partition       = data.aws_partition.current.partition
  state_bucket    = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  state_lock_name = "${var.project}-tfstate-lock"

  tags = merge({
    Project   = var.project
    ManagedBy = "terraform"
    Scope     = "shared"
  }, var.tags)
}

###############################################################################
# Remote state backend
###############################################################################
# An explicit key policy rather than relying on the AWS default. Functionally
# the same, but it is reviewable in the repository instead of only in the
# console, and it matches how the per-environment keys are defined.

data "aws_iam_policy_document" "state_key" {
  #checkov:skip=CKV_AWS_356:In a KMS *key* policy, "*" means this key, the grammar has no way to name the key being created. Not an IAM wildcard.
  #checkov:skip=CKV_AWS_109:Same statement. AWS requires the account root to retain administration of every CMK, or the key becomes unmanageable.
  #checkov:skip=CKV_AWS_111:Same statement.
  statement {
    sid       = "EnableIamPoliciesForAccount"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform state and the state lock table"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json

  tags = merge(local.tags, { Name = "${var.project}-tfstate-key" })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate-key"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # State is never disposable.
  force_destroy = false

  tags = merge(local.tags, { Name = local.state_bucket })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    # Orphaned multipart uploads are invisible in the console and billed as
    # storage forever. The artifact bucket already reclaims them; this bucket
    # was missing the rule.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_dynamodb_table" "state_lock" {
  name         = local.state_lock_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.tags, { Name = local.state_lock_name })
}

###############################################################################
# CI identity: the "AWS authentication via API key" requirement
#
# This user holds a long-lived access key, which is the only long-lived
# credential in the system. Its own policy grants nothing except the right to
# assume the environment deployment roles, so a leaked key is worth very
# little on its own: the attacker still needs the ExternalId and still lands in
# a region- and prefix-fenced role.
###############################################################################

resource "aws_iam_user" "ci" {
  name = "${var.project}-ci-user"
  path = "/ci/"

  tags = merge(local.tags, { Name = "${var.project}-ci-user" })
}

data "aws_iam_policy_document" "ci_assume_only" {
  statement {
    sid       = "AssumeDeploymentRolesOnly"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [for env in var.environments : "arn:${local.partition}:iam::${local.account_id}:role/${env}-health-check-deploy-role"]
  }

  statement {
    sid       = "WhoAmI"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "ci" {
  name   = "${var.project}-ci-assume-deploy-roles"
  user   = aws_iam_user.ci.name
  policy = data.aws_iam_policy_document.ci_assume_only.json
}

resource "aws_iam_access_key" "ci" {
  count = var.create_ci_access_key ? 1 : 0

  user = aws_iam_user.ci.name
}

###############################################################################
# Deployment roles: one per environment
###############################################################################

module "deploy_role" {
  source   = "../terraform/modules/deploy_iam"
  for_each = toset(var.environments)

  name_prefix            = each.key
  trusted_principal_arns = [aws_iam_user.ci.arn]
  external_id            = var.deploy_role_external_id

  state_bucket     = aws_s3_bucket.state.id
  state_lock_table = aws_dynamodb_table.state_lock.name

  account_id = local.account_id
  partition  = local.partition
  tags       = merge(local.tags, { Environment = each.key })
}

###############################################################################
# API Gateway account settings
#
# The CloudWatch role for API Gateway is an account-wide singleton, which is
# why it lives here rather than in the per-environment stack. Two
# environments both managing it would fight over the same setting.
###############################################################################

resource "aws_iam_role" "apigw_cloudwatch" {
  count = var.manage_apigateway_account_role ? 1 : 0

  name        = "${var.project}-apigateway-cloudwatch-role"
  description = "Lets API Gateway push execution and access logs to CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "apigateway.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "apigw_cloudwatch" {
  count = var.manage_apigateway_account_role ? 1 : 0

  name = "${var.project}-apigateway-cloudwatch-policy"
  role = aws_iam_role.apigw_cloudwatch[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteApiGatewayLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
        ]
        Resource = [
          "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/*",
          "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/apigateway/*:*",
          "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:API-Gateway-Execution-Logs*",
          "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:API-Gateway-Execution-Logs*:*",
        ]
      }
    ]
  })
}

resource "aws_api_gateway_account" "this" {
  count = var.manage_apigateway_account_role ? 1 : 0

  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch[0].arn

  depends_on = [aws_iam_role_policy.apigw_cloudwatch]
}
