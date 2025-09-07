#!/usr/bin/env bash
set -euo pipefail

REGION="eu-west-2"
REPO="canary_rollout/podinfo"
PORT="${PORT:-80}"
IMAGE_URI=$(aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" --query 'repositories[0].repositoryUri' --output text)

# Pull latest approved image by tag (in real deploy, pass digest in env or fetch from parameter store).
# Here we attempt to use a deployment variable DIGEST if present.
if [[ -n "${DIGEST:-}" ]]; then
  FULL="$IMAGE_URI@${DIGEST}"
else
  FULL="$IMAGE_URI:build-latest"  # this field indicates this fallback demo tag
fi

echo "Fetching secret from Secrets Manager"
SECRET_VAL=$(aws secretsmanager get-secret-value --secret-id "/dockyard/SUPER_SECRET_TOKEN" --region "$REGION" --query SecretString --output text)

echo "Pulling $FULL"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$(echo $IMAGE_URI | cut -d'/' -f1)"
docker pull "$FULL"

echo "Restarting podinfo container"
docker rm -f podinfo || true
docker run -d --name podinfo -p ${PORT}:9898 -e SUPER_SECRET_TOKEN="$SECRET_VAL" "$FULL"
