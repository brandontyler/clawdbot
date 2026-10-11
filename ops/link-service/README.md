# OpenClaw first-party link service

A small corp-account service that creates revocable clean links for private S3 artifacts without storing presigned credentials.

## Security model

- Management (`create`, `status`, `revoke`) uses direct synchronous Lambda invocation by the existing `openclaw-server-role`. A function resource policy grants that role invocation; it is **not** the Lambda execution role.
- CloudFormation creates a dedicated Lambda execution role. Its inline policy is limited to `GetItem`/`PutItem`/`UpdateItem` on this stack's table, `GetObject` under the configured source bucket/prefix, object reads/writes in this stack's snapshot bucket, and stream writes in this function's log group. The role trusts only `lambda.amazonaws.com` and has no wildcard actions.
- The stack no longer passes `openclaw-server-role` to Lambda. It therefore does not require that role to trust Lambda or require `iam:PassRole` on that existing role. As with any IAM-bearing CloudFormation stack, the deployment identity must be allowed to create/manage/pass the stack-owned execution role; `deploy.sh` acknowledges this with `CAPABILITY_IAM`.
- API Gateway exposes only public `GET /{code}`, which accepts an 8-character generated code. There are no public or IAM-authenticated management routes.
- Creation accepts an S3 **object key**, never a URL. The Lambda hard-rejects `url`, `target`, `location`, and presigned-url fields.
- The source bucket and prefix are fixed by environment (`kiro-sessions-035405309532/artifacts/`). Creation downloads and verifies the requested bytes, then writes them to a private service-owned versioned snapshot bucket. Arbitrary internet redirects and internal URLs are impossible by construction.
- The table stores the immutable snapshot bucket/key/VersionId, verified SHA-256, AWS checksum/fingerprint, TTL, owner/channel, and disabled state—never a signed URL.
- Each click rechecks and presigns the exact snapshot VersionId; changing or deleting the original source key cannot retarget an existing link.
- Each valid click mints a fresh **60-second** S3 GET URL with `ResponseCacheControl=no-store,max-age=0`, then returns `302` with `Cache-Control: no-store` and `Referrer-Policy: no-referrer`.
- DynamoDB TTL cleans old items; application logic enforces expiry immediately because TTL deletion is asynchronous.
- Revocation sets `disabled=true` and immediately blocks future clean-link resolutions. New requests to an already-issued S3 URL are rejected after its 60-second expiry, but AWS documents that a download started before expiry can continue after that time; this design cannot terminate an in-flight transfer.
- Caller-visible failures use a fixed, bounded error-code/message catalog. Audit logs use fixed event schemas and contain only event class, a one-way code digest, bounded channel, expiry/size, and fixed error classification—never raw exceptions, object keys, link codes, request bodies, source IPs, credentials, AWS request IDs, or signed targets.
- Unexpected provider/runtime failures are rethrown as the fixed `internal_error` exception so Lambda's native `Errors` metric still increments without logging the caught exception text.
- Lambda invocation/error alarms enter `ALARM` state for loops and failures; they are passive console/metric signals until an SNS notification action is separately approved. API throttling, reserved concurrency, a 10 MiB artifact cap, and the 60-second window bound fresh credential issuance and replay impact.
- A 60-second S3 URL is still reusable during its brief lifetime, so unusually sensitive or expensive artifacts require a revocation-aware proxy/CDN data path rather than this redirect design.

## Architecture

```text
openclaw-server-role --direct invoke (resource policy)--------> Lambda
                                                               ^ dedicated stack-owned execution role
                                                               |--> DynamoDB link table
source S3 artifact --verify SHA-256--> versioned snapshot S3   |
human --GET /code--> API Gateway (public resolver only)--------|--> exact snapshot VersionId presign (60s)
```

## Deploy

The deployer refuses any account except `035405309532`, updates a private encrypted versioned package bucket, builds a deterministic ZIP, uploads it with an AWS checksum, captures its VersionId, validates both templates, and deploys the service stack with `Code.S3ObjectVersion` pinned to that exact package:

```bash
./ops/link-service/deploy.sh
```

The main stack contains IAM resources and is deployed with `CAPABILITY_IAM`. It creates the dedicated execution role described above. `CallerRoleName` identifies only the same-account role granted direct management invocation and recorded as `createdBy`; CloudFormation never edits that caller role.

The deployment identity needs the ordinary CloudFormation/S3/Lambda/API Gateway/DynamoDB/Logs/CloudWatch permissions plus permission to create, update, delete, and pass the stack-owned role. No pre-existing Lambda trust relationship or `iam:PassRole` grant on `openclaw-server-role` is required.

No custom domain is created because the corp account currently has no Route 53 hosted zone. The initial public hostname is the AWS-owned `execute-api` endpoint. Add ACM/Route 53 only after Brandon chooses a domain.

## Operate

