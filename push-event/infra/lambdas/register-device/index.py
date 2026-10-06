"""Register an FCM device token as an SNS platform endpoint."""

from __future__ import annotations

import json
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

sns = boto3.client("sns")
ssm = boto3.client("ssm")
secretsmanager = boto3.client("secretsmanager")
dynamodb = boto3.resource("dynamodb")

DEVICES_TABLE = os.environ["DEVICES_TABLE"]
FCM_SECRET_ARN = os.environ["FCM_SECRET_ARN"]
PLATFORM_APP_PARAM = os.environ["PLATFORM_APP_PARAM"]
PLATFORM_APP_NAME = os.environ["PLATFORM_APP_NAME"]

devices_table = dynamodb.Table(DEVICES_TABLE)


def _response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _username_from_event(event: dict[str, Any]) -> str | None:
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("claims", {})
    )
    username = claims.get("username") or claims.get("cognito:username")
    return username if isinstance(username, str) and username else None


def _load_service_account_json() -> str:
    secret = secretsmanager.get_secret_value(SecretId=FCM_SECRET_ARN)
    raw = secret.get("SecretString") or ""
    if not raw.strip():
        raise ValueError("FCM service account secret is empty")
    parsed = json.loads(raw)
    if parsed.get("placeholder") is True or parsed.get("type") == "ReplaceMe":
        raise ValueError(
            "FCM service account secret still has a placeholder. "
            "Put the Firebase service account JSON into Secrets Manager."
        )
    if "private_key" not in parsed or "project_id" not in parsed:
        raise ValueError(
            "FCM service account JSON must include private_key and project_id"
        )
    return raw


def _get_platform_application_arn() -> str | None:
    try:
        result = ssm.get_parameter(Name=PLATFORM_APP_PARAM)
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ParameterNotFound":
            return None
        raise
    value = result["Parameter"]["Value"]
    if not value or value == "PENDING":
        return None
    return value


def _ensure_platform_application() -> str:
    existing = _get_platform_application_arn()
    if existing:
        return existing

    # Token auth is inferred when PlatformCredential is a service-account JSON.
    # Passing AuthenticationMethod explicitly fails with Invalid attribute name.
    credential = _load_service_account_json()
    created = sns.create_platform_application(
        Name=PLATFORM_APP_NAME,
        Platform="GCM",
        Attributes={
            "PlatformCredential": credential,
        },
    )
    arn = created["PlatformApplicationArn"]
    ssm.put_parameter(
        Name=PLATFORM_APP_PARAM,
        Value=arn,
        Type="String",
        Overwrite=True,
    )
    return arn


def _create_or_update_endpoint(
    platform_application_arn: str,
    token: str,
    username: str,
) -> str:
    existing = devices_table.get_item(Key={"username": username}).get("Item")
    if existing and existing.get("endpointArn") and existing.get("fcmToken") == token:
        endpoint_arn = str(existing["endpointArn"])
        sns.set_endpoint_attributes(
            EndpointArn=endpoint_arn,
            Attributes={"Enabled": "true", "Token": token},
        )
        return endpoint_arn

    if existing and existing.get("endpointArn"):
        try:
            sns.set_endpoint_attributes(
                EndpointArn=str(existing["endpointArn"]),
                Attributes={"Enabled": "true", "Token": token},
            )
            return str(existing["endpointArn"])
        except ClientError:
            pass

    created = sns.create_platform_endpoint(
        PlatformApplicationArn=platform_application_arn,
        Token=token,
        CustomUserData=username[:2048],
    )
    return created["EndpointArn"]


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    username = _username_from_event(event)
    if not username:
        return _response(401, {"error": "Unauthorized"})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    fcm_token = body.get("fcmToken")
    if not isinstance(fcm_token, str) or not fcm_token.strip():
        return _response(400, {"error": "fcmToken is required"})

    try:
        platform_arn = _ensure_platform_application()
        endpoint_arn = _create_or_update_endpoint(
            platform_arn,
            fcm_token.strip(),
            username,
        )
        devices_table.put_item(
            Item={
                "username": username,
                "fcmToken": fcm_token.strip(),
                "endpointArn": endpoint_arn,
            }
        )
    except ValueError as exc:
        return _response(400, {"error": str(exc)})
    except ClientError as exc:
        return _response(500, {"error": exc.response["Error"].get("Message", str(exc))})

    return _response(
        200,
        {
            "username": username,
            "endpointArn": endpoint_arn,
        },
    )
