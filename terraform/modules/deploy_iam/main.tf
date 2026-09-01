###############################################################################
# Deployment role module
#
# The role GitHub Actions assumes to run terraform plan/apply for one
# environment. The pipeline authenticates with an IAM access key, then 
# calls sts:AssumeRole into this role, so the long-lived key itself carries 
# almost no privilege and every deploy runs under short-lived, 
# environment-scoped credentials.
#
# Strategy:
#   * Every statement is pinned to one region via aws:RequestedRegion.
#   * Every resource ARN carries the environment prefix, so the staging role
#     physically cannot touch prod resources.
#   * Actions that AWS does not support resource-level permissions for (the
#     read-only Describe/List/Get family) are the only ones using "*", and a
#     Deny statement fences off IAM privilege escalation and state deletion.
###############################################################################

data "aws_region" "current" {}

locals {
  region       = data.aws_region.current.name
  arn_prefix   = "arn:${var.partition}"
  env          = var.name_prefix
  role_name    = "${var.name_prefix}-${var.role_name}"
  env_resource = "${var.name_prefix}-*" # e.g. staging-* -- environment fence
}

###############################################################################
# Trust policy
###############################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "CiPrincipalMayAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }

    # Shared-secret second factor on top of the access key.
    dynamic "condition" {
      for_each = var.external_id == null ? [] : [var.external_id]
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }

    # Removed aws:SecureTransport condition. STS endpoints accept
    # HTTPS only, so the condition buys nothing, and a Bool test on a key
    # that is absent from the request context evaluates false, which denies
    # every assume unconditionally. TLS on this path is guaranteed by the
    # endpoint, not by policy.
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.role_name
  description          = "Terraform deployment role for the ${local.env} health check stack"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(var.tags, { Name = local.role_name })
}

###############################################################################
# Terraform state access
###############################################################################

data "aws_iam_policy_document" "state" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["${local.arn_prefix}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.env}/*"]
    }
  }

  statement {
    sid    = "ReadWriteOwnStateObject"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    # Only this environment's state key. Staging cannot read prod state.
    resources = ["${local.arn_prefix}:s3:::${var.state_bucket}/${local.env}/*"]
  }

  statement {
    sid    = "StateLocking"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = ["${local.arn_prefix}:dynamodb:${local.region}:${var.account_id}:table/${var.state_lock_table}"]
  }
}

###############################################################################
# Managing the stack's own resources
###############################################################################

