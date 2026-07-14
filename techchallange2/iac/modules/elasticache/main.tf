resource "aws_security_group" "redis" {
  name        = "${var.project_name}-redis-sg"
  description = "Permite Redis (6379) apenas a partir dos nos do EKS"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-redis-sg"
  })
}

locals {
  allowed_sg_map = {
    for idx, sg_id in var.allowed_security_group_ids :
    tostring(idx) => sg_id
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_sg" {
  for_each                     = local.allowed_sg_map
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis a partir do SG ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "redis_cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = each.value
  from_port         = 6379
  to_port           = 6379
  ip_protocol       = "tcp"
  description       = "Redis a partir de ${each.value}"
}

# ---------------------------------------------------------------------
# Opcao 1 (default): ElastiCache Serverless for Redis
# ---------------------------------------------------------------------
resource "aws_elasticache_serverless_cache" "this" {
  count       = var.serverless ? 1 : 0
  engine      = "redis"
  name        = "${var.project_name}-cache"
  description = "Cache do evaluation-service (hot path de avaliacao de flags)"

  security_group_ids = [aws_security_group.redis.id]
  subnet_ids         = var.subnet_ids

  cache_usage_limits {
    data_storage {
      maximum = 5
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-cache"
  })
}

# ---------------------------------------------------------------------
# Opcao 2: cluster ElastiCache tradicional (node unico) - usado somente
# se var.serverless = false
# ---------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "this" {
  count      = var.serverless ? 0 : 1
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_cluster" "this" {
  count              = var.serverless ? 0 : 1
  cluster_id         = "${var.project_name}-cache"
  engine             = "redis"
  node_type          = var.node_type
  num_cache_nodes    = 1
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this[0].name
  security_group_ids = [aws_security_group.redis.id]

  tags = merge(var.tags, {
    Name = "${var.project_name}-cache"
  })
}
