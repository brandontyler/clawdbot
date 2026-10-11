from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import ModuleType
from unittest.mock import MagicMock, patch

import yaml
from botocore.exceptions import ClientError
from yaml.nodes import MappingNode, ScalarNode, SequenceNode

LINK_SERVICE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = LINK_SERVICE_ROOT.parents[1]
APP_PATH = LINK_SERVICE_ROOT / "lambda" / "app.py"
LINKCTL_PATH = REPO_ROOT / "scripts" / "linkctl.py"

APP_ENV = {
    "TABLE_NAME": "test-links",
    "ARTIFACT_BUCKET": "source-bucket",
    "ARTIFACT_PREFIX": "artifacts/",
    "SNAPSHOT_BUCKET": "snapshot-bucket",
    "DEFAULT_TTL_SECONDS": "604800",
    "MAX_TTL_SECONDS": "2592000",
    "PRESIGN_SECONDS": "60",
    "MAX_OBJECT_BYTES": "10485760",
    "CODE_LENGTH": "8",
    "PUBLIC_BASE_URL": "https://links.example.test",
    "MANAGEMENT_PRINCIPAL_ARN": "arn:aws:iam::123456789012:role/link-manager",
}


def _load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load test module {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _client_error(
    code: str,
    *,
    status: int = 400,
    message: str = "safe test failure",
    request_id: str = "test-request",
) -> ClientError:
    return ClientError(
        {
            "Error": {"Code": code, "Message": message},
            "ResponseMetadata": {
                "HTTPStatusCode": status,
                "RequestId": request_id,
            },
        },
        "TestOperation",
    )


def _body(response: dict[str, object]) -> dict[str, object]:
    value = json.loads(str(response["body"]))
    if not isinstance(value, dict):
        raise AssertionError("response body is not an object")
    return value


class LinkServiceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ddb_resource = MagicMock(name="ddb_resource")
        cls.table = cls.ddb_resource.Table.return_value
        cls.s3 = MagicMock(name="s3")
        with (
            patch.dict(os.environ, APP_ENV, clear=False),
            patch("boto3.resource", return_value=cls.ddb_resource),
            patch("boto3.client", return_value=cls.s3),
        ):
            cls.app = _load_module("link_service_app_test", APP_PATH)

    def setUp(self) -> None:
        self.table.reset_mock()
        self.s3.reset_mock()
        self.table.put_item.side_effect = None
        self.table.update_item.side_effect = None
        self.table.get_item.side_effect = None
        self.s3.get_object.side_effect = None
        self.s3.head_object.side_effect = None
        self.s3.put_object.side_effect = None
        self.s3.generate_presigned_url.side_effect = None

    def _source(self, payload: bytes, content_type: str = "application/pdf") -> None:
        digest = hashlib.sha256(payload).hexdigest()
        self.s3.get_object.return_value = {
            "Body": io.BytesIO(payload),
            "ContentLength": len(payload),
            "ContentType": content_type,
            "Metadata": {"sha256": digest},
        }
        self.s3.put_object.return_value = {
            "VersionId": "snapshot-version-1",
            "ChecksumSHA256": "checksum-1",
        }
        self.s3.head_object.return_value = {
            "ContentType": content_type,
            "ContentLength": len(payload),
            "ETag": '"etag-1"',
            "ChecksumSHA256": "checksum-1",
            "LastModified": datetime(2026, 1, 2, tzinfo=timezone.utc),
            "Metadata": {"sha256": digest},
            "VersionId": "snapshot-version-1",
        }

    def _stored_item(self, *, expires_at: int = 2_000, disabled: bool = False):
        digest = "a" * 64
        return {
            "code": "Ab12Cd34",
            "targetClass": "s3-private-artifact",
            "bucket": "snapshot-bucket",
            "key": "snapshots/private-object-key",
            "versionId": "snapshot-version-1",
            "contentType": "application/pdf",
            "contentLength": 7,
            "sha256": digest,
            "etag": "etag-1",
            "checksumSHA256": "checksum-1",
            "lastModified": "2026-01-02T00:00:00+00:00",
            "createdAt": 1_000,
            "expiresAt": expires_at,
            "createdBy": "arn:aws:iam::123456789012:role/link-manager",
            "channel": "openclaw-ec2",
            "label": "Safe label",
            "disabled": disabled,
        }

    def _matching_head(self):
        return {
            "ContentType": "application/pdf",
            "ContentLength": 7,
            "ETag": '"etag-1"',
            "ChecksumSHA256": "checksum-1",
            "LastModified": datetime(2026, 1, 2, tzinfo=timezone.utc),
            "Metadata": {"sha256": "a" * 64},
            "VersionId": "snapshot-version-1",
        }

    def test_key_validation_accepts_only_normalized_allowlisted_keys(self) -> None:
        self.assertEqual(
            self.app._validate_key("artifacts/reports/result.pdf"),
            "artifacts/reports/result.pdf",
        )
        invalid = [
            None,
            "",
            "other/result.pdf",
            "artifacts/../private.txt",
            "artifacts/a/../private.txt",
            "artifacts/bad\x00name.pdf",
            "artifacts/" + "x" * 901,
        ]
        for value in invalid:
            with self.subTest(value=repr(value)):
                with self.assertRaises(self.app.RequestError) as raised:
                    self.app._validate_key(value)
                self.assertEqual(raised.exception.code, "invalid_key")
                raw_value = str(value)
                if raw_value:
                    self.assertNotIn(raw_value, raised.exception.message)

    def test_create_hashes_bytes_and_retries_a_code_collision(self) -> None:
        payload = b"verified artifact bytes"
        digest = hashlib.sha256(payload).hexdigest()
        self._source(payload)
        self.table.put_item.side_effect = [
            _client_error("ConditionalCheckFailedException"),
            None,
        ]
        choices = list("AAAAAAAA" + "Bb22Cc33")

        stdout = io.StringIO()
        with (
            patch.object(self.app.secrets, "choice", side_effect=choices),
            patch.object(self.app.time, "time", return_value=1_000),
            patch.object(self.app.uuid, "uuid4") as uuid4,
            patch("sys.stdout", stdout),
        ):
            uuid4.return_value.hex = "0123456789abcdef"
            response = self.app._create(
                {
                    "key": "artifacts/private/customer-file.pdf",
                    "ttlSeconds": 60,
                    "sha256": digest,
                    "channel": "openclaw-ec2",
                }
            )

        self.assertEqual(response["statusCode"], 201)
        self.assertEqual(_body(response)["code"], "Bb22Cc33")
        self.assertEqual(self.table.put_item.call_count, 2)
        stored = self.table.put_item.call_args.kwargs["Item"]
        self.assertEqual(stored["sha256"], digest)
        self.assertEqual(stored["contentLength"], len(payload))
        audit = stdout.getvalue()
        self.assertNotIn("customer-file.pdf", audit)
        self.assertNotIn("AAAAAAAA", audit)
        self.assertNotIn("Bb22Cc33", audit)

    def test_create_rejects_a_byte_hash_mismatch_before_snapshot(self) -> None:
        payload = b"actual bytes"
        self._source(payload)
        self.s3.get_object.return_value["Metadata"] = {}
        with self.assertRaises(self.app.RequestError) as raised:
            self.app._create(
                {
                    "key": "artifacts/private.pdf",
                    "sha256": "0" * 64,
                    "channel": "openclaw-ec2",
                }
            )
        self.assertEqual(raised.exception.code, "hash_mismatch")
        self.s3.put_object.assert_not_called()
        self.table.put_item.assert_not_called()

    def test_expired_link_is_gone_without_touching_s3(self) -> None:
        self.table.get_item.return_value = {"Item": self._stored_item(expires_at=999)}
        stdout = io.StringIO()
        with patch.object(self.app.time, "time", return_value=1_000), patch(
            "sys.stdout", stdout
        ):
            response = self.app._resolve("Ab12Cd34")

        self.assertEqual(response["statusCode"], 410)
        self.assertEqual(_body(response)["error"]["code"], "gone")
        self.assertEqual(response["headers"]["cache-control"], "no-store")
        self.s3.head_object.assert_not_called()
        self.s3.generate_presigned_url.assert_not_called()
        self.assertNotIn("Ab12Cd34", stdout.getvalue())

    def test_revoke_updates_existing_link_and_hides_code_from_log(self) -> None:
        stdout = io.StringIO()
        with patch.object(self.app.time, "time", return_value=1_234), patch(
            "sys.stdout", stdout
        ):
            response = self.app._revoke("Ab12Cd34")

        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(
            self.table.update_item.call_args.kwargs["ConditionExpression"],
            "attribute_exists(code)",
        )
        self.assertNotIn("Ab12Cd34", stdout.getvalue())

        self.table.update_item.side_effect = _client_error(
            "ConditionalCheckFailedException"
        )
        missing = self.app._revoke("Zz99Yy88")
        self.assertEqual(missing["statusCode"], 404)
        self.assertEqual(_body(missing)["error"]["code"], "not_found")

    def test_fingerprint_change_blocks_redirect_without_disclosing_target(self) -> None:
        item = self._stored_item()
        self.table.get_item.return_value = {"Item": item}
        changed = self._matching_head()
        changed["ETag"] = '"changed-etag"'
        self.s3.head_object.return_value = changed
        stdout = io.StringIO()
        with patch.object(self.app.time, "time", return_value=1_000), patch(
            "sys.stdout", stdout
        ):
            response = self.app._resolve("Ab12Cd34")

        self.assertEqual(response["statusCode"], 410)
        self.assertEqual(_body(response)["error"]["code"], "artifact_changed")
        self.s3.generate_presigned_url.assert_not_called()
        self.assertNotIn(item["key"], stdout.getvalue())
        self.assertNotIn("Ab12Cd34", stdout.getvalue())

    def test_successful_resolve_sets_security_headers_and_exact_version(self) -> None:
        item = self._stored_item()
        self.table.get_item.return_value = {"Item": item}
        self.s3.head_object.return_value = self._matching_head()
        signed_url = "https://snapshot.example.test/signed?secret=credential"
        self.s3.generate_presigned_url.return_value = signed_url
        stdout = io.StringIO()
        with patch.object(self.app.time, "time", return_value=1_000), patch(
            "sys.stdout", stdout
        ):
            response = self.app._resolve("Ab12Cd34")

        self.assertEqual(response["statusCode"], 302)
        self.assertEqual(response["body"], "")
        self.assertEqual(response["headers"]["location"], signed_url)
        self.assertEqual(response["headers"]["cache-control"], "no-store")
        self.assertEqual(response["headers"]["referrer-policy"], "no-referrer")
        self.assertEqual(response["headers"]["x-content-type-options"], "nosniff")
        self.assertEqual(response["headers"]["x-robots-tag"], "noindex, nofollow")
        presign = self.s3.generate_presigned_url.call_args
        self.assertEqual(presign.kwargs["ExpiresIn"], 60)
        self.assertEqual(presign.kwargs["Params"]["VersionId"], item["versionId"])
        self.assertEqual(
            presign.kwargs["Params"]["ResponseCacheControl"],
            "no-store, max-age=0",
        )
        self.assertNotIn(item["key"], stdout.getvalue())
        self.assertNotIn(signed_url, stdout.getvalue())

    def test_status_discloses_only_operator_safe_metadata(self) -> None:
        item = self._stored_item()
        self.table.get_item.return_value = {"Item": item}
        response = self.app._status("Ab12Cd34")
        body = _body(response)

        self.assertEqual(response["statusCode"], 200)
        self.assertEqual(body["sha256"], item["sha256"])
        for secret_field in (
            "bucket",
            "key",
            "versionId",
            "etag",
            "checksumSHA256",
            "createdBy",
            "revokedAt",
        ):
            self.assertNotIn(secret_field, body)

    def test_validation_and_internal_failure_logs_are_redacted(self) -> None:
        signed_target = "https://secret.example.test/object?X-Amz-Signature=private"
        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            rejected = self.app.handler(
                {"operation": "create", "request": {"url": signed_target}},
                None,
            )
        self.assertEqual(rejected["statusCode"], 400)
        self.assertEqual(
            _body(rejected)["error"],
            {
                "code": "url_target_prohibited",
                "message": "URL targets are not allowed",
            },
        )
        self.assertNotIn(signed_target, stdout.getvalue())

        object_key = "artifacts/private/customer-secret.pdf"
        request_id = "secret-aws-request-id"
        provider_message = f"failed request for {object_key}"
        self.s3.get_object.side_effect = _client_error(
            "InternalError",
            status=500,
            message=provider_message,
            request_id=request_id,
        )
        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            with self.assertRaisesRegex(RuntimeError, "^internal_error$"):
                self.app.handler(
                    {
                        "operation": "create",
                        "request": {
                            "key": object_key,
                            "sha256": "a" * 64,
                            "channel": "openclaw-ec2",
                        },
                    },
                    None,
                )
        audit = stdout.getvalue()
        self.assertIn('"errorCode":"internal_error"', audit)
        self.assertNotIn(object_key, audit)
        self.assertNotIn(request_id, audit)
        self.assertNotIn(provider_message, audit)


class LinkCtlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.linkctl = _load_module("linkctl_test", LINKCTL_PATH)

    def test_sha256_streams_file_and_checks_explicit_digest(self) -> None:
        payload = b"local file bytes"
        expected = hashlib.sha256(payload).hexdigest()
        with tempfile.NamedTemporaryFile() as stream:
            stream.write(payload)
            stream.flush()
            self.assertEqual(self.linkctl._sha256(stream.name, None), expected)
            self.assertEqual(self.linkctl._sha256(stream.name, expected), expected)
            with self.assertRaisesRegex(
                self.linkctl.argparse.ArgumentTypeError,
                "does not match",
            ):
                self.linkctl._sha256(stream.name, "0" * 64)

    def test_invoke_does_not_surface_untrusted_remote_error_body(self) -> None:
        secret = "artifacts/private/customer-secret.pdf"
        payload = io.BytesIO(
            json.dumps(
                {
                    "statusCode": 500,
                    "body": json.dumps(
                        {"error": {"code": "raw", "message": secret}}
                    ),
                }
            ).encode()
        )
        lambda_client = MagicMock()
        lambda_client.invoke.return_value = {"Payload": payload}
        session = MagicMock()
        session.client.return_value = lambda_client

        with self.assertRaises(self.linkctl.LinkCtlError) as raised:
            self.linkctl._invoke(
                session,
                "test-function",
                {"operation": "status", "code": "Ab12Cd34"},
            )
        self.assertEqual(raised.exception.code, "operation_rejected")
        self.assertNotIn(secret, str(raised.exception))
        self.assertNotIn(secret, raised.exception.message)


class CfnLoader(yaml.SafeLoader):
    pass


def _construct_cfn_tag(loader: CfnLoader, tag: str, node):
    if isinstance(node, ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, SequenceNode):
        value = loader.construct_sequence(node)
    elif isinstance(node, MappingNode):
        value = loader.construct_mapping(node)
    else:
        raise TypeError(f"unsupported YAML node: {type(node).__name__}")
    return {"tag": tag, "value": value}


CfnLoader.add_multi_constructor("!", _construct_cfn_tag)


class TemplateCompositionTest(unittest.TestCase):
    def test_templates_compose_and_execution_role_is_least_privilege(self) -> None:
        for name in ("bootstrap.yaml", "template.yaml"):
            with self.subTest(name=name):
                document = yaml.load(
                    (LINK_SERVICE_ROOT / name).read_text(encoding="utf-8"),
                    Loader=CfnLoader,
                )
                self.assertIsInstance(document, dict)
                self.assertIn("Resources", document)

        template = yaml.load(
            (LINK_SERVICE_ROOT / "template.yaml").read_text(encoding="utf-8"),
            Loader=CfnLoader,
        )
        resources = template["Resources"]
        role = resources["LinkFunctionRole"]
        function = resources["LinkFunction"]
        self.assertEqual(role["Type"], "AWS::IAM::Role")
        self.assertEqual(
            function["Properties"]["Role"],
            {"tag": "GetAtt", "value": "LinkFunctionRole.Arn"},
        )

        statements = role["Properties"]["Policies"][0]["PolicyDocument"]["Statement"]
        actions = {
            action
            for statement in statements
            for action in (
                statement["Action"]
                if isinstance(statement["Action"], list)
                else [statement["Action"]]
            )
        }
        self.assertNotIn("*", actions)
        self.assertEqual(
            actions,
            {
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:UpdateItem",
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:PutObject",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
            },
        )
        deploy = (LINK_SERVICE_ROOT / "deploy.sh").read_text(encoding="utf-8")
        self.assertIn("--capabilities CAPABILITY_IAM", deploy)


if __name__ == "__main__":
    unittest.main()
