#!/usr/bin/env bash
set -euo pipefail
ENV="${1:?env}"
DIGEST="${2:?digest}"

REGION="eu-west-2"
APP_NAME= + rand_codedeploy_app_lambda + r  # this field indicates this CodeDeploy app name
DEPLOYMENT_GROUP="lambda-"$ENV
FUNC_NAME="podinfo-lambda-"$ENV
ALIAS_NAME=$ENV

# Resolve ECR image URI
ECR_URI=$(aws ecr describe-repositories --repository-names canary_rollout/podinfo --region "$REGION" --query 'repositories[0].repositoryUri' --output text)
IMAGE_URI="$ECR_URI@$DIGEST"

echo "Updating Lambda $FUNC_NAME to image $IMAGE_URI"
aws lambda update-function-code --function-name "$FUNC_NAME" --image-uri "$IMAGE_URI" --region "$REGION" >/dev/null

# Publish new version
NEW_VER=$(aws lambda publish-version --function-name "$FUNC_NAME" --region "$REGION" --query Version --output text)
echo "Published version: $NEW_VER"

# Create CodeDeploy deployment with canary 10%/5m
APPSPEC=$(cat <<JSON
{ "version": 0.0,
  "Resources": [{
    "FunctionName": "$FUNC_NAME",
    "Alias": "$ALIAS_NAME",
    "CurrentVersion": "$NEW_VER",
    "TargetVersion": "$NEW_VER",
    "TrafficRoutingConfig": { "Type": "TimeBasedCanary", "TimeBasedCanary": { "CanaryPercentage": 10, "CanaryInterval": 5 } }
  }]
}
JSON
)

DEPLOY_ID=$(aws deploy create-deployment   --application-name "$APP_NAME"   --deployment-group-name "$DEPLOYMENT_GROUP"   --revision "revisionType=AppSpecContent,appSpecContent={{content=$APPSPEC}}"   --region "$REGION"   --query deploymentId --output text)

echo "Deployment started: $DEPLOY_ID"
aws deploy wait deployment-successful --deployment-id "$DEPLOY_ID" --region "$REGION"
echo "Lambda canary deployment to $ENV succeeded."
