variable "project_name" {
  description = "Prefixo usado no nome da role"
  type        = string
}

variable "role_name" {
  description = <<-EOT
    Nome da IAM role. Deixe null para usar "<project_name>-github-actions".
    Preencha com o nome de uma role que ja exista se quiser adotar ela
    por `tofu import` em vez de criar uma nova (ver README).
  EOT
  type        = string
  default     = null
}

variable "github_repository" {
  description = <<-EOT
    Repositorio que tem permissao de assumir a role, no formato
    "dono/repositorio" (ex: "luizcibulski/DEVOPS-ARQCLOUD"). E o valor
    que entra na condicao `sub` da trust policy - sem isso qualquer
    repositorio do GitHub poderia assumir a role.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository deve estar no formato dono/repositorio."
  }
}

variable "allowed_branches" {
  description = <<-EOT
    Branches autorizadas a assumir a role. Os workflows so publicam no
    ECR em push na main (`if: github.ref == 'refs/heads/main'`), entao o
    default reflete exatamente isso - a role nao pode ser assumida a
    partir de um PR de terceiros.
  EOT
  type        = list(string)
  default     = ["main"]
}

variable "additional_subjects" {
  description = <<-EOT
    Escape hatch para subjects extras do OIDC, caso precise liberar um
    environment ou tag (ex: "repo:dono/repo:environment:production").
    Deixe vazio se so usa branches.
  EOT
  type        = list(string)
  default     = []
}

variable "create_oidc_provider" {
  description = <<-EOT
    O provider OIDC do GitHub e um recurso *por conta AWS*, nao por
    projeto. true = este Terraform cria; false = so faz lookup de um
    provider que ja existe (use false se outro projeto/stack da mesma
    conta ja registrou o token.actions.githubusercontent.com, senao o
    apply falha com EntityAlreadyExists).
  EOT
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = <<-EOT
    ARNs dos repositorios ECR em que a role pode dar push. Passar a
    lista explicita (em vez de "*") e o que mantem a permissao minima:
    o pipeline publica imagem, e nao consegue mexer em nenhum outro
    recurso da conta.
  EOT
  type        = list(string)
}

variable "max_session_duration" {
  description = "Duracao maxima da credencial temporaria, em segundos (1h e suficiente para build + push)"
  type        = number
  default     = 3600
}

variable "tags" {
  type    = map(string)
  default = {}
}
