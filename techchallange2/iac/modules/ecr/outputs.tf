output "repository_urls" {
  description = "Mapa nome-do-servico => URL do repositorio ECR (usar no campo image: do Deployment)"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  value = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