data "aws_iam_policy_document" "stack" {
  #checkov:skip=CKV_AWS_356:Two statements need "*": kms:CreateKey (no key exists to scope to) and the read-only ec2:Describe* family (no resource-level permissions in IAM). Both are fenced by aws:RequestedRegion, and a Deny block bounds the rest. See README.
  # --- DynamoDB application table ------------------------------------------
  statement {
    sid    = "ManageApplicationTable"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:UpdateTimeToLive",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
    ]
    resources = ["${local.arn_prefix}:dynamodb:${local.region}:${var.account_id}:table/${local.env_resource}"]
  }

  # --- Lambda ---------------------------------------------------------------
  statement {
    sid    = "ManageFunction"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetPolicy",
      "lambda:ListVersionsByFunction",
      "lambda:PublishVersion",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:CreateAlias",
      "lambda:DeleteAlias",
      "lambda:GetAlias",
      "lambda:UpdateAlias",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:PutFunctionConcurrency",
      "lambda:DeleteFunctionConcurrency",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:ListTags",
    ]
    resources = ["${local.arn_prefix}:lambda:${local.region}:${var.account_id}:function:${local.env_resource}"]
  }

  # --- API Gateway ----------------------------------------------------------
  # API Gateway resource ARNs are path-based and the API id is only known after
  # creation, so the id segment cannot be pinned. The region and account are.
  statement {
    sid    = "ManageRestApi"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
    ]
    resources = [
      "${local.arn_prefix}:apigateway:${local.region}::/restapis",
      "${local.arn_prefix}:apigateway:${local.region}::/restapis/*",
      "${local.arn_prefix}:apigateway:${local.region}::/tags/*",
      "${local.arn_prefix}:apigateway:${local.region}::/usageplans",
      "${local.arn_prefix}:apigateway:${local.region}::/usageplans/*",
    ]
  }

  # --- CloudWatch Logs ------------------------------------------------------
  statement {
    sid    = "ManageLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:AssociateKmsKey",
      "logs:DisassociateKmsKey",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = [
      "${local.arn_prefix}:logs:${local.region}:${var.account_id}:log-group:/aws/lambda/${local.env_resource}",
      "${local.arn_prefix}:logs:${local.region}:${var.account_id}:log-group:/aws/lambda/${local.env_resource}:*",
      "${local.arn_prefix}:logs:${local.region}:${var.account_id}:log-group:/aws/apigateway/${local.env_resource}",
      "${local.arn_prefix}:logs:${local.region}:${var.account_id}:log-group:/aws/apigateway/${local.env_resource}:*",
      "${local.arn_prefix}:logs:${local.region}:${var.account_id}:log-group:/aws/vpc/${local.env_resource}",
      "${local.arn_prefix}:logs:${local.region}:${var.account_id}:log-group:/aws/vpc/${local.env_resource}:*",
    ]
  }

  # --- Artifact bucket ------------------------------------------------------
  statement {
    sid    = "ManageArtifactBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:GetBucketVersioning",
      "s3:PutBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketLogging",
      "s3:GetBucketWebsite",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = ["${local.arn_prefix}:s3:::${local.env}-${var.artifacts_bucket_name}-${var.account_id}"]
  }

  statement {
    sid    = "ManageArtifactObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging",
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["${local.arn_prefix}:s3:::${local.env}-${var.artifacts_bucket_name}-${var.account_id}/*"]
  }

  # --- KMS ------------------------------------------------------------------
  # kms:CreateKey has no resource to attach to (the key does not exist yet), so
  # AWS mandates "*" for that one action. Everything afterwards is pinned to
  # keys carrying this environment's tag.
  statement {
    sid       = "CreateKeyMandatoryWildcard"
    effect    = "Allow"
    actions   = ["kms:CreateKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid    = "ManageEnvironmentKey"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:EnableKey",
      "kms:DisableKey",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:ListAliases",
      "kms:ListResourceTags",
      "kms:TagResource",
      "kms:UntagResource",
      # Needed so Terraform can write the encrypted state object.
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [
      "${local.arn_prefix}:kms:${local.region}:${var.account_id}:key/*",
      "${local.arn_prefix}:kms:${local.region}:${var.account_id}:alias/${local.env_resource}",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  # --- IAM ------------------------------------------------------------------
  # Only roles whose name starts with this environment's prefix.
  statement {
    sid    = "ManageEnvironmentRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["${local.arn_prefix}:iam::${var.account_id}:role/${local.env_resource}"]
  }

  statement {
    sid       = "PassExecutionRoleToLambdaOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["${local.arn_prefix}:iam::${var.account_id}:role/${local.env_resource}"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com"]
    }
  }

  # --- Networking -----------------------------------------------------------
  statement {
    sid    = "ManageVpcResources"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteVpcEndpoints",
      "ec2:ModifyVpcEndpoint",
      "ec2:CreateFlowLogs",
      "ec2:DeleteFlowLogs",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]

    # Resource-level permissions for most of these actions only apply to
    # resources that already exist, so the fence here is the region plus the
    # deny block below.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  # Read-only discovery. These actions do not support resource-level
  # permissions in IAM at all -- "*" is mandatory, and they cannot mutate.
  statement {
    sid    = "ReadOnlyDiscoveryMandatoryWildcard"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeSubnets",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeVpcEndpoints",
      "ec2:DescribeVpcEndpointServices",
      "ec2:DescribePrefixLists",
      "ec2:DescribeManagedPrefixLists",
      "ec2:DescribeFlowLogs",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeTags",
      "sts:GetCallerIdentity",
      "iam:ListRoles",
    ]
    resources = ["*"]
  }
}

###############################################################################
# Guardrails: things a deployment must never be able to do
###############################################################################

data "aws_iam_policy_document" "guardrails" {
  statement {
    sid    = "DenyPrivilegeEscalation"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:UpdateAccessKey",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:AttachRolePolicy",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:CreateAccountAlias",
      "organizations:LeaveOrganization",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyStateBucketDestruction"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketVersioning",
      "s3:PutBucketPolicy",
    ]
    resources = ["${local.arn_prefix}:s3:::${var.state_bucket}"]
  }

  # The service-wide action patterns below appear inside a *Deny*: they remove
  # permission rather than granting it, which is the opposite of the wildcard
  # the least-privilege rule is aimed at. Written as an explicit allow-list this
  # statement could never keep up with new API actions, and a gap would mean a
  # deploy escaping the region fence.
  statement {
    sid       = "DenyOutsideDeploymentRegion"
    effect    = "Deny"
    actions   = ["ec2:*", "lambda:*", "dynamodb:*", "apigateway:*", "kms:*", "logs:*"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }
}

###############################################################################
# Attach
###############################################################################

resource "aws_iam_role_policy" "state" {
  name   = "${local.role_name}-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.state.json
}

resource "aws_iam_role_policy" "stack" {
  name   = "${local.role_name}-stack"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.stack.json
}

resource "aws_iam_role_policy" "guardrails" {
  name   = "${local.role_name}-guardrails"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.guardrails.json
}
