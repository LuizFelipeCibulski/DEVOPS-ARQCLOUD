#!/usr/bin/env bash
# =====================================================================
# Gerador de tráfego - deixa os dashboards, traces e o alerta "vivos"
# ---------------------------------------------------------------------
# Faz, em loop, o caminho completo de negócio pela URL pública (Traefik):
#   GET /evaluation/evaluate   -> evaluation -> Redis -> flag/targeting -> auth -> SQS -> analytics
#   GET /flags/flags/<nome>    -> flag -> auth (gera tráfego constante no auth-service,
#                                 já que o evaluation tem cache de 30s)
#
# Uso:
#   ./techchallange4/scripts/gerar-trafego.sh            # roda até Ctrl+C
#   DURACAO=300 RPS=5 ./techchallange4/scripts/gerar-trafego.sh
#
# Na primeira execução cria a flag "nova-ui" (50% dos usuários) se não existir.
# =====================================================================
set -uo pipefail

RPS="${RPS:-4}"
DURACAO="${DURACAO:-0}"   # 0 = infinito
FLAG="${FLAG:-nova-ui}"

URL="${URL:-https://$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')}"
KEY="${SERVICE_API_KEY:-$(kubectl get secret -n evaluation-service evaluation-secrets -o jsonpath='{.data.SERVICE_API_KEY}' | base64 -d)}"
[ -z "$KEY" ] && { echo "Não achei a SERVICE_API_KEY (Secret evaluation-secrets)."; exit 1; }

c() { curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$@"; }

echo "Alvo: $URL  |  ${RPS} req/s  |  flag: $FLAG"
# Cria flag e regra (409 = já existe, tudo bem)
c -X POST "$URL/flags/flags" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$FLAG\",\"description\":\"Fase 4 - demo\",\"is_enabled\":true}" >/dev/null
c -X POST "$URL/target/rules" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d "{\"flag_name\":\"$FLAG\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}" >/dev/null

inicio=$(date +%s); n=0; declare -A conta
trap 'echo; echo "Total: $n requisições"; for k in "${!conta[@]}"; do echo "  $k: ${conta[$k]}"; done; exit 0' INT TERM
while :; do
  for _ in $(seq 1 "$RPS"); do
    u="user-$((RANDOM % 500))"
    c "$URL/evaluation/evaluate?user_id=$u&flag_name=$FLAG" >/dev/null &
    s2=$(c "$URL/flags/flags/$FLAG" -H "Authorization: Bearer $KEY")
    wait
    conta["flags:$s2"]=$(( ${conta["flags:$s2"]:-0} + 1 )); n=$((n+2))
  done
  printf '\r%5d req | flags->auth: %s   ' "$n" "$(for k in "${!conta[@]}"; do printf '%s=%s ' "${k#flags:}" "${conta[$k]}"; done)"
  [ "$DURACAO" -gt 0 ] && [ $(( $(date +%s) - inicio )) -ge "$DURACAO" ] && break
  sleep 1
done
echo; echo "Fim: $n requisições."
