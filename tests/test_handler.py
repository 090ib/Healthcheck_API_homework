"""Unit tests for the health-check Lambda handler.

DynamoDB is faked with moto, so the tests run offline and touch no AWS account.
"""

from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

SRC = Path(__file__).resolve().parents[1] / "src" / "lambda"
sys.path.insert(0, str(SRC))

TABLE_NAME = "staging-requests-db"
REGION = "eu-central-1"


@pytest.fixture()
def handler(monkeypatch):
    """Import the handler with a moto-backed DynamoDB table in place."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("ENVIRONMENT", "staging")

    with mock_aws():
        boto3.client("dynamodb", region_name=REGION).create_table(
            TableName=TABLE_NAME,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        module = importlib.import_module("handler")
        importlib.reload(module)
        yield module
    sys.modules.pop("handler", None)


def _event(method="POST", body=None, qs=None):
    return {
        "httpMethod": method,
        "path": "/health",
        "body": body,
        "queryStringParameters": qs,
        "isBase64Encoded": False,
        "requestContext": {
            "requestId": "test-request-id",
            "identity": {"sourceIp": "203.0.113.7", "userAgent": "pytest"},
        },
    }


def _scan(table_name=TABLE_NAME):
    return boto3.resource("dynamodb", region_name=REGION).Table(table_name).scan()["Items"]


def test_post_with_payload_returns_200_and_persists(handler):
    event = _event(body=json.dumps({"payload": {"service": "checkout"}}))

    result = handler.lambda_handler(event, None)
    body = json.loads(result["body"])

    assert result["statusCode"] == 200
    assert body["status"] == "healthy"
    assert body["message"] == "Request processed and saved."

    items = _scan()
    assert len(items) == 1
    assert items[0]["id"] == body["id"]
    assert items[0]["payload"] == {"service": "checkout"}
    assert items[0]["environment"] == "staging"
    assert items[0]["source_ip"] == "203.0.113.7"
    assert int(items[0]["expires_at"]) > int(items[0]["received_at"])


def test_get_with_payload_querystring_returns_200(handler):
    result = handler.lambda_handler(_event(method="GET", qs={"payload": "ping"}), None)

    assert result["statusCode"] == 200
    items = _scan()
    assert items[0]["payload"] == "ping"
    assert items[0]["payload_source"] == "querystring"


def test_body_without_payload_key_returns_400(handler):
    result = handler.lambda_handler(_event(body=json.dumps({"nope": 1})), None)

    assert result["statusCode"] == 400
    assert "payload" in json.loads(result["body"])["message"]
    assert _scan() == []


def test_missing_body_and_querystring_returns_400(handler):
    result = handler.lambda_handler(_event(method="GET"), None)

    assert result["statusCode"] == 400
    assert _scan() == []


def test_malformed_json_returns_400(handler):
    result = handler.lambda_handler(_event(body="{not json"), None)

    assert result["statusCode"] == 400
    assert "valid JSON" in json.loads(result["body"])["message"]


def test_non_object_body_returns_400(handler):
    result = handler.lambda_handler(_event(body=json.dumps(["payload"])), None)

    assert result["statusCode"] == 400


def test_oversized_body_returns_400(handler, monkeypatch):
    oversized = json.dumps({"payload": "x" * 9000})
    result = handler.lambda_handler(_event(body=oversized), None)

    assert result["statusCode"] == 400
    assert "maximum" in json.loads(result["body"])["message"]


def test_floats_are_stored_as_decimal(handler):
    result = handler.lambda_handler(_event(body=json.dumps({"payload": {"latency": 12.5}})), None)

    assert result["statusCode"] == 200
    assert float(_scan()[0]["payload"]["latency"]) == 12.5


def test_dynamodb_failure_returns_500(handler, monkeypatch):
    def boom(*_args, **_kwargs):
        raise RuntimeError("table unavailable")

    monkeypatch.setattr(handler, "save_request", boom)
    result = handler.lambda_handler(_event(body=json.dumps({"payload": "x"})), None)

    assert result["statusCode"] == 500
    assert json.loads(result["body"])["status"] == "error"


def test_event_is_logged(handler, caplog):
    with caplog.at_level("INFO"):
        handler.lambda_handler(_event(body=json.dumps({"payload": "x"})), None)

    assert any("Incoming request event" in record.getMessage() for record in caplog.records)