```bash
# Create from an allowlisted private artifact; local file supplies integrity hash.
python3 scripts/linkctl.py create \
  --key artifacts/archify/ec2-openclaw-hermes-2026-08-29.html \
  --file artifacts/archify/ec2-openclaw-hermes.html \
  --ttl 7d --label "EC2 agent architecture"

python3 scripts/linkctl.py resolve CODE
python3 scripts/linkctl.py status CODE
python3 scripts/linkctl.py revoke CODE
```

The CLI uses the current AWS credential chain to call Lambda Invoke directly for management. Only `resolve` uses the public API endpoint to construct a clean URL. The CLI has no command accepting an arbitrary URL. It does not print raw AWS exceptions or untrusted Lambda error bodies.

## Offline validation

These checks do not make AWS calls or deploy resources:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s ops/link-service/tests -p 'test_*.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile ops/link-service/lambda/app.py scripts/linkctl.py ops/link-service/tests/test_link_service.py
bash -n ops/link-service/deploy.sh
```

The unit suite mocks all boto3 resources/clients. It covers key and request validation, local and service-side hashing, code collisions, application expiry, revocation, immutable fingerprint checks, redirect/error headers, status disclosure, raw-provider-error redaction, CLI response redaction, YAML composition, and the execution-role action set.

CloudFormation's remote `validate-template` remains part of `deploy.sh`, but it is intentionally not run during offline validation because it is an AWS API call.

## Verify after an approved deployment

For a newly created link:

1. `curl -sS -D headers -o /dev/null SHORT_URL` → `302`, one fresh S3 `Location`, `no-store`.
2. Follow once and verify `200`, content type/length/hash.
3. Revoke; `GET SHORT_URL` must return `410` without issuing another S3 redirect.
4. Treat any S3 URL captured before revocation as accepting new requests for up to 60 seconds; a download already started can continue afterward.
5. Create a replacement link for handoff.

## Cost

At roughly 100 creates + 1,000 clicks/month:

- API Gateway HTTP API (public clicks only): about `1,000 × $1.00 / 1,000,000 = $0.001` before free tier.
- DynamoDB on-demand: about `100 × $1.25 / 1,000,000 + 1,000 × $0.25 / 1,000,000 = $0.000375` before free tier.
- Lambda 128 MB / short invocations: normally inside free tier; otherwise far below one cent.
- CloudWatch Logs: tiny at this volume with 14-day retention. Alarms are passive until a separately approved notification action is configured.
- Snapshot storage at the hard maximum: `100 × 10 MiB ≈ 0.98 GB × $0.023/GB-month ≈ $0.023/month`; typical sub-MiB artifacts are proportionally lower and expire after 35 days.
- S3 requests: roughly `100 PUT × $0.005/1,000 + 2,100 GET-class × $0.0004/1,000 ≈ $0.00134/month`.
- Maximum-size download egress is `1,000 × 10 MiB ≈ 9.8 GB/month`; this is usually inside AWS's account-level 100 GB internet-transfer allowance, but usage beyond the shared allowance is billed at the regional transfer rate.

Expected service/request cost is below $0.01/month for typical sub-MiB artifacts while transfer remains inside the shared allowance. The deliberate 10 MiB maximum-load scenario adds about $0.023/month of snapshot storage, plus any egress beyond the account allowance. Custom domains and Route 53 are excluded.

## Rollback and destroy

A normal rollback is a CloudFormation **update** to the prior `CodeKey` + `CodeVersion`, preserving the API, table, revocations, and audit records. The bootstrap bucket retains versioned packages for 30 days, so redeploying a prior version is deterministic.

Full destroy is intentionally destructive:

```bash
aws cloudformation delete-stack --region us-east-1 --stack-name openclaw-link-service
aws cloudformation wait stack-delete-complete --region us-east-1 --stack-name openclaw-link-service
```

Destroying the service stack removes the API, function, dedicated execution role, alarms, logs, and link table, including revocation/audit state. It does not delete source artifacts or modify `openclaw-server-role`. Both the immutable snapshot bucket and deployment bootstrap bucket have `DeletionPolicy: Retain`; empty all object versions explicitly before deleting retained buckets or the bootstrap stack. A stack in `ROLLBACK_COMPLETE` must be deleted before redeployment; verify any retained snapshot bucket is empty before deleting it.

## Explicit WIP limitations

- This source has only offline mocked validation in the current change; no AWS calls, deployment, or live resolver round trip were performed.
- There is no custom domain, WAF, SNS alarm delivery, or revocation-aware content proxy. The execute-api hostname, passive alarms, throttling, and 60-second replay window are intentional initial limits.
- Source artifacts encrypted with a customer-managed KMS key are unsupported unless a future change adds a key-specific `kms:Decrypt` grant; the execution role intentionally has no broad KMS permission.
- Collision exhaustion can leave an unreachable snapshot object until the 35-day bucket lifecycle removes it. Normal collisions retry eight times; automatic orphan deletion is not yet implemented because it would expand runtime delete permission.
- Retained snapshot/deployment buckets require explicit version-aware cleanup after stack deletion.
