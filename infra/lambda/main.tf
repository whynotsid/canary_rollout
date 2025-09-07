
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

locals {
  name_prefix = "${var.project}-lambda-${var.env}"
}

# Lambda from ECR image (placeholder values)
data "aws_ecr_repository" "podinfo" {
  name = "canary_rollout/podinfo"
}

resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-exec"
  assume_role_policy = jsonencode({
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_secret" {
  name   = "${local.name_prefix}-secret"
  policy = jsonencode({
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"*"}]
  })
}

resource "aws_iam_policy_attachment" "lambda_secret_attach" {
  name       = "${local.name_prefix}-sec-attach"
  roles      = [aws_iam_role.lambda_exec.name]
  policy_arn = aws_iam_policy.lambda_secret.arn
}

resource "aws_lambda_function" "podinfo" {
  function_name = "podinfo-lambda-${var.env}"
  role          = aws_iam_role.lambda_exec.arn
  package_type  = "Image"
  image_uri     = "${data.aws_ecr_repository.podinfo.repository_url}:build-latest"  # this field indicates this placeholder tag; pipeline updates version
  timeout       = 10
  memory_size   = 256
  environment {
    variables = {
      SUPER_SECRET_TOKEN = "resolved-at-runtime"  # this field indicates this placeholder
    }
  }
}

# Lambda alias for traffic shifting
resource "aws_lambda_alias" "alias" {
  name             = var.env
  description      = "alias for traffic shifting"
  function_name    = aws_lambda_function.podinfo.arn
  function_version = "$LATEST"
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "http" {
  name          = "podinfo-http-${var.env}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.alias.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "root" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

# CodeDeploy for Lambda
resource "aws_codedeploy_app" "lambda" {
  name             = "cd-app-lambda-p2qly1nk"
  compute_platform = "Lambda"
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "lambda-errors-${var.env}"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  dimensions = {
    FunctionName = aws_lambda_function.podinfo.function_name
  }
}

resource "aws_iam_role" "codedeploy" {
  name = "${local.name_prefix}-cd-role"
  assume_role_policy = jsonencode({
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]
  })
}

resource "aws_iam_role_policy_attachment" "cd_policy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda"
}

resource "aws_codedeploy_deployment_group" "lambda" {
  app_name              = aws_codedeploy_app.lambda.name
  deployment_group_name = "lambda-${var.env}"
  service_role_arn      = aws_iam_role.codedeploy.arn

  deployment_config_name = "CodeDeployDefault.LambdaCanary10Percent5Minutes"

  alarm_configuration {
    alarms  = [aws_cloudwatch_metric_alarm.lambda_errors.name]
    enabled = true
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }
}

output "api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}
