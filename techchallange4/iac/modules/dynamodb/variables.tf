variable "table_name" {
  description = "Nome da tabela DynamoDB usada pelo analytics-service (AWS_DYNAMODB_TABLE)"
  type        = string
  default     = "ToggleMasterAnalytics"
}

variable "hash_key" {
  description = "Chave primaria esperada pelo codigo do analytics-service (item['event_id'])"
  type        = string
  default     = "event_id"
}

variable "tags" {
  type    = map(string)
  default = {}
}
