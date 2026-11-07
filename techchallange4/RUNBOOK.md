# Runbooks — ToggleMaster

Os alertas do Grafana apontam para cá (`runbook_url`). Cada runbook diz **o que
a automação já fez sozinha** e **o que o humano faz se ela não resolver**.

---

## auth-service-5xx

**Alerta:** `auth-service - taxa de erros 5xx acima de 5%` · severidade `critical`

**Impacto:** o `flag-service` e o `targeting-service` validam toda requisição no
`/validate` do auth. Com ele falhando, o `evaluation-service` não consegue
avaliar flags: o produto inteiro para.

**O que já aconteceu automaticamente**

1. O Grafana abriu um incidente no **PagerDuty** e notificou o **Discord**.
2. O **self-healer** executou `kubectl rollout restart deployment/auth-service -n auth-service`
   e postou no Discord os pods antes e depois.
3. Cooldown de 5 minutos: a automação **não** reinicia de novo nesse intervalo.

**Se o alerta continuar Firing depois do restart** (a causa não está no processo):

```bash
# 1. Logs com erro (Grafana > Explore > Loki)
{k8s_namespace_name="auth-service"} |~ "ERRO"

# 2. O banco está de pé?
aws rds describe-db-instances --query "DBInstances[?contains(DBInstanceIdentifier,'auth')].DBInstanceStatus"

# 3. Algum trace com erro no New Relic: APM > auth-service > Errors inbox

# 4. Falha injetada esquecida ligada?
./techchallange4/scripts/chaos.sh status
```

Resolveu? O alerta volta a `Normal` e o PagerDuty fecha o incidente sozinho
(resolve pelo mesmo `dedup_key`).

---

## evaluation-latencia

**Alerta:** `evaluation-service - latência p95 acima de 1s` · `warning` (só Discord)

1. New Relic → APM → `evaluation-service` → Transactions → abra o trace mais lento.
2. Veja qual span domina: `get`/`set` (Redis), `HTTP GET` → flag/targeting, ou `evaluation publish` (SQS).
3. Se for Redis: `kubectl logs -n evaluation-service deploy/evaluation-service | grep -i redis`.
4. Se for flag/targeting: siga o trace até o serviço, e de lá até o `auth-service`.

---

## crashloop

**Alerta:** `Microsserviço reiniciando repetidamente` · `warning`

```bash
kubectl get pods -A | grep -E 'CrashLoop|Error'
kubectl describe pod -n <ns> <pod>          # Events no final: OOMKilled? probe?
kubectl logs -n <ns> <pod> --previous       # log da execução que morreu
```

Causas que já aconteceram neste projeto: Secret do ESO ainda não materializado
(`CreateContainerConfigError`), banco sem tabela (ver `db-migration.yaml`) e Redis
sem TLS (`rediss://`).
