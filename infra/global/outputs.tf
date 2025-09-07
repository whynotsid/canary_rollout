output "ecr_repository_url" {
  value = aws_ecr_repository.podinfo.repository_url
}
output "gha_oidc_role_arn" {
  value = aws_iam_role.gha_oidc.arn
}
output "secret_arn" {
  value = aws_secretsmanager_secret.super.arn
}
output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
