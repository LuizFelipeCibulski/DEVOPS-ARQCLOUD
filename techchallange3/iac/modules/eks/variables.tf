variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "control_plane_subnet_ids" {
  description = "Subnets usadas pelas ENIs do control plane (public + private-app, para permitir endpoint publico e privado)"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnets private-app onde os nos (EC2) do node group sobem"
  type        = list(string)
}

# --- Modo Academy vs Normal --------------------------------------------
variable "is_academy" {
  description = "true = reaproveita a LabRole existente (não cria IAM role nenhuma); false = cria roles proprias + OIDC/IRSA"
  type        = bool
}

variable "existing_role_arn" {
  description = "ARN da LabRole (obrigatorio quando is_academy = true)"
  type        = string
  default     = null
}

variable "enable_irsa" {
  description = "Cria o provider OIDC do cluster para permitir IRSA (so faz sentido quando is_academy = false)"
  type        = bool
  default     = false
}

# --- Node group ----------------------------------------------------------
variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"
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

variable "endpoint_public_access" {
  type    = bool
  default = true
}

variable "endpoint_private_access" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
