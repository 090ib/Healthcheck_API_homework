###############################################################################
# API Gateway module (REST API / v1)
#
# REST API rather than HTTP API specifically because it supports request
# validators: a POST without a "payload" key, or a GET without a "payload"
# query-string parameter, is rejected with 400 at the edge and never reaches
# Lambda. Throttling is applied at both the stage and the method level to blunt
# request floods.
###############################################################################

locals {
  api_name = "${var.name_prefix}-${var.api_name}"
  # Wildcards here are API Gateway's own ARN grammar for "any method, any path
  # in this stage", not IAM permission wildcards.
  execution_arn_all = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_api_gateway_rest_api" "this" {
  name        = local.api_name
  description = "Health check API (${var.name_prefix})"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = merge(var.tags, { Name = local.api_name })

  # Replacing a REST API in place would take the endpoint down between the
  # destroy and the create. Building the replacement first keeps the URL
  # serving throughout.
  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# /health resource
###############################################################################

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = var.route_path
}

###############################################################################
# [sec] Request validation -- invalid requests never reach Lambda
###############################################################################

resource "aws_api_gateway_model" "health_request" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "HealthRequest"
  description  = "Body schema for POST ${var.route_path}: a 'payload' key is mandatory."
  content_type = "application/json"

  schema = jsonencode({
    "$schema"            = "http://json-schema.org/draft-04/schema#"
    title                = "HealthRequest"
    type                 = "object"
    required             = ["payload"]
    additionalProperties = true
    properties = {
      payload = {
        description = "Caller-supplied payload; stored verbatim in DynamoDB."
      }
    }
  })
}

resource "aws_api_gateway_request_validator" "body_and_params" {
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  name                        = "${local.api_name}-validate-body-and-params"
  validate_request_body       = true
  validate_request_parameters = true
}

resource "aws_api_gateway_request_validator" "params_only" {
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  name                        = "${local.api_name}-validate-params"
  validate_request_body       = false
  validate_request_parameters = true
}

###############################################################################
# POST /health -- body must contain "payload"
###############################################################################

resource "aws_api_gateway_method" "post" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.health.id
  http_method          = "POST"
  authorization        = var.authorization
  api_key_required     = var.api_key_required
  request_validator_id = aws_api_gateway_request_validator.body_and_params.id

  request_models = {
    "application/json" = aws_api_gateway_model.health_request.name
  }
}

resource "aws_api_gateway_integration" "post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
  timeout_milliseconds    = var.integration_timeout_ms
}

###############################################################################
# GET /health -- "payload" must be supplied as a query-string parameter
###############################################################################

resource "aws_api_gateway_method" "get" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  resource_id          = aws_api_gateway_resource.health.id
  http_method          = "GET"
  authorization        = var.authorization
  api_key_required     = var.api_key_required
  request_validator_id = aws_api_gateway_request_validator.params_only.id

  request_parameters = {
    "method.request.querystring.payload" = true
  }
}

resource "aws_api_gateway_integration" "get" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.lambda_invoke_arn
  timeout_milliseconds    = var.integration_timeout_ms
}

###############################################################################
# Consistent JSON for gateway-generated 4xx/429 responses
###############################################################################

resource "aws_api_gateway_gateway_response" "bad_request_body" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "BAD_REQUEST_BODY"
  status_code   = "400"

  response_templates = {
    "application/json" = "{\"status\":\"error\",\"message\":\"Request body must be a JSON object containing a 'payload' key.\"}"
  }
}

resource "aws_api_gateway_gateway_response" "bad_request_parameters" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "BAD_REQUEST_PARAMETERS"
  status_code   = "400"

  response_templates = {
    "application/json" = "{\"status\":\"error\",\"message\":\"Missing required 'payload' query-string parameter.\"}"
  }
}

resource "aws_api_gateway_gateway_response" "throttled" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = "THROTTLED"
  status_code   = "429"

  response_templates = {
    "application/json" = "{\"status\":\"error\",\"message\":\"Too many requests.\"}"
  }
}

###############################################################################
# Deployment + stage
###############################################################################

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.health.id,
      aws_api_gateway_method.post.id,
      aws_api_gateway_method.get.id,
      aws_api_gateway_integration.post.id,
      aws_api_gateway_integration.get.id,
      aws_api_gateway_model.health_request.schema,
      aws_api_gateway_request_validator.body_and_params.id,
      aws_api_gateway_request_validator.params_only.id,
      var.lambda_invoke_arn,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/${local.api_name}/access"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id           = aws_api_gateway_rest_api.this.id
  deployment_id         = aws_api_gateway_deployment.this.id
  stage_name            = var.stage_name
  description           = "${var.name_prefix} stage"
  cache_cluster_enabled = false
  xray_tracing_enabled  = var.xray_tracing_enabled

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId       = "$context.requestId"
      ip              = "$context.identity.sourceIp"
      requestTime     = "$context.requestTime"
      httpMethod      = "$context.httpMethod"
      routeKey        = "$context.resourcePath"
      status          = "$context.status"
      protocol        = "$context.protocol"
      responseLength  = "$context.responseLength"
      integrationErr  = "$context.integration.error"
      validationError = "$context.error.message"
    })
  }

  tags = merge(var.tags, { Name = "${local.api_name}-${var.stage_name}" })

  depends_on = [aws_cloudwatch_log_group.access_logs]
}

###############################################################################
# Throttling (anti-DDoS) + execution logging
###############################################################################

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name

  # "*/*" is API Gateway's syntax for "every method on every resource".
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
    metrics_enabled        = true
    logging_level          = var.logging_level
    data_trace_enabled     = false # never log full request bodies
  }
}

###############################################################################
# Optional usage plan + API key (a second throttling tier, per client)
###############################################################################

resource "aws_api_gateway_usage_plan" "this" {
  count = var.enable_usage_plan ? 1 : 0

  name        = "${local.api_name}-usage-plan"
  description = "Per-client quota and throttle for ${var.name_prefix}"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = var.usage_plan_rate_limit
    burst_limit = var.usage_plan_burst_limit
  }

  quota_settings {
    limit  = var.usage_plan_quota_limit
    period = var.usage_plan_quota_period
  }

  tags = var.tags
}

###############################################################################
# Permission for API Gateway to invoke the Lambda alias
###############################################################################

resource "aws_lambda_permission" "invoke" {
  statement_id  = "AllowInvokeFrom-${local.api_name}"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  qualifier     = var.lambda_alias_name
  principal     = "apigateway.amazonaws.com"

  # Scoped to this API only.
  source_arn = local.execution_arn_all
}
