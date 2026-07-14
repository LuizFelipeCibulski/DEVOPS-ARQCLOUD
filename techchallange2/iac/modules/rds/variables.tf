variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets private-db (isoladas) onde as instâncias RDS vão morar"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security Groups que podem falar com o Postgres na porta 5432 (ex: SG dos nos do EKS)"
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDRs que podem falar com o Postgres na porta 5432 (fallback quando nao ha SG de cluster gerenciado pelo Terraform)"
  type        = list(string)
  default     = []
}

variable "databases" {
  description = "Um banco RDS independente por microsservico: chave = nome do servico"
  type = map(object({
    db_name  = string
    username = string
  }))
}

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  description = "true = nao gera snapshot final ao destruir (mais pratico p/ ambiente de estudo/Academy)"
  type        = bool
  default     = true
}

variable "backup_retention_period" {
  type    = number
  default = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
