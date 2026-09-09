# =====================================================================
# Configuração do ambiente - VERSIONADA de propósito
# ---------------------------------------------------------------------
# Este arquivo existe porque o pipeline (terraform.yml) roda num runner
# limpo, sem o seu terraform.tfvars local. Sem ele, o apply do CI usaria
# os defaults de variables.tf e faria estrago silencioso:
#   - enable_github_oidc = false  ->  destruiria a role do ECR e
#                                     quebraria os 5 pipelines
#   - endpoint_public_access = false -> cortaria o acesso via kubectl
#
# O sufixo .auto.tfvars faz o OpenTofu carregar sozinho, sem precisar de
# -var-file no pipeline. Não há nada sensível aqui: são liga/desliga e
# nomes de recurso. Segredo nenhum entra neste arquivo.
# =====================================================================

is_academy         = false
manage_eks_cluster = true

# ---------------------------------------------------------------------
# CI/CD - roles assumidas pelo GitHub Actions via OIDC
# ---------------------------------------------------------------------
enable_github_oidc          = true
github_repository           = "LuizFelipeCibulski/DEVOPS-ARQCLOUD"
create_github_oidc_provider = false # o provider já existe nesta conta
github_oidc_role_name       = "github-actions-ecr-push"
create_terraform_role       = true # role do próprio terraform.yml

# ---------------------------------------------------------------------
# Camada de aplicação: Secrets Manager + as 5 roles IRSA
# ---------------------------------------------------------------------
enable_app_platform = true

# ---------------------------------------------------------------------
# Acesso à API do cluster
# ---------------------------------------------------------------------
# O CIDR NÃO fica aqui: é o IP de quem administra, muda sozinho quando a
# operadora troca, e não faz sentido versionar. Ele vem da variável de
# repositório EKS_PUBLIC_ACCESS_CIDRS, que o terraform.yml injeta como
# TF_VAR_public_access_cidrs. Localmente, continue usando o seu
# terraform.tfvars (que tem precedência sobre TF_VAR_*).
#
# Trocou de IP? Atualize a variável e o próximo apply acerta:
#   gh api -X PATCH repos/:owner/:repo/actions/variables/EKS_PUBLIC_ACCESS_CIDRS \
#     -f name=EKS_PUBLIC_ACCESS_CIDRS -f 'value=["SEU.IP.AQUI/32"]'
endpoint_public_access = true
