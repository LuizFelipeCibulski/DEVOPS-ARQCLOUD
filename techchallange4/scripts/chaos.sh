#!/usr/bin/env bash
# =====================================================================
# Injeção de falha no auth-service - "A Prova Real" do vídeo
# ---------------------------------------------------------------------
#   ./techchallange4/scripts/chaos.sh on [taxa]   # padrão 0.5 = 50% de HTTP 500
#   ./techchallange4/scripts/chaos.sh off
#   ./techchallange4/scripts/chaos.sh status
#
# Como funciona: POST /admin/chaos (protegido pela MASTER_KEY) liga um
# middleware que devolve 500 numa fração das requisições. O estado fica
# SÓ na memória do processo -> o rollout restart do self-healer cria pods
# novos, limpos, e a falha some. É exatamente o ciclo a demonstrar:
#
#   chaos on -> 5xx > 5% por 1 min -> alerta FIRING no Grafana
#     -> PagerDuty abre incidente + Discord notifica
#     -> self-healer executa rollout restart deployment/auth-service
#     -> pods novos sem a falha -> 5xx volta a 0 -> alerta RESOLVED
#
# O comando entra por port-forward (o /admin não precisa ficar exposto).
# =====================================================================
set -euo pipefail
acao="${1:-status}"; taxa="${2:-0.5}"

MASTER_KEY=$(kubectl get secret -n auth-service auth-secrets -o jsonpath='{.data.MASTER_KEY}' | base64 -d)
PORTA=18001
kubectl port-forward -n auth-service deploy/auth-service "$PORTA:8001" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s "localhost:$PORTA/health" >/dev/null 2>&1 && break; sleep 0.5; done

case "$acao" in
  on)     corpo="{\"error_rate\": $taxa}" ;;
  off)    corpo='{"error_rate": 0}' ;;
  status) corpo="" ;;
  *) echo "uso: $0 on [taxa] | off | status"; exit 1 ;;
esac

if [ -n "$corpo" ]; then
  curl -s -X POST "localhost:$PORTA/admin/chaos" -H "Authorization: Bearer $MASTER_KEY" -d "$corpo"; echo
else
  curl -s "localhost:$PORTA/admin/chaos" -H "Authorization: Bearer $MASTER_KEY"; echo
fi
echo "pod: $(kubectl get pod -n auth-service -l app=auth-service -o jsonpath='{.items[0].metadata.name}')"
[ "$acao" = on ] && echo "Agora rode o gerar-trafego.sh e acompanhe: kubectl get pods -n auth-service -w"
