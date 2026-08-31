# ---------------------------------------------------------------------
# "Checklist de infraestrutura" pedido no PDF: strings de conexao para
# colar (em base64) nos Secrets/ConfigMaps de kubernetes/*.
# ---------------------------------------------------------------------

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "ecr_repository_urls" {
  description = "URL de cada repo ECR - usar no campo image: dos Deployments"
  value       = module.ecr.repository_urls
}

output "eks_cluster_name" {
  value = var.manage_eks_cluster ? module.eks[0].cluster_name : null
}

output "eks_kubeconfig_command" {
  description = "Rode isso depois do apply para configurar o kubectl"
  value       = var.manage_eks_cluster ? "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks[0].cluster_name}" : "Cluster gerenciado manualmente (manage_eks_cluster = false) - crie via Console e depois rode o update-kubeconfig apontando pro nome escolhido."
}

output "rds_endpoints" {
  description = "host:porta de cada instancia RDS"
  value       = { for k, db in module.rds.instances : k => db.endpoint }
}

output "rds_database_urls" {
  description = "DATABASE_URL pronta (postgres://user:senha@host:porta/db) - fazer echo -n '<valor>' | base64 e colar no secret.yaml correspondente"
  value       = module.rds.database_urls
  sensitive   = true
}

output "redis_endpoint" {
  value = "${module.elasticache.endpoint}:${module.elasticache.port}"
}

output "redis_url" {
  description = "REDIS_URL pronta para o evaluation-service"
  value       = "redis://${module.elasticache.endpoint}:${module.elasticache.port}"
}

output "dynamodb_table_name" {
  value = module.dynamodb.table_name
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "sqs_queue_arn" {
  value = module.sqs.queue_arn
}

output "sqs_dlq_url" {
  value = module.sqs.dlq_url
}
