output "role_arn" {
  description = "ARN para cadastrar no secret AWS_ROLE_TO_ASSUME do repositorio"
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  value = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "ARN do provider OIDC do GitHub (criado aqui ou apenas referenciado)"
  value       = local.oidc_provider_arn
}
