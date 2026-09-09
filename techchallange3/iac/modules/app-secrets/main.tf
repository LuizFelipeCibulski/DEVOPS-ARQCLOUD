# ---------------------------------------------------------------------
# Secrets das aplicacoes no AWS Secrets Manager
# ---------------------------------------------------------------------
# O External Secrets Operator le daqui e materializa Secrets do
# Kubernetes. Nenhum valor sensivel entra no repositorio git: o que fica
# versionado sao os manifestos ExternalSecret, que so citam o *caminho*
# do segredo.
#
# Cada secret guarda um JSON, e o ESO extrai chave a chave via
# `remoteRef.property`.
# ---------------------------------------------------------------------

# MASTER_KEY: credencial de admin do auth-service. Nao e gerada pelo
# servico - ele a recebe pronta e usa para proteger o POST /admin/keys
# (o endpoint que cunha as API keys). Como e so um segredo compartilhado,
# geramos aqui e ninguem precisa nunca ver o valor.
resource "random_password" "master_key" {
  length  = 48
  special = false # evita dor de cabeca com escaping em header HTTP
}

locals {
  conteudo = {
    "auth-service" = {
      DATABASE_URL = var.database_urls["auth-service"]
      MASTER_KEY   = random_password.master_key.result
    }
    "flag-service" = {
      DATABASE_URL = var.database_urls["flag-service"]
    }
    "targeting-service" = {
      DATABASE_URL = var.database_urls["targeting-service"]
    }
    "evaluation-service" = {
      REDIS_URL = var.redis_url
    }
  }
}

resource "aws_secretsmanager_secret" "app" {
  for_each = local.conteudo

  name                    = "${var.name_prefix}/${each.key}"
  description             = "Secrets do ${each.key} - consumidos via External Secrets Operator"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}/${each.key}"
  })
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each = local.conteudo

  secret_id     = aws_secretsmanager_secret.app[each.key].id
  secret_string = jsonencode(each.value)
}

# ---------------------------------------------------------------------
# SERVICE_API_KEY - o secret que o Terraform NAO preenche
# ---------------------------------------------------------------------
# Este valor so existe depois que o auth-service estiver de pe: e ele
# quem cunha a chave, via POST /admin/keys autenticado com a MASTER_KEY,
# e devolve o texto plano uma unica vez (o banco guarda so o hash).
# Quem preenche e o Job de bootstrap do Kubernetes.
#
# Por isso criamos o *container* do secret aqui (para o ESO ter um
# caminho estavel para apontar e para a IAM policy poder referenciar o
# ARN), mas nao criamos nenhum secret_version: se o Terraform gerenciasse
# o conteudo, todo `apply` sobrescreveria a chave cunhada pelo Job.
resource "aws_secretsmanager_secret" "service_api_key" {
  name                    = "${var.name_prefix}/service-api-key"
  description             = "SERVICE_API_KEY cunhada pelo Job de bootstrap do auth-service (NAO gerenciada pelo Terraform)"
  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}/service-api-key"
  })
}
