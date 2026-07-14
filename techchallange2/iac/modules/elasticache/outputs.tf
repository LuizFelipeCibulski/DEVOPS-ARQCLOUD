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
