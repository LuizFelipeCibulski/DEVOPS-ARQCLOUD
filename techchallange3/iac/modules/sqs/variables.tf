variable "queue_name" {
  type    = string
  default = "evaluation"
}

variable "visibility_timeout_seconds" {
  description = "Deve ser >= tempo que o analytics-service leva pra processar + gravar no DynamoDB"
  type        = number
  default     = 30
}

variable "message_retention_seconds" {
  type    = number
  default = 86400 # 1 dia
}

variable "max_receive_count" {
  description = "Quantas vezes uma mensagem pode falhar antes de ir pra Dead Letter Queue"
  type        = number
  default     = 5
}

variable "tags" {
  type    = map(string)
  default = {}
}
