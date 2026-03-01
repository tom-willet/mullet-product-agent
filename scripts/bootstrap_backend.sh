#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-mullet-dev}"
AWS_REGION="${AWS_REGION:-us-west-2}"
STACK_DIR="terraform/bootstrap"

ACCOUNT_ID="$(aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" sts get-caller-identity --query Account --output text)"
STATE_BUCKET="mullet-product-agent-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
LOCK_TABLE="mullet-product-agent-tf-locks"

terraform -chdir="${STACK_DIR}" init
terraform -chdir="${STACK_DIR}" apply \
  -var="aws_profile=${AWS_PROFILE}" \
  -var="aws_region=${AWS_REGION}" \
  -var="state_bucket_name=${STATE_BUCKET}" \
  -var="lock_table_name=${LOCK_TABLE}"

cat <<OUT

Backend resources applied.
Use these values in terraform/envs/prod/backend.hcl:
  bucket         = ${STATE_BUCKET}
  dynamodb_table = ${LOCK_TABLE}
  region         = ${AWS_REGION}
OUT
