#!/usr/bin/env bash
# =====================================================================================
# Bootstrap do backend remoto do Terraform (S3 + DynamoDB lock table)
# -------------------------------------------------------------------------------------
# Por que isso existe fora do Terraform do projeto?
#   O backend (onde o state fica guardado) precisa existir ANTES do "terraform init".
#   Se o bucket/tabela fossem criados pelo próprio Terraform do projeto, teríamos um
#   problema de "galinha e ovo": o Terraform precisaria do backend pra rodar, mas o
#   backend seria criado pelo Terraform. Por isso esse script roda uma única vez,
#   manualmente, fora do fluxo de CI/CD, com credenciais locais (aws configure).
#
# Como usar:
#   chmod +x bootstrap-backend.sh
#   ./bootstrap-backend.sh
# =====================================================================================
set -euo pipefail

# ---- AJUSTE AQUI ----
BUCKET_NAME="togglemaster-tfstate-tibursio"          # precisa ser globalmente único no S3
DYNAMODB_TABLE="togglemaster-tfstate-lock-tibursio"
AWS_REGION="us-east-1"
# ----------------------

echo "==> Criando bucket S3 para o Terraform state: $BUCKET_NAME"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "Bucket já existe, pulando criação."
else
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
fi

echo "==> Habilitando versionamento (permite recuperar um state anterior em caso de erro)"
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

echo "==> Habilitando criptografia padrão (SSE-S3)"
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

echo "==> Bloqueando acesso público ao bucket (o state contém dados sensíveis)"
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "==> Criando tabela DynamoDB para lock do state: $DYNAMODB_TABLE"
if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Tabela já existe, pulando criação."
else
  aws dynamodb create-table \
    --table-name "$DYNAMODB_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"

  echo "Aguardando a tabela ficar ativa..."
  aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE" --region "$AWS_REGION"
fi

cat <<EOF

✅ Backend pronto! Agora descomente o bloco "backend s3" em providers.tf com:

  backend "s3" {
    bucket         = "$BUCKET_NAME"
    key            = "tech-challenge-fase2/terraform.tfstate"
    region         = "$AWS_REGION"
    dynamodb_table = "$DYNAMODB_TABLE"
    encrypt        = true
  }

Depois rode "terraform init" (ou "tofu init") para migrar o state local para o S3.
EOF