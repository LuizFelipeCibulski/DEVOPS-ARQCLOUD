#!/usr/bin/env bash
# =====================================================================================
# Atualiza os secrets do GitHub com as credenciais temporárias do AWS Academy
# -------------------------------------------------------------------------------------
# Por que isso é necessário?
#   No AWS Academy (Vocareum / Learner Lab), as credenciais são temporárias e
#   expiram a cada poucas horas (ou quando a sessão do Lab reinicia). Diferente
#   de uma conta normal, aqui NÃO dá pra usar uma IAM Role fixa via OIDC - o
#   pipeline precisa de um Access Key + Secret Key + Session Token atualizados.
#
#   Este script lê essas 3 credenciais (que você copia da aba "AWS Details" do
#   Learner Lab, botão "Show" em "AWS CLI") e atualiza os secrets do repositório
#   no GitHub automaticamente, usando a GitHub CLI (`gh`).
#
# Pré-requisitos:
#   - GitHub CLI instalada e autenticada: https://cli.github.com/  (`gh auth login`)
#   - Rodar este script de dentro do repositório (ou passar --repo dono/repo)
#
# Como usar:
#   1. No Learner Lab, clique em "AWS Details" -> "Show" (ao lado de AWS CLI)
#   2. Copie o conteúdo (formato abaixo) para um arquivo, ex: academy-creds.txt:
#        [default]
#        aws_access_key_id=ASIA...
#        aws_secret_access_key=...
#        aws_session_token=...
#   3. Rode:
#        ./update-academy-secrets.sh academy-creds.txt
#   4. Repita sempre que a sessão do Lab expirar (o pipeline vai começar a
#      falhar no login AWS com "ExpiredToken" - esse é o sinal pra rodar de novo).
# =====================================================================================
set -euo pipefail

CREDS_FILE="${1:-}"

if [ -z "$CREDS_FILE" ] || [ ! -f "$CREDS_FILE" ]; then
  echo "Uso: $0 <arquivo-de-credenciais-do-academy>"
  echo ""
  echo "Cole o conteúdo de 'AWS Details -> AWS CLI -> Show' do Learner Lab"
  echo "em um arquivo texto e passe o caminho dele aqui."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) não encontrada. Instale em https://cli.github.com/ e rode 'gh auth login'."
  exit 1
fi

ACCESS_KEY=$(grep -i 'aws_access_key_id' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')
SECRET_KEY=$(grep -i 'aws_secret_access_key' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')
SESSION_TOKEN=$(grep -i 'aws_session_token' "$CREDS_FILE" | cut -d'=' -f2- | tr -d ' \r')

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ] || [ -z "$SESSION_TOKEN" ]; then
  echo "Não consegui extrair as 3 credenciais do arquivo. Confira o formato esperado no cabeçalho deste script."
  exit 1
fi

echo "==> Atualizando secrets no GitHub..."
gh secret set AWS_ACCESS_KEY_ID     --body "$ACCESS_KEY"
gh secret set AWS_SECRET_ACCESS_KEY --body "$SECRET_KEY"
gh secret set AWS_SESSION_TOKEN     --body "$SESSION_TOKEN"

echo "==> Garantindo que a variável AWS_MODE está como 'academy'..."
gh variable set AWS_MODE --body "academy"

echo ""
echo "✅ Secrets atualizados! Válidos até a sessão do Lab expirar (geralmente poucas horas)."
echo "   Quando o pipeline começar a falhar com erro de token expirado, rode este script de novo."