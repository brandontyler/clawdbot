#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_NAME="openclaw-link-service"
BOOTSTRAP_STACK="openclaw-link-service-bootstrap"
REGION="us-east-1"
EXPECTED_ACCOUNT="035405309532"
ARTIFACT_BUCKET="kiro-sessions-035405309532"
ARTIFACT_PREFIX="artifacts/"

account="$(aws sts get-caller-identity --query Account --output text --region "$REGION")"
if [[ "$account" != "$EXPECTED_ACCOUNT" ]]; then
  echo "ERROR: expected AWS account $EXPECTED_ACCOUNT, got $account" >&2
  exit 1
fi

aws cloudformation validate-template --region "$REGION" --template-body "file://$ROOT/bootstrap.yaml" >/dev/null
aws cloudformation validate-template --region "$REGION" --template-body "file://$ROOT/template.yaml" >/dev/null

echo "Deploying versioned package bucket: $BOOTSTRAP_STACK"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$BOOTSTRAP_STACK" \
  --template-file "$ROOT/bootstrap.yaml" \
  --no-fail-on-empty-changeset \
  --tags Project=url-shortener Owner=brandon Channel=openclaw-ec2

DEPLOY_BUCKET="$(aws cloudformation describe-stacks \
  --region "$REGION" --stack-name "$BOOTSTRAP_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`DeploymentBucketName`].OutputValue | [0]' \
  --output text)"
if [[ -z "$DEPLOY_BUCKET" || "$DEPLOY_BUCKET" == "None" ]]; then
  echo "ERROR: bootstrap stack did not return a deployment bucket" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$ROOT/lambda/app.py" "$work/app.py"
# Normalize the ZIP entry timestamp so identical source produces identical bytes.
touch -t 198001010000 "$work/app.py"
(
  cd "$work"
  zip -q -X function.zip app.py
)
sha="$(sha256sum "$work/function.zip" | awk '{print $1}')"
code_key="deployments/openclaw-link-service/function-${sha}.zip"

echo "Uploading versioned Lambda package: s3://$DEPLOY_BUCKET/$code_key"
version_id="$(aws s3api put-object \
  --region "$REGION" \
  --bucket "$DEPLOY_BUCKET" \
  --key "$code_key" \
  --body "$work/function.zip" \
  --server-side-encryption AES256 \
  --cache-control no-store \
  --metadata "sha256=$sha" \
  --checksum-algorithm SHA256 \
  --query VersionId --output text)"
if [[ -z "$version_id" || "$version_id" == "None" || "$version_id" == "null" ]]; then
  echo "ERROR: versioned package upload did not return VersionId" >&2
  exit 1
fi

echo "Deploying stack: $STACK_NAME"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$ROOT/template.yaml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "CodeBucket=$DEPLOY_BUCKET" \
    "CodeKey=$code_key" \
    "CodeVersion=$version_id" \
    "ArtifactBucket=$ARTIFACT_BUCKET" \
    "ArtifactPrefix=$ARTIFACT_PREFIX" \
  --tags Project=url-shortener Owner=brandon Channel=openclaw-ec2

aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' \
  --output table

echo "Code package: s3://$DEPLOY_BUCKET/$code_key?versionId=$version_id"
echo "Destroy service: aws cloudformation delete-stack --region $REGION --stack-name $STACK_NAME"
echo "Bootstrap bucket is retained intentionally; empty all versions before deleting its stack."
