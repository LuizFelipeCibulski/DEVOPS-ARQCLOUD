#!/usr/bin/env bash
# =====================================================================
# Grava os tokens das integrações externas no AWS Secrets Manager
# ---------------------------------------------------------------------
# Cofre: togglemaster/prod/observability  (criado vazio pelo Terraform)
# O External Secrets Operator replica para o cluster em até 1 minuto, e
# este script reinicia quem lê os tokens no boot (Grafana, OTel
# Collector, self-healer).
#
# Uso (interativo - os valores não aparecem na tela nem no histórico):
#   ./techchallange4/scripts/set-observability-secrets.sh
#
# Ou não-interativo (CI, ou para trocar só um token):
#   NEW_RELIC_LICENSE_KEY=... PAGERDUTY_ROUTING_KEY=... \
#   DISCORD_WEBHOOK_URL=... ./set-observability-secrets.sh --yes
#
# Campo vazio = mantém o valor que já está no cofre.
# SELF_HEALER_TOKEN e a senha do Grafana são gerados automaticamente na
# primeira execução e preservados nas seguintes.
# =====================================================================
set -euo pipefail

SECRET_ID="${SECRET_ID:-togglemaster/prod/observability}"
REGION="${AWS_REGION:-us-east-1}"
NAO_INTERATIVO=false
[ "${1:-}" = "--yes" ] && NAO_INTERATIVO=true

for bin in aws jq openssl; do
  command -v "$bin" >/dev/null || { echo "Falta o comando '$bin'."; exit 1; }
done

# Valor atual (ou {} se o cofre ainda não tem versão nenhuma)
atual=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ID" \
          --query SecretString --output text 2>/dev/null || echo '{}')
pega() { echo "$atual" | jq -r --arg k "$1" '.[$k] // empty'; }

pergunta() { # nome descrição
  local nome="$1" desc="$2" valor="${!1:-}"
  if [ -z "$valor" ] && [ "$NAO_INTERATIVO" = false ]; then
    local tem=""; [ -n "$(pega "$nome")" ] && tem=" [ENTER mantém o atual]"
    read -r -s -p "$desc$tem: " valor; echo
  fi
  [ -z "$valor" ] && valor="$(pega "$nome")"
  printf -v "$nome" '%s' "$valor"
}

echo "== Tokens das integrações (Secrets Manager: $SECRET_ID)"
pergunta NEW_RELIC_LICENSE_KEY "New Relic - INGEST - LICENSE key (termina com NRAL)"
pergunta PAGERDUTY_ROUTING_KEY "PagerDuty - Integration Key do serviço (Events API v2)"
pergunta DISCORD_WEBHOOK_URL   "Discord - Webhook URL do canal (https://discord.com/api/webhooks/...)"

SELF_HEALER_TOKEN="${SELF_HEALER_TOKEN:-$(pega SELF_HEALER_TOKEN)}"
[ -z "$SELF_HEALER_TOKEN" ] && SELF_HEALER_TOKEN=$(openssl rand -hex 32)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-$(pega GRAFANA_ADMIN_USER)}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(pega GRAFANA_ADMIN_PASSWORD)}"
[ -z "$GRAFANA_ADMIN_PASSWORD" ] && GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')

# Validações rápidas de formato (erro de cópia é o problema nº 1)
case "$DISCORD_WEBHOOK_URL" in
  ""|https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
  *) echo "AVISO: DISCORD_WEBHOOK_URL não parece um webhook do Discord." ;;
esac
[ -n "$PAGERDUTY_ROUTING_KEY" ] && [ ${#PAGERDUTY_ROUTING_KEY} -ne 32 ] && \
  echo "AVISO: a Integration Key do PagerDuty costuma ter 32 caracteres (esta tem ${#PAGERDUTY_ROUTING_KEY})."

json=$(jq -n \
  --arg nr "$NEW_RELIC_LICENSE_KEY" --arg pd "$PAGERDUTY_ROUTING_KEY" \
  --arg dc "$DISCORD_WEBHOOK_URL" --arg sh "$SELF_HEALER_TOKEN" \
  --arg gu "$GRAFANA_ADMIN_USER" --arg gp "$GRAFANA_ADMIN_PASSWORD" \
  '{NEW_RELIC_LICENSE_KEY:$nr, PAGERDUTY_ROUTING_KEY:$pd, DISCORD_WEBHOOK_URL:$dc,
    SELF_HEALER_TOKEN:$sh, GRAFANA_ADMIN_USER:$gu, GRAFANA_ADMIN_PASSWORD:$gp}')

aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET_ID" \
  --secret-string "$json" >/dev/null
echo "✔ Gravado em $SECRET_ID"
echo "  Preenchidos: $(echo "$json" | jq -r 'to_entries|map(select(.value!=""))|map(.key)|join(", ")')"
vazios=$(echo "$json" | jq -r 'to_entries|map(select(.value==""))|map(.key)|join(", ")')
[ -n "$vazios" ] && echo "  ⚠ Ainda vazios: $vazios"

# ---- Propaga para o cluster ------------------------------------------
if kubectl get ns observability >/dev/null 2>&1; then
  echo "== Forçando o ESO a reler o cofre e reiniciando quem lê os tokens no boot"
  for es in observability/observability-secrets self-healing/self-healer-secrets; do
    ns=${es%%/*}; name=${es##*/}
    kubectl annotate externalsecret -n "$ns" "$name" force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  done
  sleep 10
  kubectl rollout restart -n observability deployment/kps-grafana 2>/dev/null || true
  kubectl rollout restart -n observability daemonset/otel-collector-agent 2>/dev/null \
    || kubectl rollout restart -n observability daemonset/otel-collector 2>/dev/null || true
  kubectl rollout restart -n self-healing deployment/self-healer 2>/dev/null || true
  echo "✔ Reinício disparado. Login do Grafana: usuário '$GRAFANA_ADMIN_USER' (senha: rode"
  echo "  aws secretsmanager get-secret-value --secret-id $SECRET_ID --query SecretString --output text | jq -r .GRAFANA_ADMIN_PASSWORD)"
else
  echo "(cluster ainda sem a stack de observabilidade - o ESO aplica quando ela subir)"
fi
