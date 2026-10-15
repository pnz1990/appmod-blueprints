#!/bin/bash
# Optional (subscription.enabled in chart/values.yaml): the IAM role that the rust
# Subscription's ECR pull token is minted with. Kardinal makes no AWS calls; External
# Secrets' ECRAuthorizationToken generator assumes this role with the External Secrets
# controller's own identity (EKS Pod Identity role <prefix>-hub-external-secrets-role) and
# writes a dockerconfigjson Secret the Subscription reads. The role trusts only that role
# and may only read ECR. Idempotent; prints the role ARN for subscription.ecr.roleArn.
# Needs AWS credentials that may create IAM roles; RESOURCE_PREFIX defaults to peeks.
set -euo pipefail
PREFIX="${RESOURCE_PREFIX:-peeks}"
ROLE="${PREFIX}-hub-kardinal-ecr-reader"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ESO_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${PREFIX}-hub-external-secrets-role"
aws iam get-role --role-name "${PREFIX}-hub-external-secrets-role" >/dev/null
TRUST=$(jq -nc --arg p "$ESO_ROLE_ARN" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{AWS:$p},Action:["sts:AssumeRole","sts:TagSession"]}]}')
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" \
    --description "Kardinal Subscription ECR pull token (assumed by External Secrets)" --no-cli-pager >/dev/null
  echo "created role $ROLE" >&2
else
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST"
fi
aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam get-role --role-name "$ROLE" --query Role.Arn --output text
