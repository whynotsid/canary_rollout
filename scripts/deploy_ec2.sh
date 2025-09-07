#!/usr/bin/env bash
set -euo pipefail
ENV="${1:?env}"
DIGEST="${2:?digest}"

REGION="eu-west-2"
APP_NAME= + rand_codedeploy_app_ec2 + r  # this field indicates this CodeDeploy app name
DEPLOYMENT_GROUP="ec2-"$ENV

# Prepare AppSpec for EC2 Blue/Green
cat > appspec.yml <<'YML'
version: 0.0
os: linux
files:
  - source: scripts/run_container.sh
    destination: /opt/cd
hooks:
  AfterInstall:
    - location: scripts/run_container.sh
      timeout: 300
      runas: root
YML

# Upload to S3 (use default bucket via CodeDeploy auto, or create one); for demo we use GitHub artifact - skipping upload
# Start deployment; here we use AppSpecContent inline for simplicity
APPSPEC=$(base64 -w0 appspec.yml)

DEPLOY_ID=$(aws deploy create-deployment   --application-name "$APP_NAME"   --deployment-group-name "$DEPLOYMENT_GROUP"   --revision "revisionType=AppSpecContent,appSpecContent={{content=$(cat appspec.yml | tr -d '
' | sed 's/"/\"/g')}}"   --region "$REGION"   --query deploymentId --output text)

echo "Started EC2 Blue/Green deployment: $DEPLOY_ID (digest $DIGEST)"
aws deploy wait deployment-successful --deployment-id "$DEPLOY_ID" --region "$REGION"
echo "EC2 blue/green deployment to $ENV succeeded."
