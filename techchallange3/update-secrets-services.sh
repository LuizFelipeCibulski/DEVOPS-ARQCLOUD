#!/usr/bin/env bash
set -euo pipefail

CREDS_FILE="${1:-}"

if [ -z "$CREDS_FILE" ] || [ ! -f "$CREDS_FILE" ]; then
  echo "Uso: $0 <arquivo-de-urls>"
  echo ""
  echo "Cole o conteúdo output do terraform"
  echo "em um arquivo texto e passe o caminho dele aqui."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) não encontrada. Instale em https://cli.github.com/ e rode 'gh auth login'."
  exit 1
fi


ECR_ANALYTICS_SERVICE=$(grep -i 'analytics-service' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')
ECR_AUTH_SERVICE=$(grep -i 'auth-service' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')
ECR_EVALUATION_SERVICE=$(grep -i 'evaluation-service' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')
ECR_FLAG_SERVICE=$(grep -i 'flag-service' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')
ECR_TARGETING_SERVICE=$(grep -i 'targeting-service' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')

if [ -z "$ECR_ANALYTICS_SERVICE" ] || [ -z "$ECR_AUTH_SERVICE" ] || [ -z "$ECR_EVALUATION_SERVICE" ] || [ -z "$ECR_FLAG_SERVICE" ] || [ -z "$ECR_TARGETING_SERVICE"  ]; then
  echo "Não consegui extrair as 5 credenciais do arquivo. Confira o formato esperado no cabeçalho deste script."
  exit 1
fi

echo "==> Atualizando secrets no GitHub..."
gh secret set ECR_ANALYTICS_SERVICE     --body "$ECR_ANALYTICS_SERVICE"
gh secret set ECR_AUTH_SERVICE --body "$ECR_AUTH_SERVICE"
gh secret set ECR_EVALUATION_SERVICE     --body "$ECR_EVALUATION_SERVICE"
gh secret set ECR_FLAG_SERVICE --body "$ECR_FLAG_SERVICE"
gh secret set ECR_TARGETING_SERVICE --body "$ECR_TARGETING_SERVICE"

echo ""
echo "✅ Secrets atualizados! Válidos até a sessão do Lab expirar (geralmente poucas horas)."
echo "   Quando o pipeline começar a falhar com erro de token expirado, rode este script de novo."
