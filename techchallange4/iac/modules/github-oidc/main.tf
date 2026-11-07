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

# ---------------------------------------------------------------------
# Role do workflow terraform.yml (secret AWS_TERRAFORM_ROLE_ARN)
# ---------------------------------------------------------------------
# Problema do ovo e da galinha: quem cria esta role e o Terraform, mas
# quem roda o Terraform no CI precisa dela. Resolve-se com UM apply local
# (credencial do `aws configure`), depois o pipeline se sustenta sozinho.
# O README do iac documenta o passo.

locals {
  terraform_role_name = coalesce(var.terraform_role_name, "${var.project_name}-github-terraform")
}

# ATENCAO - a pegadinha que quebrou o primeiro apply do pipeline:
#
# Quando um job declara `environment: production` (que e o que liga o
# gate de aprovacao manual), o GitHub MUDA o claim `sub` do token OIDC.
# Ele deixa de ser
#     repo:<owner>/<repo>:ref:refs/heads/main
# e passa a ser
#     repo:<owner>/<repo>:environment:production
#
# Por isso o job `plan` (sem environment) autenticava e o `apply` morria
# com "Not authorized to perform sts:AssumeRoleWithWebIdentity" - a
# trust policy so conhecia o formato de branch.
#
# A role do ECR NAO ganha esses subjects: os jobs dela nao usam
# environment, e ampliar a confianca dela sem necessidade seria piorar
# o escopo de graca.
data "aws_iam_policy_document" "assume_role_terraform" {
  count = var.create_terraform_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = concat(
        local.allowed_subjects,
        [for env in var.terraform_environments : "repo:${var.github_repository}:environment:${env}"],
      )
    }
  }
}

resource "aws_iam_role" "terraform" {
  count = var.create_terraform_role ? 1 : 0

  name                 = local.terraform_role_name
  description          = "Assumida pelo workflow terraform.yml de ${var.github_repository}"
  assume_role_policy   = data.aws_iam_policy_document.assume_role_terraform[0].json
  max_session_duration = 3600

  tags = merge(var.tags, {
    Name = local.terraform_role_name
  })
}

resource "aws_iam_role_policy_attachment" "terraform" {
  for_each = var.create_terraform_role ? toset(var.terraform_policy_arns) : toset([])

  role       = aws_iam_role.terraform[0].name
  policy_arn = each.value
}

# O state fica num bucket S3 com lock no DynamoDB (ver providers.tf). O
# PowerUserAccess ja cobre os dois, mas deixamos explicito para quem
# trocar as policies por algo mais restrito nao esquecer desta parte.
data "aws_iam_policy_document" "terraform_state" {
  count = var.create_terraform_role ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.tfstate_bucket}", "arn:aws:s3:::${var.tfstate_bucket}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:*:*:table/${var.tfstate_lock_table}"]
  }
}

resource "aws_iam_role_policy" "terraform_state" {
  count = var.create_terraform_role ? 1 : 0

  name   = "tfstate-backend"
  role   = aws_iam_role.terraform[0].id
  policy = data.aws_iam_policy_document.terraform_state[0].json
}
