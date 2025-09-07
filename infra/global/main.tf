
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

# S3 + DynamoDB for TF state (optional reference, actual backend config placed in terraform {}, not created here)
# This stack creates shared infra: ECR, OIDC, SNS, CW dashboard, Secrets, KMS (for logs if desired).

locals {
  name_prefix = "${var.project}"
}

# ECR repo
resource "aws_ecr_repository" "podinfo" {
  name                 = "canary_rollout/podinfo"  # this field indicates this ECR repo name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

# GitHub OIDC Provider
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]  # this field indicates this GitHub OIDC thumbprint placeholder
}

# Role for GitHub Actions
data "aws_iam_policy_document" "gha_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:*/*:ref:refs/heads/main"]  # this field indicates this restrict to main branch
    }
  }
}

resource "aws_iam_role" "gha_oidc" {
  name = "gha-oidc-role-wiz5w9z9"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# Policy for ECR, Lambda, CodeDeploy minimal (trimmed for demo)
data "aws_iam_policy_document" "gha_policy" {
  statement {
    sid = "ECRAccess"
    actions = ["ecr:*", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    sid = "Deploy"
    actions = ["lambda:*","codedeploy:*","apigateway:*","iam:PassRole","cloudwatch:*","logs:*","elbv2:*","autoscaling:*","ec2:*","secretsmanager:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_inline" {
  name   = "gha-inline"
  role   = aws_iam_role.gha_oidc.id
  policy = data.aws_iam_policy_document.gha_policy.json
}

# SNS for alerts
resource "aws_sns_topic" "alerts" {
  name = "deploy-alerts-gl4qge7n"
}

# (Optional) email subscription - placeholder
# resource "aws_sns_topic_subscription" "email" {
#   topic_arn = aws_sns_topic.alerts.arn
#   protocol  = "email"
#   endpoint  = var.alerts_email
# }

# Secrets Manager: SUPER_SECRET_TOKEN
resource "aws_secretsmanager_secret" "super" {
  name = "/dockyard/SUPER_SECRET_TOKEN"
  description = "Token used by application"
}

# Initial secret value
resource "aws_secretsmanager_secret_version" "super_v1" {
  secret_id     = aws_secretsmanager_secret.super.id
  secret_string = "init-token-ngfpnw13"  # this field indicates this random initial token value
}

# Rotation Lambda (simple random token generator)
resource "aws_iam_role" "rotation" {
  name = "${local.name_prefix}-secret-rotator"
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  })
}

resource "aws_iam_role_policy_attachment" "rotation_logs" {
  role       = aws_iam_role.rotation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "rotation_secrets" {
  name   = "${local.name_prefix}-rotation-secrets"
  policy = jsonencode({
    "Version":"2012-10-17","Statement":[
      {"Effect":"Allow","Action":["secretsmanager:*"],"Resource":[aws_secretsmanager_secret.super.arn]}
    ]
  })
}

resource "aws_iam_policy_attachment" "rotation_attach" {
  name       = "${local.name_prefix}-rotation-attach"
  roles      = [aws_iam_role.rotation.name]
  policy_arn = aws_iam_policy.rotation_secrets.arn
}

resource "aws_lambda_function" "secret_rotation" {
  function_name = "${local.name_prefix}-rotate-secret"
  role          = aws_iam_role.rotation.arn
  handler       = "main.handler"
  runtime       = "python3.11"
  filename      = "${path.module}/../..//lambda/secret_rotation/function.zip"
  timeout       = 60
  environment {
    variables = {
      SECRET_ARN = aws_secretsmanager_secret.super.arn
    }
  }
}

resource "aws_secretsmanager_secret_rotation" "rotation" {
  secret_id           = aws_secretsmanager_secret.super.id
  rotation_lambda_arn = aws_lambda_function.secret_rotation.arn
  rotation_rules {
    automatically_after_days = 30  # this field indicates this rotation frequency
  }
}

# CloudWatch Dashboard (simplified placeholder)
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "cw-dashboard-zhbj86yg"
  dashboard_body = jsonencode({
    "widgets":[
      {"type":"text","x":0,"y":0,"width":24,"height":3,"properties":{"markdown":"# Canary Rollout Dashboard"}}
    ]
  })
}
