variable "project_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets private-db onde o Redis vai morar"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security Groups autorizados a falar com o Redis na porta 6379 (SG dos nos do EKS)"
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDRs autorizados a falar com o Redis na porta 6379 (fallback quando nao ha SG de cluster gerenciado pelo Terraform)"
  type        = list(string)
  default     = []
}

variable "serverless" {
  description = "true = ElastiCache Serverless for Redis (paga por uso, escala sozinho); false = cluster provisionado tradicional"
  type        = bool
  default     = true
}

# --- usado somente quando serverless = false ---
variable "node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "tags" {
  type    = map(string)
  default = {}
}
