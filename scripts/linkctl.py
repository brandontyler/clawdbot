#!/usr/bin/env python3
"""Operator CLI for the first-party OpenClaw private-artifact link service."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

DEFAULT_STACK = "openclaw-link-service"
DEFAULT_REGION = "us-east-1"
CODE_PATTERN = re.compile(r"^[A-Za-z0-9]{8}$")

CLI_ERROR_MESSAGES = {
    "aws_session_failed": "AWS session could not be initialized",
    "invalid_lambda_response": "Lambda returned an invalid response",
    "lambda_invoke_failed": "Lambda invocation failed",
    "missing_stack_output": "CloudFormation stack is missing a required output",
    "operation_rejected": "management operation was rejected",
    "stack_lookup_failed": "CloudFormation stack lookup failed",
}


class LinkCtlError(Exception):
    """A bounded operator-safe failure that contains no AWS response details."""

    def __init__(self, code: str):
        message = CLI_ERROR_MESSAGES.get(code)
        if message is None:
            raise RuntimeError("unknown_linkctl_error_code")
        super().__init__(code)
        self.code = code
        self.message = message


def _session(profile: str | None, region: str):
    try:
        return boto3.Session(profile_name=profile, region_name=region)
    except (BotoCoreError, ClientError, OSError, ValueError):
        raise LinkCtlError("aws_session_failed") from None


def _outputs(session, stack: str) -> dict[str, str]:
    try:
        response = session.client("cloudformation").describe_stacks(StackName=stack)
        outputs = response["Stacks"][0].get("Outputs", [])
        return {
            item["OutputKey"]: item["OutputValue"]
            for item in outputs
            if isinstance(item, dict)
            and isinstance(item.get("OutputKey"), str)
            and isinstance(item.get("OutputValue"), str)
        }
    except (BotoCoreError, ClientError, KeyError, IndexError, TypeError):
        raise LinkCtlError("stack_lookup_failed") from None


def _required_output(outputs: dict[str, str], name: str, _stack: str) -> str:
    value = outputs.get(name)
    if not value:
        raise LinkCtlError("missing_stack_output")
    return value


def _invoke(session, function_name: str, event: dict[str, Any]) -> dict[str, Any]:
    try:
        response = session.client("lambda").invoke(
            FunctionName=function_name,
            InvocationType="RequestResponse",
            Payload=json.dumps(event, separators=(",", ":")).encode(),
        )
    except (BotoCoreError, ClientError, OSError, TypeError, ValueError):
        raise LinkCtlError("lambda_invoke_failed") from None

    if response.get("FunctionError"):
        raise LinkCtlError("lambda_invoke_failed")

    try:
        raw = response["Payload"].read()
        envelope = json.loads(raw)
        status = int(envelope["statusCode"])
        body = json.loads(envelope.get("body") or "{}")
    except (
        AttributeError,
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ):
        raise LinkCtlError("invalid_lambda_response") from None
    if not isinstance(body, dict):
        raise LinkCtlError("invalid_lambda_response")
    if status >= 400:
        # The remote body is untrusted and may contain request details. The CLI
        # deliberately reports only this fixed local error code and message.
        raise LinkCtlError("operation_rejected")
    return body


def _ttl(value: str) -> int:
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    try:
        seconds = (
            int(value[:-1]) * units[value[-1].lower()]
            if value[-1:].lower() in units
            else int(value)
        )
    except (ValueError, KeyError) as exc:
        raise argparse.ArgumentTypeError(
            "TTL must be seconds or use s/m/h/d suffix"
        ) from exc
    if not 60 <= seconds <= 2_592_000:
        raise argparse.ArgumentTypeError("TTL must be between 60 seconds and 30 days")
    return seconds


def _code(value: str) -> str:
    if not CODE_PATTERN.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "code must be exactly 8 alphanumeric characters"
        )
    return value


def _sha256(path: str | None, explicit: str | None) -> str:
    if explicit and not re.fullmatch(r"[a-f0-9]{64}", explicit):
        raise argparse.ArgumentTypeError(
            "--sha256 must be 64 lowercase hexadecimal characters"
        )
    computed = None
    if path:
        digest = hashlib.sha256()
        try:
            with Path(path).open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
        except OSError:
            raise argparse.ArgumentTypeError("--file could not be read") from None
        computed = digest.hexdigest()
    if explicit and computed and explicit != computed:
        raise argparse.ArgumentTypeError("--sha256 does not match --file bytes")
    result = explicit or computed
    if not result:
        raise argparse.ArgumentTypeError("create requires --file or --sha256")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default=DEFAULT_REGION)
    parser.add_argument("--stack", default=DEFAULT_STACK)
    parser.add_argument("--profile")
    sub = parser.add_subparsers(dest="command", required=True)

    create = sub.add_parser("create", help="create a revocable private-artifact link")
    create.add_argument(
        "--key",
        required=True,
        help="allowlisted S3 object key (never a URL)",
    )
    create.add_argument(
        "--ttl",
        default="7d",
        type=_ttl,
        help="link lifetime: 60 seconds to 30 days; suffix s/m/h/d",
    )
    create.add_argument("--sha256")
    create.add_argument("--file", help="local artifact used only to calculate sha256")
    create.add_argument("--channel", default="openclaw-ec2")
    create.add_argument("--label")

    status = sub.add_parser("status", help="read link metadata")
    status.add_argument("code", type=_code)

    revoke = sub.add_parser("revoke", help="disable a link immediately")
    revoke.add_argument("code", type=_code)

    resolve = sub.add_parser(
        "resolve",
        help="print the public resolver URL without following it",
    )
    resolve.add_argument("code", type=_code)

    args = parser.parse_args()
    session = _session(args.profile, args.region)
    outputs = _outputs(session, args.stack)
    endpoint = _required_output(outputs, "ApiEndpoint", args.stack).rstrip("/")

    if args.command == "resolve":
        result = {"code": args.code, "url": f"{endpoint}/{args.code}"}
    else:
        function_name = _required_output(outputs, "LinkFunctionName", args.stack)
        if args.command == "create":
            request: dict[str, Any] = {
                "key": args.key,
                "ttlSeconds": args.ttl,
                "channel": args.channel,
                "sha256": _sha256(args.file, args.sha256),
            }
            if args.label:
                request["label"] = args.label
            event: dict[str, Any] = {"operation": "create", "request": request}
        else:
            event = {"operation": args.command, "code": args.code}
        result = _invoke(session, function_name, event)

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except argparse.ArgumentTypeError as exc:
        print(f"linkctl: invalid_argument: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except LinkCtlError as exc:
        print(f"linkctl: {exc.code}: {exc.message}", file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        # Never print raw boto3, filesystem, or response exceptions.
        print("linkctl: internal_error: operation failed", file=sys.stderr)
        raise SystemExit(1)
