variable "name_prefix" {
  description = "Prefixo dos secrets no Secrets Manager, ex: togglemaster/prod"
  type        = string
}

variable "database_urls" {
  description = "Mapa nome-do-servico => DATABASE_URL (saida do modulo rds)"
  type        = map(string)
  sensitive   = true
}

variable "redis_url" {
  description = "REDIS_URL do evaluation-service"
  type        = string
}

variable "recovery_window_in_days" {
  description = <<-EOT
    Janela de recuperacao ao deletar um secret. 0 = apaga na hora.
    O default da AWS (30 dias) e um problema em ambiente de estudo: apos
    um `destroy`, o nome fica reservado e o proximo `apply` falha com
    InvalidRequestException ate a janela vencer.
  EOT
  type        = number
  default     = 0
}

variable "tags" {
  type    = map(string)
  default = {}
}
