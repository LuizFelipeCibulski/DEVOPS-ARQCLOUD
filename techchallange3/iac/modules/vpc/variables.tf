variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos da VPC"
  type        = string
}

variable "vpc_cidr" {
  description = "Bloco CIDR principal da VPC"
  type        = string
}

variable "azs" {
  description = "Availability Zones a utilizar (mínimo 2, exigido pelo RDS DB Subnet Group)"
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Informe pelo menos 2 AZs (RDS Subnet Group exige >= 2)."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas (uma por AZ) - só aqui vive o Load Balancer do Ingress"
  type        = list(string)
}

variable "private_app_subnet_cidrs" {
  description = "CIDRs das subnets privadas de aplicação (uma por AZ) - nós do EKS"
  type        = list(string)
}

variable "private_db_subnet_cidrs" {
  description = "CIDRs das subnets privadas de dados (uma por AZ) - RDS e ElastiCache, totalmente isoladas da internet"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true = 1 único NAT Gateway (mais barato); false = 1 NAT Gateway por AZ (mais resiliente)"
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Nome do cluster EKS que vai usar essas subnets (usado nas tags kubernetes.io/*)"
  type        = string
}

variable "tags" {
  description = "Tags comuns aplicadas a todos os recursos"
  type        = map(string)
  default     = {}
}
