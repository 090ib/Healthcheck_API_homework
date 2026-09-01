"""Health check Lambda function.

Invoked by API Gateway (REST API v1, Lambda proxy integration) on /health.

Responsibilities:
  1. Log the incoming request event to CloudWatch.
  2. Validate that the request carries a ``payload`` key (API Gateway
     already rejects requests that do not, see the request
     validator in the api_gateway module).
  3. Persist the request details to DynamoDB under a freshly generated UUID.
  4. Return 200 OK with a JSON body.

Only the AWS SDK bundled with the Lambda runtime is used, so the deployment
package has no third-party dependencies.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import time
import uuid
from decimal import Decimal
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
TABLE_NAME = os.environ.get("TABLE_NAME", "")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")
# Items are expired automatically to keep the table (and the bill) small.
TTL_DAYS = int(os.environ.get("ITEM_TTL_DAYS", "30"))
MAX_PAYLOAD_BYTES = int(os.environ.get("MAX_PAYLOAD_BYTES", "8192"))

logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

# Retries are bounded so a DynamoDB brown-out cannot pin the function open for
# its whole timeout budget.
_BOTO_CONFIG = Config(
    retries={"max_attempts": 3, "mode": "standard"},
    connect_timeout=2,
    read_timeout=3,
)

_dynamodb = boto3.resource("dynamodb", config=_BOTO_CONFIG)
_table = _dynamodb.Table(TABLE_NAME) if TABLE_NAME else None


class ValidationError(Exception):
    """Raised when the incoming request does not satisfy the contract."""


def _response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
        },
        "body": json.dumps(body),
    }


def _parse_body(event: dict[str, Any]) -> dict[str, Any] | None:
    """Return the JSON body as a dict, or None when there is no body."""
    raw = event.get("body")
    if raw is None or raw == "":
        return None
    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except Exception as exc:  # surfaced to the caller as a 400 below
            raise ValidationError("Request body is not valid base64-encoded UTF-8.") from exc
    if len(raw.encode("utf-8")) > MAX_PAYLOAD_BYTES:
        raise ValidationError(
            f"Request body exceeds the maximum of {MAX_PAYLOAD_BYTES} bytes."
        )
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise ValidationError("Request body is not valid JSON.") from exc
    if not isinstance(parsed, dict):
        raise ValidationError("Request body must be a JSON object.")
    return parsed


def extract_payload(event: dict[str, Any]) -> tuple[Any, str]:
    """Locate the ``payload`` value and report where it came from.

    POST requests carry it in the JSON body. GET requests have no body, so the
    equivalent contract is the required ``payload`` query-string parameter --
    API Gateway enforces both, this function re-checks them.
    """
    body = _parse_body(event)
    if body is not None:
        if "payload" not in body:
            raise ValidationError("Request body must contain a 'payload' key.")
        return body["payload"], "body"

    params = event.get("queryStringParameters") or {}
    if "payload" in params and params["payload"] not in (None, ""):
        return params["payload"], "querystring"

    raise ValidationError(
        "Missing 'payload'. Send a JSON body containing a 'payload' key, "
        "or a 'payload' query-string parameter."
    )


def _request_context(event: dict[str, Any]) -> dict[str, Any]:
    ctx = event.get("requestContext") or {}
    identity = ctx.get("identity") or {}
    return {
        "api_request_id": ctx.get("requestId"),
        "http_method": event.get("httpMethod") or ctx.get("httpMethod"),
        "path": event.get("path") or ctx.get("path"),
        "source_ip": identity.get("sourceIp"),
        "user_agent": identity.get("userAgent"),
    }


def _to_dynamo_safe(value: Any) -> Any:
    """DynamoDB has no float type; convert via str to keep full precision."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, list):
        return [_to_dynamo_safe(v) for v in value]
    if isinstance(value, dict):
        return {k: _to_dynamo_safe(v) for k, v in value.items()}
    return value


def save_request(payload: Any, source: str, event: dict[str, Any]) -> str:
    """Persist the request and return the generated item id."""
    if _table is None:
        raise RuntimeError("TABLE_NAME environment variable is not set.")

    item_id = str(uuid.uuid4())
    now = int(time.time())
    item = {
        "id": item_id,
        "environment": ENVIRONMENT,
        "received_at": now,
        "expires_at": now + TTL_DAYS * 86400,
        "payload_source": source,
        "payload": _to_dynamo_safe(payload),
        **{k: v for k, v in _request_context(event).items() if v is not None},
    }
    _table.put_item(Item=item, ConditionExpression="attribute_not_exists(id)")
    return item_id


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    # Requirement: log the incoming request event to CloudWatch.
    logger.info("Incoming request event: %s", json.dumps(event, default=str))

    try:
        payload, source = extract_payload(event)
    except ValidationError as exc:
        logger.warning("Request rejected: %s", exc)
        return _response(400, {"status": "error", "message": str(exc)})

    try:
        item_id = save_request(payload, source, event)
    except (ClientError, BotoCoreError, RuntimeError):
        logger.exception("Failed to persist request to DynamoDB")
        return _response(
            500,
            {
                "status": "error",
                "message": "Request could not be saved.",
                "request_id": getattr(context, "aws_request_id", None),
            },
        )

    logger.info("Stored request %s in table %s", item_id, TABLE_NAME)
    return _response(
        200,
        {
            "status": "healthy",
            "message": "Request processed and saved.",
            "id": item_id,
        },
    )
