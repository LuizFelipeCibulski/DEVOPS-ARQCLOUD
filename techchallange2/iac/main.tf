locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  cluster_name = "${var.project_name}-${var.environment}"
}

# A LabRole ja existe no Academy - so fazemos um lookup, nunca criamos IAM
# role nenhuma nesse modo (regra dura do desafio).
data "aws_iam_role" "lab_role" {
  count = var.is_academy ? 1 : 0
  name  = var.lab_role_name
}

module "vpc" {
  source = "./modules/vpc"

  project_name             = var.project_name
  vpc_cidr                 = var.vpc_cidr
  azs                      = var.azs
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs
  single_nat_gateway       = var.single_nat_gateway
  cluster_name             = local.cluster_name
  tags                     = local.common_tags
}

module "ecr" {
  source = "./modules/ecr"

  repository_names = var.microservices
  tags             = local.common_tags
}

module "eks" {
  count  = var.manage_eks_cluster ? 1 : 0
  source = "./modules/eks"

  cluster_name             = local.cluster_name
  cluster_version          = var.cluster_version
  vpc_id                   = module.vpc.vpc_id
  control_plane_subnet_ids = concat(module.vpc.public_subnet_ids, module.vpc.private_app_subnet_ids)
  node_subnet_ids          = module.vpc.private_app_subnet_ids

  is_academy        = var.is_academy
  existing_role_arn = var.is_academy ? data.aws_iam_role.lab_role[0].arn : null
  enable_irsa       = !var.is_academy

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  tags = local.common_tags
}

locals {
  # Sem cluster gerenciado pelo Terraform nao existe um SG de cluster pra
  # referenciar; nesse caso liberamos RDS/ElastiCache para toda a faixa
  # das subnets private-app (onde os nos vao subir de qualquer forma).
  app_tier_security_group_ids = var.manage_eks_cluster ? [module.eks[0].cluster_security_group_id] : []
  app_tier_cidr_blocks        = var.manage_eks_cluster ? [] : var.private_app_subnet_cidrs
}

module "rds" {
  source = "./modules/rds"

  project_name               = var.project_name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_db_subnet_ids
  allowed_security_group_ids = local.app_tier_security_group_ids
  allowed_cidr_blocks        = local.app_tier_cidr_blocks
  databases                  = var.rds_databases
  instance_class             = var.rds_instance_class
  engine_version             = var.rds_engine_version
  tags                       = local.common_tags
}

module "elasticache" {
  source = "./modules/elasticache"

  project_name               = var.project_name
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_db_subnet_ids
  allowed_security_group_ids = local.app_tier_security_group_ids
  allowed_cidr_blocks        = local.app_tier_cidr_blocks
  serverless                 = var.redis_serverless
  tags                       = local.common_tags
}

module "dynamodb" {
  source = "./modules/dynamodb"

  table_name = var.dynamodb_table_name
  tags       = local.common_tags
}

module "sqs" {
  source = "./modules/sqs"

  queue_name = var.sqs_queue_name
  tags       = local.common_tags
}
