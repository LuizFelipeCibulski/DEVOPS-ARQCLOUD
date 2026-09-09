output "secret_arns" {
  description = "Mapa servico => ARN do secret (usado nas IAM policies do ESO)"
  value       = { for k, s in aws_secretsmanager_secret.app : k => s.arn }
}

output "secret_names" {
  description = "Mapa servico => nome/caminho do secret (usado no remoteRef.key do ExternalSecret)"
  value       = { for k, s in aws_secretsmanager_secret.app : k => s.name }
}

output "service_api_key_arn" {
  value = aws_secretsmanager_secret.service_api_key.arn
}

output "service_api_key_name" {
  value = aws_secretsmanager_secret.service_api_key.name
}

output "all_arns" {
  description = "Todos os ARNs, para a policy de leitura do External Secrets Operator"
  value       = concat([for s in aws_secretsmanager_secret.app : s.arn], [aws_secretsmanager_secret.service_api_key.arn])
}
