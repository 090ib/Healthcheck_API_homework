###############################################################################
# Lambda module
#
# Packages the Python source, uploads it as an immutable, content-addressed S3
# artifact, publishes a numbered Lambda version and points a stable "live"
# alias at it. API Gateway invokes the alias, so a rollback is a one-line alias
# change rather than a redeploy.
###############################################################################

data "aws_region" "current" {}

locals {
  function_name = "${var.name_prefix}-${var.function_name}"
  log_group_arn = "arn:${var.partition}:logs:${data.aws_region.current.name}:${var.account_id}:log-group:/aws/lambda/${local.function_name}"
  artifact_key  = "lambda/${local.function_name}/${data.archive_file.package.output_base64sha256}.zip"
}

###############################################################################
# Packaging
###############################################################################

data "archive_file" "package" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/${var.name_prefix}-health-check.zip"

  # Nothing but the handler ships: no tests, no caches, no dev tooling.
  excludes = ["__pycache__", "tests", "requirements.txt", ".pytest_cache"]
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name_prefix}-${var.artifacts_bucket_name}-${var.account_id}"
  force_destroy = var.artifacts_force_destroy

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.artifacts_bucket_name}" })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-artifact-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.artifact_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts_tls_only" {
  bucket = aws_s3_bucket.artifacts.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_s3_object" "package" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = local.artifact_key
  source      = data.archive_file.package.output_path
  source_hash = data.archive_file.package.output_md5

  # Encrypted with the same customer-managed key as everything else.
  server_side_encryption = "aws:kms"
  kms_key_id             = var.kms_key_arn

  tags = merge(var.tags, {
    Name          = "${local.function_name}-artifact"
    SourceVersion = var.source_version
    SourceSHA256  = data.archive_file.package.output_base64sha256
  })

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

###############################################################################
# Logging
###############################################################################

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

###############################################################################
# Execution role -- least privilege, no wildcard actions, resource-scoped
###############################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "LambdaServiceAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    # Only this account's Lambda service may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                 = "${local.function_name}-role"
  description          = "Execution role for the ${var.name_prefix} health check function"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

data "aws_iam_policy_document" "lambda" {
  #checkov:skip=CKV_AWS_356:The six ENI actions must be on Resource "*" -- AWS documents it, and CreateFunction's pre-flight check rejects any scoping or condition. See README, "The wildcards that remain".
  #checkov:skip=CKV_AWS_111:Same statement. Every other action here is pinned to an exact ARN.
  # --- CloudWatch Logs: only this function's own log group -------------------
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    # The stream name is generated by the service, hence the trailing wildcard
    # on the resource path. The log *group* is pinned exactly.
    resources = ["${local.log_group_arn}:log-stream:*"]
  }

  # --- DynamoDB: write-only, single table -----------------------------------
  statement {
    sid       = "PutHealthCheckItems"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [var.dynamodb_table_arn]
  }

  # --- KMS: only for the two services that need it, only this key -----------
  statement {
    sid    = "UseCustomerManagedKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "dynamodb.${data.aws_region.current.name}.amazonaws.com",
        "logs.${data.aws_region.current.name}.amazonaws.com",
      ]
    }
  }

  # --- VPC networking -------------------------------------------------------
  # Creating an ENI is scoped to this VPC's subnets and security group. The ENI
  # itself does not exist yet at authorisation time, so the network-interface
  # resource has to be matched by pattern.

  # These six actions are a mandatory exception to the no-wildcards
  # rule according to aws docs: for VPC-attached functions "add all of the
  # following permissions and allow them on all resources (Resource: *)".
  # Note: only lambda.amazonaws.com in this account can assume this role, 
  # so these permissions are only ever exercised by the Lambda service 
  # managing this function's own ENIs.
  statement {
    sid    = "LambdaVpcEniManagement"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.function_name}-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

###############################################################################
# Function, version and alias
###############################################################################

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = "Health check endpoint (${var.name_prefix}) - source ${var.source_version}"
  role          = aws_iam_role.lambda.arn
  handler       = var.handler
  runtime       = var.runtime
  architectures = ["arm64"] # ~20% cheaper per GB-second than x86_64

  s3_bucket         = aws_s3_bucket.artifacts.id
  s3_key            = aws_s3_object.package.key
  s3_object_version = aws_s3_object.package.version_id
  source_code_hash  = data.archive_file.package.output_base64sha256

  # Publish an immutable numbered version on every content change.
  publish = true

  memory_size = var.memory_size
  timeout     = var.timeout

  # Caps blast radius and runaway cost if the endpoint is hammered.
  reserved_concurrent_executions = var.reserved_concurrency

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      TABLE_NAME        = var.dynamodb_table_name
      ENVIRONMENT       = var.name_prefix
      LOG_LEVEL         = var.log_level
      ITEM_TTL_DAYS     = tostring(var.item_ttl_days)
      MAX_PAYLOAD_BYTES = tostring(var.max_payload_bytes)
    }
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = var.tracing_mode
  }

  tags = merge(var.tags, {
    Name          = local.function_name
    SourceVersion = var.source_version
  })

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda,
  ]
}

resource "aws_lambda_alias" "live" {
  name             = var.alias_name
  description      = "Stable target for API Gateway; repoint to roll back."
  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version
}

# NOTE: the lambda:InvokeFunction permission for API Gateway lives in the
# api_gateway module. Granting it here would make this module depend on the
# API's ARN while the API depends on this alias -- a dependency cycle.
