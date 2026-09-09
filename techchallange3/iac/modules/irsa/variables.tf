variable "role_name" {
  description = "Nome da IAM role"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN do provider OIDC do cluster EKS (saida do modulo eks)"
  type        = string
}

variable "oidc_issuer_url" {
  description = "URL do issuer OIDC do cluster, com https:// (saida do modulo eks)"
  type        = string
}

variable "namespace" {
  description = "Namespace do Kubernetes onde vive a ServiceAccount"
  type        = string
}

variable "service_account" {
  description = "Nome da ServiceAccount que pode assumir esta role"
  type        = string
}

variable "policy_json" {
  description = "Documento de policy (JSON) com as permissoes que a role concede"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
