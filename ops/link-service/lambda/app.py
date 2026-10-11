"""First-party private artifact link resolver for OpenClaw.

Management uses direct Lambda invocation authorized by a role-scoped resource
policy. The public API exposes only GET /{code}; it stores no signed credential
and mints a fresh short-lived presigned URL on each valid click.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import string
import tempfile
import time
import uuid
from typing import Any

import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]
ARTIFACT_BUCKET = os.environ["ARTIFACT_BUCKET"]
ARTIFACT_PREFIX = os.environ.get("ARTIFACT_PREFIX", "artifacts/")
SNAPSHOT_BUCKET = os.environ["SNAPSHOT_BUCKET"]
DEFAULT_TTL_SECONDS = int(os.environ.get("DEFAULT_TTL_SECONDS", "604800"))
MAX_TTL_SECONDS = int(os.environ.get("MAX_TTL_SECONDS", "2592000"))
PRESIGN_SECONDS = int(os.environ.get("PRESIGN_SECONDS", "60"))
MAX_OBJECT_BYTES = int(os.environ.get("MAX_OBJECT_BYTES", str(10 * 1024 * 1024)))
CODE_LENGTH = int(os.environ.get("CODE_LENGTH", "8"))
PUBLIC_BASE_URL = os.environ["PUBLIC_BASE_URL"].rstrip("/")
MANAGEMENT_PRINCIPAL_ARN = os.environ["MANAGEMENT_PRINCIPAL_ARN"]

CODE_ALPHABET = string.ascii_letters + string.digits
if (
    not ARTIFACT_PREFIX
    or ARTIFACT_PREFIX.startswith("/")
    or not ARTIFACT_PREFIX.endswith("/")
    or ".." in ARTIFACT_PREFIX
    or any(ch in ARTIFACT_PREFIX for ch in "*?[]\\")
):
    raise RuntimeError("invalid_artifact_prefix_configuration")
if not re.fullmatch(r"https://[A-Za-z0-9.-]+", PUBLIC_BASE_URL):
    raise RuntimeError("invalid_public_base_url_configuration")
if not re.fullmatch(
    r"arn:[A-Za-z0-9-]+:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+",
    MANAGEMENT_PRINCIPAL_ARN,
):
    raise RuntimeError("invalid_management_principal_configuration")
SHA256_PATTERN = re.compile(r"^[a-f0-9]{64}$")
CHANNEL_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]{1,80}$")
CODE_REF_PATTERN = re.compile(r"^[a-f0-9]{12}$")
ALLOWED_CONTENT_TYPES = {
    "text/html",
    "text/markdown",
    "application/pdf",
    "application/zip",
    "application/json",
}
ALLOWED_IMAGE_PREFIX = "image/"
ALLOWED_VIDEO_PREFIX = "video/"

ERROR_MESSAGES = {
    "artifact_changed": "artifact changed after link creation",
    "artifact_unavailable": "artifact is unavailable",
    "code_allocation_failed": "a unique link code could not be allocated",
    "gone": "link expired or revoked",
    "hash_mismatch": "sha256 does not match artifact bytes",
    "invalid_channel": "channel is invalid",
    "invalid_code": f"code must be {CODE_LENGTH} alphanumeric characters",
    "invalid_content_type": "artifact content type is not allowed",
    "invalid_key": "key must be an allowlisted S3 object key",
    "invalid_label": "label must contain 1 to 120 characters",
    "invalid_operation": "operation must be create, status, or revoke",
    "invalid_request": "request is invalid",
    "invalid_sha256": "sha256 must be 64 lowercase hexadecimal characters",
    "invalid_size": f"artifact size must be 1 to {MAX_OBJECT_BYTES} bytes",
    "invalid_target": "link target is no longer allowed",
    "invalid_ttl": f"ttlSeconds must be an integer from 60 to {MAX_TTL_SECONDS}",
    "not_found": "link not found",
    "route_not_found": "route not found",
    "snapshot_failed": "artifact snapshot could not be created",
    "unsupported_field": "request contains unsupported fields",
    "url_target_prohibited": "URL targets are not allowed",
}
INTERNAL_ERROR_CODE = "internal_error"
INTERNAL_ERROR_MESSAGE = "link service request failed"

LOG_SCHEMAS = {
    "link_artifact_fingerprint_changed": {"codeRef"},
    "link_artifact_missing": {"codeRef"},
    "link_created": {"codeRef", "channel", "expiresAt", "contentLength"},
    "link_gone": {"codeRef", "disabled"},
    "link_invalid_target_class": {"codeRef"},
    "link_resolved": {"codeRef", "expiresAt"},
    "link_revoked": {"codeRef"},
    "request_failed": {"requestClass", "errorCode"},
    "request_rejected": {"requestClass", "errorCode"},
}
REQUEST_CLASSES = {"management", "resolve", "unknown"}


ddb = boto3.resource("dynamodb")
table = ddb.Table(TABLE_NAME)
s3 = boto3.client("s3")


class RequestError(Exception):
    """A caller-safe error selected from the fixed public error catalog."""

    def __init__(self, code: str):
        if code not in ERROR_MESSAGES:
            raise RuntimeError("unknown_public_error_code")
        super().__init__(code)
        self.code = code

    @property
    def message(self) -> str:
        return ERROR_MESSAGES[self.code]


def _response(
    status: int,
    body: dict[str, Any] | str,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    base_headers = {
        "cache-control": "no-store",
        "content-type": "application/json; charset=utf-8",
        "referrer-policy": "no-referrer",
        "x-content-type-options": "nosniff",
        "x-robots-tag": "noindex, nofollow",
    }
    if headers:
        base_headers.update(headers)
    payload = body if isinstance(body, str) else json.dumps(body, separators=(",", ":"))
    return {"statusCode": status, "headers": base_headers, "body": payload}


def _error_response(status: int, code: str) -> dict[str, Any]:
    message = ERROR_MESSAGES.get(code)
    if message is None:
        if code != INTERNAL_ERROR_CODE:
            raise RuntimeError("unknown_error_response_code")
        message = INTERNAL_ERROR_MESSAGE
    return _response(status, {"error": {"code": code, "message": message}})


def _log(event: str, **fields: Any) -> None:
    """Emit only schema-checked, bounded audit fields.

    Never pass exception text, object keys, signed URLs, request bodies,
    credentials, source IPs, or arbitrary caller fields to this function.
    """

    expected_fields = LOG_SCHEMAS.get(event)
    if expected_fields is None or set(fields) != expected_fields:
        raise RuntimeError("invalid_audit_log_schema")

    for name, value in fields.items():
        if name == "codeRef" and (
            not isinstance(value, str) or not CODE_REF_PATTERN.fullmatch(value)
        ):
            raise RuntimeError("invalid_audit_code_ref")
        if name == "channel" and (
            not isinstance(value, str) or not CHANNEL_PATTERN.fullmatch(value)
        ):
            raise RuntimeError("invalid_audit_channel")
        if name == "requestClass" and value not in REQUEST_CLASSES:
            raise RuntimeError("invalid_audit_request_class")
        if name == "errorCode" and (
            not isinstance(value, str)
            or value not in {*ERROR_MESSAGES, INTERNAL_ERROR_CODE}
        ):
            raise RuntimeError("invalid_audit_error_code")
        if name in {"expiresAt", "contentLength"} and (
            not isinstance(value, int) or isinstance(value, bool) or value < 0
        ):
            raise RuntimeError("invalid_audit_integer")
        if name == "disabled" and not isinstance(value, bool):
            raise RuntimeError("invalid_audit_boolean")

    print(json.dumps({"event": event, **fields}, separators=(",", ":")))


def _request_class(event: dict[str, Any]) -> str:
    if event.get("operation") is not None:
        return "management"
    if event.get("routeKey") == "GET /{code}":
        return "resolve"
    return "unknown"


def _validate_key(key: Any) -> str:
    if not isinstance(key, str) or not key or len(key) > 900:
        raise RequestError("invalid_key")
    if not key.startswith(ARTIFACT_PREFIX):
        raise RequestError("invalid_key")
    if ".." in key.split("/") or "\x00" in key or key.startswith("/"):
        raise RequestError("invalid_key")
    return key


def _allowed_content_type(value: str) -> bool:
    media_type = (value or "application/octet-stream").split(";", 1)[0].strip().lower()
    return (
        media_type in ALLOWED_CONTENT_TYPES
        or media_type.startswith(ALLOWED_IMAGE_PREFIX)
        or media_type.startswith(ALLOWED_VIDEO_PREFIX)
    )


def _short_url(code: str) -> str:
    return f"{PUBLIC_BASE_URL}/{code}"


def _code_ref(code: str) -> str:
    return hashlib.sha256(code.encode("ascii")).hexdigest()[:12]


def _create(request: dict[str, Any]) -> dict[str, Any]:
    forbidden = {"url", "target", "location", "presignedUrl", "presigned_url"} & set(
        request
    )
    if forbidden:
        raise RequestError("url_target_prohibited")
    allowed = {"key", "ttlSeconds", "sha256", "channel", "label"}
    if set(request) - allowed:
        raise RequestError("unsupported_field")

    key = _validate_key(request.get("key"))
    ttl = request.get("ttlSeconds", DEFAULT_TTL_SECONDS)
    if (
        not isinstance(ttl, int)
        or isinstance(ttl, bool)
        or ttl < 60
        or ttl > MAX_TTL_SECONDS
    ):
        raise RequestError("invalid_ttl")
    expected_sha = request.get("sha256")
    if not isinstance(expected_sha, str) or not SHA256_PATTERN.fullmatch(expected_sha):
        raise RequestError("invalid_sha256")
    channel = request.get("channel", "openclaw-ec2")
    if not isinstance(channel, str) or not CHANNEL_PATTERN.fullmatch(channel):
        raise RequestError("invalid_channel")
    label = request.get("label")
    if label is not None and (
        not isinstance(label, str) or not 1 <= len(label) <= 120
    ):
        raise RequestError("invalid_label")

    try:
        source = s3.get_object(
            Bucket=ARTIFACT_BUCKET,
            Key=key,
            ChecksumMode="ENABLED",
        )
    except ClientError as exc:
        status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if status in {403, 404}:
            raise RequestError("artifact_unavailable") from None
        raise

    size = int(source.get("ContentLength", 0))
    content_type = source.get("ContentType", "application/octet-stream")
    if size <= 0 or size > MAX_OBJECT_BYTES:
        source["Body"].close()
        raise RequestError("invalid_size")
    normalized_content_type = content_type.split(";", 1)[0].strip().lower()
    if not _allowed_content_type(content_type) or normalized_content_type == "image/svg+xml":
        source["Body"].close()
        raise RequestError("invalid_content_type")
    stored_sha = (source.get("Metadata") or {}).get("sha256")
    if stored_sha and not secrets.compare_digest(expected_sha, stored_sha):
        source["Body"].close()
        raise RequestError("hash_mismatch")

    tmp_path = ""
    digest = hashlib.sha256()
    try:
        with tempfile.NamedTemporaryFile(
            prefix="link-artifact-",
            dir="/tmp",
            delete=False,
        ) as tmp:
            tmp_path = tmp.name
            while True:
                chunk = source["Body"].read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                tmp.write(chunk)
        if not secrets.compare_digest(expected_sha, digest.hexdigest()):
            raise RequestError("hash_mismatch")

        snapshot_key = f"snapshots/{expected_sha}/{uuid.uuid4().hex}"
        with open(tmp_path, "rb") as verified_stream:
            put_result = s3.put_object(
                Bucket=SNAPSHOT_BUCKET,
                Key=snapshot_key,
                Body=verified_stream,
                ContentType=content_type,
                CacheControl="no-store, max-age=0",
                Metadata={"sha256": expected_sha},
                ServerSideEncryption="AES256",
                ChecksumAlgorithm="SHA256",
            )
    finally:
        source["Body"].close()
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass

    version_id = put_result.get("VersionId")
    if not version_id:
        raise RequestError("snapshot_failed")
    snapshot_head = s3.head_object(
        Bucket=SNAPSHOT_BUCKET,
        Key=snapshot_key,
        VersionId=version_id,
        ChecksumMode="ENABLED",
    )

    now = int(time.time())
    expires_at = now + ttl
    item = {
        "targetClass": "s3-private-artifact",
        "bucket": SNAPSHOT_BUCKET,
        "key": snapshot_key,
        "versionId": version_id,
        "contentType": content_type,
        "contentLength": size,
        "sha256": expected_sha,
        "etag": str(snapshot_head.get("ETag", "")).strip('"'),
        "checksumSHA256": snapshot_head.get(
            "ChecksumSHA256",
            put_result.get("ChecksumSHA256", ""),
        ),
        "lastModified": snapshot_head["LastModified"].isoformat(),
        "createdAt": now,
        "expiresAt": expires_at,
        "createdBy": MANAGEMENT_PRINCIPAL_ARN,
        "channel": channel,
        "disabled": False,
    }
    if label:
        item["label"] = label

    for _ in range(8):
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        candidate = {"code": code, **item}
        try:
            table.put_item(
                Item=candidate,
                ConditionExpression="attribute_not_exists(code)",
            )
        except ClientError as exc:
            if (
                exc.response.get("Error", {}).get("Code")
                == "ConditionalCheckFailedException"
            ):
                continue
            raise
        _log(
            "link_created",
            codeRef=_code_ref(code),
            channel=channel,
            expiresAt=expires_at,
            contentLength=size,
        )
        return _response(
            201,
            {
                "code": code,
                "url": _short_url(code),
                "expiresAt": expires_at,
                "contentType": content_type,
                "contentLength": size,
                "sha256": candidate.get("sha256"),
                "revocable": True,
            },
        )
    raise RequestError("code_allocation_failed")


def _get_item(code: str) -> dict[str, Any] | None:
    result = table.get_item(Key={"code": code}, ConsistentRead=True)
    return result.get("Item")


def _resolve(code: str) -> dict[str, Any]:
    item = _get_item(code)
    now = int(time.time())
    code_ref = _code_ref(code)
    if not item:
        # Avoid logging random public probes; API/Lambda metrics still capture volume.
        return _error_response(404, "not_found")
    if item.get("disabled") or int(item.get("expiresAt", 0)) <= now:
        _log("link_gone", codeRef=code_ref, disabled=bool(item.get("disabled")))
        return _error_response(410, "gone")
    if (
        item.get("targetClass") != "s3-private-artifact"
        or item.get("bucket") != SNAPSHOT_BUCKET
        or not item.get("versionId")
    ):
        _log("link_invalid_target_class", codeRef=code_ref)
        return _error_response(410, "invalid_target")

    head_args: dict[str, Any] = {
        "Bucket": SNAPSHOT_BUCKET,
        "Key": item["key"],
        "VersionId": item["versionId"],
        "ChecksumMode": "ENABLED",
    }
    try:
        head = s3.head_object(**head_args)
    except ClientError as exc:
        status = exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if status in {403, 404}:
            _log("link_artifact_missing", codeRef=code_ref)
            return _error_response(410, "artifact_unavailable")
        raise

    actual = {
        "contentType": head.get("ContentType", "application/octet-stream"),
        "contentLength": int(head.get("ContentLength", 0)),
        "etag": str(head.get("ETag", "")).strip('"'),
        "checksumSHA256": head.get("ChecksumSHA256", ""),
        "lastModified": head["LastModified"].isoformat(),
        "sha256": (head.get("Metadata") or {}).get("sha256", ""),
        "versionId": head.get("VersionId", ""),
    }
    expected = {name: item.get(name, "") for name in actual}
    if any(str(actual[name]) != str(expected[name]) for name in actual):
        _log("link_artifact_fingerprint_changed", codeRef=code_ref)
        return _error_response(410, "artifact_changed")

    params: dict[str, Any] = {
        "Bucket": SNAPSHOT_BUCKET,
        "Key": item["key"],
        "VersionId": item["versionId"],
        "ResponseCacheControl": "no-store, max-age=0",
    }
    location = s3.generate_presigned_url(
        "get_object",
        Params=params,
        ExpiresIn=PRESIGN_SECONDS,
        HttpMethod="GET",
    )
    _log("link_resolved", codeRef=code_ref, expiresAt=int(item["expiresAt"]))
    return _response(
        302,
        "",
        {
            "content-type": "text/plain; charset=utf-8",
            "location": location,
        },
    )


def _status(code: str) -> dict[str, Any]:
    item = _get_item(code)
    if not item:
        return _error_response(404, "not_found")
    # Do not return bucket/key, versionId, etag, checksum, or createdBy.
    return _response(
        200,
        {
            "code": code,
            "targetClass": item.get("targetClass"),
            "createdAt": int(item.get("createdAt", 0)),
            "expiresAt": int(item.get("expiresAt", 0)),
            "disabled": bool(item.get("disabled")),
            "contentType": item.get("contentType"),
            "contentLength": int(item.get("contentLength", 0)),
            "sha256": item.get("sha256"),
            "channel": item.get("channel"),
            "label": item.get("label"),
        },
    )


def _revoke(code: str) -> dict[str, Any]:
    now = int(time.time())
    try:
        table.update_item(
            Key={"code": code},
            UpdateExpression="SET disabled = :true, revokedAt = :now",
            ConditionExpression="attribute_exists(code)",
            ExpressionAttributeValues={":true": True, ":now": now},
        )
    except ClientError as exc:
        if (
            exc.response.get("Error", {}).get("Code")
            == "ConditionalCheckFailedException"
        ):
            return _error_response(404, "not_found")
        raise
    _log("link_revoked", codeRef=_code_ref(code))
    return _response(200, {"code": code, "disabled": True, "revokedAt": now})


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    if not isinstance(event, dict):
        event = {}
    route = event.get("routeKey", "")
    operation = event.get("operation")
    request_class = _request_class(event)
    try:
        if operation is not None:
            if not isinstance(operation, str) or operation not in {
                "create",
                "status",
                "revoke",
            }:
                raise RequestError("invalid_operation")
            if set(event) - {"operation", "request", "code"}:
                raise RequestError("unsupported_field")
            if operation == "create":
                if "code" in event:
                    raise RequestError("invalid_request")
                request = event.get("request")
                if not isinstance(request, dict):
                    raise RequestError("invalid_request")
                return _create(request)
            if "request" in event:
                raise RequestError("invalid_request")
            code = event.get("code")
            if not isinstance(code, str) or not re.fullmatch(
                rf"[A-Za-z0-9]{{{CODE_LENGTH}}}",
                code,
            ):
                raise RequestError("invalid_code")
            return _status(code) if operation == "status" else _revoke(code)

        if route == "GET /{code}":
            code = (event.get("pathParameters") or {}).get("code", "")
            if not isinstance(code, str) or not re.fullmatch(
                rf"[A-Za-z0-9]{{{CODE_LENGTH}}}",
                code,
            ):
                return _error_response(404, "not_found")
            return _resolve(code)
        return _error_response(404, "route_not_found")
    except RequestError as exc:
        _log(
            "request_rejected",
            requestClass=request_class,
            errorCode=exc.code,
        )
        return _error_response(400, exc.code)
    except Exception:
        # Never emit exception text or a traceback: botocore exceptions can contain
        # object keys, request IDs, and request details. Lambda receives one fixed,
        # bounded failure string so its native Errors metric still increments.
        _log(
            "request_failed",
            requestClass=request_class,
            errorCode=INTERNAL_ERROR_CODE,
        )
        raise RuntimeError(INTERNAL_ERROR_CODE) from None
