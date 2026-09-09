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

# ---------------------------------------------------------------------
# Role do GitHub Actions (OIDC) - o ARN dela e o secret
# AWS_ROLE_TO_ASSUME usado pelos workflows dos microsservicos.
# Desligada em Academy porque la nao se cria IAM role.
# ---------------------------------------------------------------------
module "github_oidc" {
  count  = var.enable_github_oidc && !var.is_academy ? 1 : 0
  source = "./modules/github-oidc"

  project_name         = var.project_name
  github_repository    = var.github_repository
  role_name            = var.github_oidc_role_name
  allowed_branches     = var.github_oidc_allowed_branches
  create_oidc_provider = var.create_github_oidc_provider

  # Permissao minima: push apenas nos repos ECR deste projeto.
  ecr_repository_arns = values(module.ecr.repository_arns)

  # Segunda role, para o workflow terraform.yml.
  create_terraform_role = var.create_terraform_role
  tfstate_bucket        = var.tfstate_bucket
  tfstate_lock_table    = var.tfstate_lock_table

  tags = local.common_tags
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

  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = var.endpoint_private_access
  public_access_cidrs     = var.public_access_cidrs

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  tags = local.common_tags
}

# Ligar o endpoint publico sem restringir o CIDR deixa a API do cluster
# exposta pra internet inteira - avisa em vez de deixar passar calado.
check "eks_endpoint_exposto" {
  assert {
    condition     = !(var.manage_eks_cluster && var.endpoint_public_access && contains(var.public_access_cidrs, "0.0.0.0/0"))
    error_message = "endpoint_public_access = true com public_access_cidrs = 0.0.0.0/0 expoe a API do EKS para a internet inteira. Restrinja ao seu IP: public_access_cidrs = [\"<SEU_IP>/32\"]."
  }
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

# =====================================================================
# CAMADA DE APLICACAO: secrets + IRSA
# ---------------------------------------------------------------------
# Tudo aqui depende do provider OIDC do cluster, que so existe em conta
# normal (is_academy = false). Em Academy o count zera e a stack continua
# valida - os servicos voltam a depender das chaves temporarias do Lab.
# =====================================================================

locals {
  app_stack_enabled = var.manage_eks_cluster && !var.is_academy && var.enable_app_platform

  secrets_prefix = "${var.project_name}/${var.environment}"

  # Guardas para nao referenciar module.eks[0] quando o cluster nao e
  # gerenciado aqui.
  oidc_provider_arn = local.app_stack_enabled ? module.eks[0].oidc_provider_arn : null
  oidc_issuer_url   = local.app_stack_enabled ? module.eks[0].oidc_issuer_url : null
}

module "app_secrets" {
  count  = local.app_stack_enabled ? 1 : 0
  source = "./modules/app-secrets"

  name_prefix   = local.secrets_prefix
  database_urls = module.rds.database_urls
  redis_url     = "redis://${module.elasticache.endpoint}:${module.elasticache.port}"
  tags          = local.common_tags
}

# ---------------------------------------------------------------------
# IRSA 1/5 - External Secrets Operator: le todos os secrets do projeto
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "eso" {
  count = local.app_stack_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = module.app_secrets[0].all_arns
  }
}

module "irsa_external_secrets" {
  count  = local.app_stack_enabled ? 1 : 0
  source = "./modules/irsa"

  role_name         = "${var.project_name}-external-secrets"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_issuer_url   = local.oidc_issuer_url
  namespace         = "external-secrets"
  service_account   = "external-secrets"
  policy_json       = data.aws_iam_policy_document.eso[0].json
  tags              = local.common_tags
}

# ---------------------------------------------------------------------
# IRSA 2/5 - Job de bootstrap: grava a SERVICE_API_KEY cunhada pelo auth
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "auth_bootstrap" {
  count = local.app_stack_enabled ? 1 : 0

  # Escopo minimo de proposito: o Job so escreve UM secret, e nem le os
  # outros. Se o pod for comprometido, o estrago para na API key.
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [module.app_secrets[0].service_api_key_arn]
  }
}

module "irsa_auth_bootstrap" {
  count  = local.app_stack_enabled ? 1 : 0
  source = "./modules/irsa"

  role_name         = "${var.project_name}-auth-bootstrap"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_issuer_url   = local.oidc_issuer_url
  namespace         = "auth-service"
  service_account   = "auth-bootstrap"
  policy_json       = data.aws_iam_policy_document.auth_bootstrap[0].json
  tags              = local.common_tags
}

# ---------------------------------------------------------------------
# IRSA 3/5 - analytics-service: consome da fila e grava no DynamoDB
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "analytics" {
  count = local.app_stack_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [module.sqs.queue_arn, module.sqs.dlq_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:GetItem",
    ]
    resources = [module.dynamodb.table_arn, "${module.dynamodb.table_arn}/index/*"]
  }
}

module "irsa_analytics" {
  count  = local.app_stack_enabled ? 1 : 0
  source = "./modules/irsa"

  role_name         = "${var.project_name}-analytics-service"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_issuer_url   = local.oidc_issuer_url
  namespace         = "analytics-service"
  service_account   = "analytics-service"
  policy_json       = data.aws_iam_policy_document.analytics[0].json
  tags              = local.common_tags
}

# ---------------------------------------------------------------------
# IRSA 4/5 - evaluation-service: so publica na fila
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "evaluation" {
  count = local.app_stack_enabled ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
    resources = [module.sqs.queue_arn]
  }
}

module "irsa_evaluation" {
  count  = local.app_stack_enabled ? 1 : 0
  source = "./modules/irsa"

  role_name         = "${var.project_name}-evaluation-service"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_issuer_url   = local.oidc_issuer_url
  namespace         = "evaluation-service"
  service_account   = "evaluation-service"
  policy_json       = data.aws_iam_policy_document.evaluation[0].json
  tags              = local.common_tags
}

# ---------------------------------------------------------------------
# IRSA 5/5 - KEDA: le a profundidade da fila para escalar o analytics
# ---------------------------------------------------------------------
# Substitui o `eksctl create iamserviceaccount` manual do
# kubernetes/keda/install.txt. Note que sqs:ListQueues NAO aceita
# permissao por recurso - por isso fica em statement separado com "*".
data "aws_iam_policy_document" "keda" {
  count = local.app_stack_enabled ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
    resources = [module.sqs.queue_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:ListQueues"]
    resources = ["*"]
  }
}

module "irsa_keda" {
  count  = local.app_stack_enabled ? 1 : 0
  source = "./modules/irsa"

  role_name         = "${var.project_name}-keda-operator"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_issuer_url   = local.oidc_issuer_url
  namespace         = "keda"
  service_account   = "keda-operator"
  policy_json       = data.aws_iam_policy_document.keda[0].json
  tags              = local.common_tags
}
