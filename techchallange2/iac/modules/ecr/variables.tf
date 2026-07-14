variable "repository_names" {
  description = "Nomes dos repositórios ECR a criar (um por microsserviço)"
  type        = list(string)
}

variable "image_retention_count" {
  description = "Quantidade de imagens tagueadas a manter por repositório (lifecycle policy)"
  type        = number
  default     = 10
}

variable "tags" {
  type    = map(string)
  default = {}
}
