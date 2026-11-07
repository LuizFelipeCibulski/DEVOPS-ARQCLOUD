output "endpoint" {
  description = "Host do Redis para montar REDIS_URL"
  value = var.serverless ? (
    length(aws_elasticache_serverless_cache.this) > 0 ? aws_elasticache_serverless_cache.this[0].endpoint[0].address : null
    ) : (
    length(aws_elasticache_cluster.this) > 0 ? aws_elasticache_cluster.this[0].cache_nodes[0].address : null
  )
}

output "port" {
  value = var.serverless ? (
    length(aws_elasticache_serverless_cache.this) > 0 ? aws_elasticache_serverless_cache.this[0].endpoint[0].port : null
    ) : (
    length(aws_elasticache_cluster.this) > 0 ? aws_elasticache_cluster.this[0].cache_nodes[0].port : null
  )
}

output "security_group_id" {
  value = aws_security_group.redis.id
}

output "url_scheme" {
  description = <<-EOT
    "rediss" (com TLS) ou "redis". O ElastiCache Serverless SEMPRE exige
    criptografia em transito - nao e opcional nem desligavel. Conectar
    nele com redis:// nao da erro claro: o TCP conecta, o servidor espera
    o handshake TLS que nunca vem, e o cliente morre com
    "read tcp ...: i/o timeout". Foi exatamente o sintoma do
    evaluation-service em CrashLoopBackOff.

    O aws_elasticache_cluster (serverless = false) sobe sem TLS, entao
    ali o esquema continua redis://.
  EOT
  value       = var.serverless ? "rediss" : "redis"
}
