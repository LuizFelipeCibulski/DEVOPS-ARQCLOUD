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

# ---------------------------------------------------------------------
# Fase 4: AWS Academy (Learner Lab)
# ---------------------------------------------------------------------
# A conta do Academy NAO permite iam:CreateRole (testado: AccessDenied).
# Consequencias, todas tratadas no codigo:
#   - EKS e node group usam a LabRole (lookup, nunca criacao)
#   - sem provider OIDC => sem IRSA: os pods usam a LabRole do no via IMDS
#   - sem role OIDC do GitHub: os pipelines usam as chaves temporarias do
#     Lab (secrets AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN + AWS_MODE=academy)
#   - Secrets Manager continua: o ESO le os cofres com a credencial do no
is_academy         = true
lab_role_name      = "LabRole"
manage_eks_cluster = true

enable_github_oidc  = false
enable_app_platform = true

# ---------------------------------------------------------------------
# Acesso a API do cluster
# ---------------------------------------------------------------------
# O CIDR NAO fica aqui: e o IP de quem administra. Vem da variavel de
# repositorio EKS_PUBLIC_ACCESS_CIDRS (CI) ou do terraform.tfvars local.
endpoint_public_access = true
