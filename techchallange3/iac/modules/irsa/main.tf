# ---------------------------------------------------------------------
# IRSA - IAM Roles for Service Accounts
# ---------------------------------------------------------------------
# Mesma ideia do OIDC do GitHub Actions, mas para dentro do cluster: o
# kubelet injeta no pod um token JWT assinado pelo issuer do EKS, o SDK
# da AWS troca esse token por credencial temporaria, e nenhuma chave
# estatica precisa existir. E o que elimina os AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN dos Secrets do Kubernetes.
#
# A amarracao e o claim `sub` do token: system:serviceaccount:<ns>:<sa>.
# Uma ServiceAccount de outro namespace nao assume esta role, mesmo que
# alguem descubra o ARN dela.
# ---------------------------------------------------------------------

locals {
  # O claim vem sem o https://, entao tiramos o prefixo do issuer.
  oidc_host = replace(var.oidc_issuer_url, "https://", "")
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    # Sem esta condicao o token poderia ter sido emitido para outra
    # audience e ainda assim ser aceito.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = "IRSA: ${var.namespace}/${var.service_account}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, {
    Name = var.role_name
  })
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
