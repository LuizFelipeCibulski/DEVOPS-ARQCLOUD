variable "project_name" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
  default     = "togglemaster"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# ---------------------------------------------------------------------
# Modo de conta - a mesma base de codigo atende os dois cenarios do
# desafio (Opcao A: AWS Academy / Opcao B: conta normal).
# ---------------------------------------------------------------------

variable "is_academy" {
  description = <<-EOT
    true  = AWS Academy: reaproveita a LabRole existente, NAO cria nenhuma
            IAM role nova, e desliga IRSA (Academy nao permite as roles
            que o IRSA exige).
    false = conta normal: o Terraform cria as IAM roles dedicadas do EKS
            e habilita o provider OIDC para IRSA.
  EOT
  type        = bool
  default     = false
}

variable "lab_role_name" {
  description = "Nome da role padrao do AWS Academy (usada apenas quando is_academy = true)"
  type        = string
  default     = "LabRole"
}

variable "manage_eks_cluster" {
  description = <<-EOT
    true  = o Terraform cria o cluster EKS + node group (equivalente em
            efeito ao Console: reaproveita a LabRole, nao cria IAM role
            nenhuma quando is_academy = true).
    false = o Terraform prepara so a VPC/subnets (com as tags
            kubernetes.io/* corretas) e voce cria o cluster manualmente
            pelo Console, seguindo a instrucao literal do PDF pra Opcao A.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------
# Rede
# ---------------------------------------------------------------------

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "single_nat_gateway" {
  description = "true = 1 NAT Gateway (mais barato, recomendado p/ Academy); false = 1 por AZ (mais resiliente)"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------

variable "cluster_version" {
  type    = string
  default = "1.36"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 4
}

# ---------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------

variable "microservices" {
  description = "Nomes dos 5 microsservicos - 1 repositorio ECR por servico"
  type        = list(string)
  default = [
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ]
}

# ---------------------------------------------------------------------
# RDS - 3 instancias independentes (auth, flag, targeting)
# ---------------------------------------------------------------------

variable "rds_databases" {
  type = map(object({
    db_name  = string
    username = string
  }))
  default = {
    "auth-service" = {
      db_name  = "auth_db"
      username = "auth_admin"
    }
    "flag-service" = {
      db_name  = "flag_db"
      username = "flag_admin"
    }
    "targeting-service" = {
      db_name  = "targeting_db"
      username = "targeting_admin"
    }
  }
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "rds_engine_version" {
  type    = string
  default = "18.4"
}

# ---------------------------------------------------------------------
# ElastiCache
# ---------------------------------------------------------------------

variable "redis_serverless" {
  description = "true = ElastiCache Serverless for Redis; false = cluster provisionado (cache.t3.micro)"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------

variable "dynamodb_table_name" {
  description = "Precisa bater com o valor injetado em AWS_DYNAMODB_TABLE no analytics-service"
  type        = string
  default     = "ToggleMasterAnalytics"
}

# ---------------------------------------------------------------------
# SQS
# ---------------------------------------------------------------------

variable "sqs_queue_name" {
  type    = string
  default = "evaluation"
}
# ---------------------------------------------------------------------
# GitHub Actions OIDC - origem do secret AWS_ROLE_TO_ASSUME
# ---------------------------------------------------------------------

variable "enable_github_oidc" {
  description = <<-EOT
    true = cria a IAM role que o GitHub Actions assume via OIDC para
           publicar no ECR. Exige github_repository preenchido e
           is_academy = false (Academy nao permite criar IAM role).
    false = nao cria nada; o pipeline tem que usar as chaves temporarias
           do Learner Lab (secrets AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN).
  EOT
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "Repositorio autorizado a assumir a role, formato dono/repositorio (obrigatorio quando enable_github_oidc = true)"
  type        = string
  default     = ""
}

variable "github_oidc_role_name" {
  description = <<-EOT
    Nome da IAM role. null = "<project_name>-github-actions". Se voce ja
    criou a role a mao antes de trazer isso pro Terraform, coloque o nome
    dela aqui e rode o `tofu import` (ver README) - senao o apply cria
    uma segunda role fazendo a mesma coisa.
  EOT
  type        = string
  default     = null
}

variable "github_oidc_allowed_branches" {
  description = "Branches que podem assumir a role - os workflows so publicam no ECR em push na main"
  type        = list(string)
  default     = ["main"]
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    O provider OIDC do GitHub e unico por conta AWS. Deixe true na
    primeira vez; mude para false se a conta ja tiver o
    token.actions.githubusercontent.com registrado (por outro stack ou
    criado a mao), senao o apply falha com EntityAlreadyExists.
  EOT
  type        = bool
  default     = true
}
