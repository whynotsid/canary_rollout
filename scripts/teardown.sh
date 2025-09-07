#!/usr/bin/env bash
set -euo pipefail

echo "Destroying EC2 stack..."
(cd infra/ec2 && terraform destroy -auto-approve || true)
echo "Destroying Lambda stack..."
(cd infra/lambda && terraform destroy -auto-approve || true)
echo "Destroying Global stack..."
(cd infra/global && terraform destroy -auto-approve || true)
echo "Note: If backend state was in S3, empty and delete bucket manually afterwards."
