resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.project_name}-db-subnet-group"
  })
}

# Um unico SG compartilhado pelas 3 instancias: só libera 5432 para quem
# está no SG dos nos do EKS (nunca 0.0.0.0/0).
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite Postgres (5432) apenas a partir dos nos do EKS"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.project_name}-rds-sg"
  })
}

locals {
  allowed_sg_map = {
    for idx, sg_id in var.allowed_security_group_ids :
    tostring(idx) => sg_id
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres_sg" {
  for_each                     = local.allowed_sg_map
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres a partir do SG ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "postgres_cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.rds.id
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  description       = "Postgres a partir de ${each.value}"
}

resource "random_password" "master" {
  for_each = var.databases
  length   = 24
  special  = false # evita caracteres que quebrariam a DATABASE_URL (ex: '/', '@', ':')
}

resource "aws_db_instance" "this" {
  for_each = var.databases

  identifier     = each.key
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 3
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = each.value.db_name
  username = each.value.username
  password = random_password.master[each.key].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot
  apply_immediately       = true

  tags = merge(var.tags, {
    Name    = each.key
    Service = each.key
  })
}
