# ---------------------------------------------------------------------
# Role assumida pelo GitHub Actions via OIDC (secret AWS_ROLE_TO_ASSUME)
# ---------------------------------------------------------------------
# Substitui o par AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY guardado no
# repositorio: o GitHub apresenta um token JWT assinado, a AWS valida a
# assinatura contra este provider e devolve credencial temporaria. Nao
# existe chave de longa duracao para vazar.
#
# So faz sentido em conta normal - o AWS Academy nao permite criar IAM
# role nem OIDC provider (nesse modo o pipeline usa as chaves
# temporarias do Learner Lab; ver ../../update-secrets-aws.sh).
# ---------------------------------------------------------------------

locals {
  oidc_host = "token.actions.githubusercontent.com"

  # "repo:dono/repo:ref:refs/heads/main" - o claim `sub` que o GitHub
  # coloca no token. E a unica coisa que separa o seu repositorio de
  # qualquer outro repositorio do mundo.
  branch_subjects = [
    for branch in var.allowed_branches :
    "repo:${var.github_repository}:ref:refs/heads/${branch}"
  ]

  allowed_subjects = concat(local.branch_subjects, var.additional_subjects)

  role_name = coalesce(var.role_name, "${var.project_name}-github-actions")

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# O thumbprint do certificado do GitHub muda quando eles rotacionam a CA;
# lendo do proprio endpoint a gente nao precisa hardcodar o hash (mesmo
# padrao usado no modulo eks para o OIDC do cluster).
data "tls_certificate" "github" {
  count = var.create_oidc_provider ? 1 : 0
  url   = "https://${local.oidc_host}"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://${local.oidc_host}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "github-actions-oidc"
  })
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://${local.oidc_host}"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # aud fixo: garante que o token foi emitido para a STS da AWS e nao
    # para outro servico.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike (e nao StringEquals) porque os subjects podem conter
    # curingas em usos mais avancados; a lista em si ja e restritiva.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = local.allowed_subjects
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = local.role_name
  description          = "Assumida pelo GitHub Actions (${var.github_repository}) para publicar imagens no ECR"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration

  tags = merge(var.tags, {
    Name = local.role_name
  })
}

data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken nao aceita recurso especifico - e a chamada que
  # o `aws-actions/amazon-ecr-login` faz para trocar o token pelo login
  # do docker.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
