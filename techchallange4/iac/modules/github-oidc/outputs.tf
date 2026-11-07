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

output "terraform_role_arn" {
  description = "ARN para cadastrar no secret AWS_TERRAFORM_ROLE_ARN (null se create_terraform_role = false)"
  value       = var.create_terraform_role ? aws_iam_role.terraform[0].arn : null
}
