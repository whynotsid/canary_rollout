#!/usr/bin/env bash
set -euo pipefail
ENV="${1:?env}"
REGION="eu-west-2"

if [[ "$ENV" == "dev" ]]; then
  api_id=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='podinfo-http-dev'].ApiId" --output text)
  api_url="https://${api_id}.execute-api.${REGION}.amazonaws.com/"
  alb_dns=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?contains(LoadBalancerName, 'podinfo-dev')].DNSName" --output text)
else
  api_id=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='podinfo-http-prod'].ApiId" --output text)
  api_url="https://${api_id}.execute-api.${REGION}.amazonaws.com/"
  alb_dns=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?contains(LoadBalancerName, 'podinfo-prod')].DNSName" --output text)
fi

echo "Smoke: API GW -> $api_url/healthz"
curl -sf "$api_url/healthz" >/dev/null

echo "Smoke: ALB -> http://$alb_dns/healthz"
curl -sf "http://$alb_dns/healthz" >/dev/null

echo "Smoke tests OK for $ENV"
