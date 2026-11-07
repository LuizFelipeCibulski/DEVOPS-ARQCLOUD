# ToggleMaster — Fase 4: Observabilidade Total e Resposta Ativa

Documento técnico **e** tutorial. A primeira metade explica *o que foi feito e
por quê* (embasamento para o vídeo e o relatório). A segunda é um passo a passo
para **replicar em qualquer cluster**.

> Base: a fase 3 (`techchallange3/`) foi copiada para `techchallange4/` e
> evoluída. Arquitetura geral, secrets, GitOps e ondas continuam valendo, e
> estão em [`ARQUITETURA.md`](ARQUITETURA.md). Aqui está só o que a fase 4 muda.

- [1. O problema e a resposta em uma tela](#1-o-problema-e-a-resposta-em-uma-tela)
- [2. Requisito do PDF → onde está](#2-requisito-do-pdf--onde-está)
- [3. Arquitetura OpenTelemetry](#3-arquitetura-opentelemetry)
- [4. Instrumentação dos 5 microsserviços](#4-instrumentação-dos-5-microsserviços)
- [5. Métricas, logs e o dashboard](#5-métricas-logs-e-o-dashboard)
- [6. APM: New Relic](#6-apm-new-relic)
- [7. Alertas, PagerDuty e Discord](#7-alertas-pagerduty-e-discord)
- [8. Self-healing (Runbook Automation)](#8-self-healing-runbook-automation)
- [9. Mudanças para rodar no AWS Academy](#9-mudanças-para-rodar-no-aws-academy)
- [10. Tutorial: do zero ao incidente auto-curado](#10-tutorial-do-zero-ao-incidente-auto-curado)
- [11. Roteiro do vídeo](#11-roteiro-do-vídeo-25-min)
- [12. Justificativas técnicas (relatório)](#12-justificativas-técnicas-para-o-relatório)
- [13. Armadilhas encontradas](#13-armadilhas-encontradas)
- [14. Limites conhecidos](#14-limites-conhecidos)

---

## 1. O problema e a resposta em uma tela

O cenário do PDF: o `evaluation-service` falhou silenciosamente, o HPA escalou
tentando compensar, e o time levou **6 h para ser avisado** e **4 h para achar a
causa** em logs espalhados pelos pods.

| Antes (fase 3) | Depois (fase 4) |
|---|---|
| `kubectl logs` pod a pod | Logs de **todos** os containers no Loki, com busca e filtro |
| Só a CPU do metrics-server | Prometheus: infra (nós, pods) + RED de cada serviço |
| Nenhum trace | Trace distribuído dos 5 serviços no New Relic, com Service Map |
| Usuário avisa o time | Alerta em 1 min → PagerDuty + Discord |
| Humano reinicia o pod | **Self-healer** reinicia sozinho e avisa o resultado |

```
                     ┌──────────── EKS (togglemaster-prod) ───────────────────────────┐
                     │                                                                │
  usuário ─HTTPS─▶ Traefik ─▶ evaluation ─▶ flag ─────▶ auth ─▶ RDS                   │
                     │          │  │  └──▶ targeting ─┘                               │
                     │          │  └─▶ Redis                                          │
                     │          └─▶ SQS ─▶ analytics ─▶ DynamoDB                      │
                     │             │ OTLP (traces+métricas)    stdout dos containers  │
                     │             ▼                                  │               │
                     │   ┌────────────────────────────┐               │               │
                     │   │ OTel Collector (DaemonSet) │◀── filelog ───┘               │
                     │   └──┬────────┬─────────┬──────┘                               │
                     │      │        │         │                                      │
                     │   métricas   logs     traces/logs das apps ──────────────────────▶ New Relic (APM)
                     │      ▼        ▼                                                │
                     │  Prometheus  Loki                                              │
                     │      └───┬────┘                                                │
                     │       Grafana ── alerta Firing ──┬──▶ PagerDuty (incidente)  ─────▶ celular do plantão
                     │                                  ├──▶ Discord (ChatOps)      ─────▶ canal do time
                     │                                  └──▶ self-healer ─PATCH─▶ Deployment (rollout restart)
                     └────────────────────────────────────────────────────────────────┘
```

---

## 2. Requisito do PDF → onde está

| Requisito | Implementação | Arquivos |
|---|---|---|
| **1. Prometheus** | kube-prometheus-stack via Argo CD; recebe remote-write do Collector | `kubernetes/argocd/apps/06-kube-prometheus-stack.yaml`, `kubernetes/observability/values/kube-prometheus-stack.yaml` |
| **1. Loki** | Loki 3 SingleBinary; ingestão OTLP nativa | `06-loki.yaml`, `values/loki.yaml` |
| **1. Grafana + dashboard** | Grafana do kps; dashboard como código (20 painéis) | `observability/config/dashboard-togglemaster.yaml`, `scripts/gerar-dashboard.py` |
| **2. OTel Collector** (obrigatório) | DaemonSet contrib: recebe OTLP + logs, roteia para Prometheus, Loki e New Relic | `07-otel-collector.yaml`, `values/otel-collector.yaml` |
| **3. APM** | New Relic via OTLP nativo | exporter `otlphttp/newrelic` no Collector |
| **3. Instrumentação do código** | Go: SDK OTel + otelhttp + otelsql + redisotel. Python: `opentelemetry-instrument` + libs | `docker/*/telemetry.go`, `docker/*/requirements.txt`, `docker/*/Dockerfile` |
| **3. Distributed Tracing** | contexto W3C via HTTP **e via SQS** (MessageAttributes) | `docker/evaluation-service/sqs.go`, `docker/analytics-service/app.py` |
| **3. Service Map** | 5 serviços conectados (+ Redis, Postgres, SQS) | consequência do item acima |
| **4. Alerta inteligente** | 5xx do auth > 5% por 1 min (+ 2 alertas warning) | `observability/config/alerting.yaml` |
| **4. PagerDuty** | contact point `pagerduty` (Events API v2) | idem |
| **4. ChatOps** | contact point Discord com template detalhado + mensagens do self-healer | idem + `docker/self-healer/app.py` |
| **4. Self-Healing** (obrigatório) | serviço in-cluster que recebe o webhook e faz rollout restart | `docker/self-healer/`, `kubernetes/self-healing/`, `.github/workflows/self-healer.yml` |
| Provocar o problema | `POST /admin/chaos` no auth-service (+ script) | `docker/auth-service/chaos.go`, `scripts/chaos.sh` |

---

## 3. Arquitetura OpenTelemetry

### 3.1 Por que um Collector no meio

Os serviços **não conhecem** Prometheus, Loki nem New Relic. Eles só falam
**OTLP** (o protocolo padrão do OpenTelemetry) com um endereço:
`otel-collector.observability.svc.cluster.local`. Isso traz:

- **Troca de backend sem rebuild.** Sair do New Relic para o Datadog é trocar um
  exporter no YAML do Collector. Nenhuma imagem muda.
- **Credencial num lugar só.** A license key do New Relic fica no Collector,
  não em cinco Deployments.
- **Processamento central.** Enriquecimento com metadados do Kubernetes,
  geração de métricas a partir de traces, filtros e batching.

### 3.2 DaemonSet, não Deployment

Um Collector **por nó**, por dois motivos:

1. **Logs.** O receiver `filelog` lê `/var/log/pods/*` do disco do nó. Só um
   DaemonSet enxerga os logs de **todos** os nós.
2. **Localidade.** O Service tem `internalTrafficPolicy: Local`, então cada pod
   envia OTLP para o Collector do **próprio** nó, sem salto de rede.

### 3.3 Os pipelines (o "roteamento" que o PDF pede para explicar)

```yaml
traces:          otlp ─▶ [memory_limiter, k8sattributes, resource, batch] ─▶ New Relic + spanmetrics
metrics:         otlp + spanmetrics ─▶ [...] ─▶ Prometheus (remote write) + New Relic
logs:            filelog ─▶ [..., service.name] ─▶ Loki (OTLP /otlp)
logs/newrelic:   filelog ─▶ [..., filter só namespaces das apps] ─▶ New Relic
```

| Peça | O que faz | Por que importa |
|---|---|---|
| `memory_limiter` | recusa dados antes de estourar memória | o Collector não toma OOMKill num pico |
| `k8sattributes` | descobre de qual pod veio cada dado (pelo IP de origem) e adiciona `k8s.namespace.name`, `k8s.pod.name`, `k8s.deployment.name`... | é o que permite filtrar logs por namespace no Loki |
| `resource/identity` | `service.instance.id` = UID do pod | evita série duplicada no Prometheus quando 3 Collectors exportam métricas do mesmo serviço |
| **`spanmetrics`** (connector) | transforma **traces em métricas** RED: `traces_span_metrics_calls_total` e `..._duration_seconds_bucket` com `service_name`, `span_kind`, `status_code`, `http_response_status_code` | Go e Python passam a ter **as mesmas métricas, com os mesmos rótulos**. O dashboard e o alerta usam uma única query para todos os serviços |
| `filter/apps-only` | só os logs das apps vão ao New Relic | protege a cota grátis; infra fica só no Loki |
| `prometheusremotewrite` | **empurra** métricas para o Prometheus (`/api/v1/write`) | o Prometheus não precisa descobrir e raspar cada pod |
| `otlphttp/loki` | Loki 3 aceita OTLP nativo | sem Promtail e sem agente extra |

> **Logs não vão por OTLP pelas apps**, de propósito: o Collector já coleta o
> stdout de todos os containers. Mandar pelos dois caminhos duplicaria cada
> linha. Os logs **passam pelo OTel do mesmo jeito**, só que entram pelo
> `filelog` e não pelo SDK.

---

## 4. Instrumentação dos 5 microsserviços

### 4.1 Go (auth-service, evaluation-service): SDK manual

`telemetry.go` (igual nos dois) configura:
- **TracerProvider** com exporter OTLP/gRPC em batch e sampler `ParentBased(AlwaysOn)`.
- **MeterProvider** com OTLP/gRPC a cada 15 s, mais métricas de runtime Go (goroutines, GC).
- **Propagador W3C** (`traceparent`): é ele que costura serviços diferentes no mesmo trace.
- Tudo configurado só por variáveis padrão (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`).
  Sem endpoint (dev local), a telemetria fica desligada.

Bibliotecas de instrumentação:

| Lib | Onde | Gera |
|---|---|---|
| `otelhttp.NewHandler` | servidor HTTP dos dois | span SERVER por requisição + `http.server.request.duration` |
| `otelhttp.NewTransport` | cliente HTTP do evaluation | span CLIENT + **injeta `traceparent`** nas chamadas a flag e targeting |
| `otelsql` | `database/sql` do auth | span por query no Postgres + métricas do pool |
| `redisotel` | go-redis do evaluation (migrado de v8 para **v9**) | span por GET/SET no cache |

Mudanças de código que a instrumentação exigiu (e por quê):
- **Propagar `context.Context`** (`getDecision(ctx, …)` → `fetchFlag(ctx, …)` →
  `http.NewRequestWithContext`). Sem o contexto, cada chamada de saída nascia
  num trace novo e o trace distribuído se partia.
- **`QueryRowContext`** no auth: a query vira **filha** do span HTTP.
- **Goroutine do SQS:** o contexto da requisição é cancelado quando o handler
  responde. A goroutine recebe `trace.ContextWithSpanContext(context.Background(), …)`,
  que carrega só a identidade do span, sem herdar o cancelamento.
- **Log com `trace_id`** (`logf`): cada linha de log traz o `trace_id`. No
  Grafana, o campo vira link para o trace no New Relic.
- **Graceful shutdown** (SIGTERM → `srv.Shutdown` → flush da telemetria): no
  rollout restart do self-healer, os últimos spans do pod antigo não se perdem.
- **`/validate` devolve 503 em erro de banco** (antes devolvia 401). Banco fora
  do ar não é "chave inválida". Precisa aparecer como 5xx para o alerta enxergar.

### 4.2 Python (flag, targeting, analytics): instrumentação automática

No Dockerfile, o processo sobe com:
```dockerfile
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
```
O `opentelemetry-instrument` aplica os patches **antes** de o gunicorn importar o
`app.py`: Flask (spans SERVER), requests (spans CLIENT + `traceparent` para o auth),
psycopg2 (spans de query), botocore (SQS/DynamoDB) e logging (`trace_id` no formato
do log). As libs estão pinadas uma a uma no `requirements.txt` (SDK `1.45.2` ↔
instrumentações `0.66b2`), e não via `opentelemetry-bootstrap`, para o build ser
reproduzível e o Trivy enxergar cada pacote.

Configuração por env (`kubernetes/<svc>/otel-configmap.yaml`): protocolo
`http/protobuf` (sem compilar grpcio no Alpine), `/health` excluído e semântica
HTTP estável (`http.response.status_code`, igual ao Go).

**Bug encontrado no teste:** os spans de banco do Python não apareciam. A
instrumentação do psycopg2 troca o `cursor_factory` da conexão, e o código
passava `cursor_factory=RealDictCursor` em cada cursor, sobrescrevendo esse.
Correção: o `RealDictCursor` foi para o pool (`SimpleConnectionPool(..., cursor_factory=RealDictCursor)`).

### 4.3 O trace atravessando a fila SQS

HTTP carrega o contexto no cabeçalho, mas mensagem SQS não tem cabeçalho. Sem
tratamento, o `analytics-service` apareceria solto, e o Service Map teria só
4 serviços conectados.

- **evaluation (`sqs.go`)**: cria um span **PRODUCER** `evaluation publish` e injeta
  `traceparent` nos **`MessageAttributes`** da mensagem.
- **analytics (`app.py`)**: pede `MessageAttributeNames=['All']`, extrai o
  contexto e abre um span **CONSUMER** `evaluation process` como filho. O
  `put_item` no DynamoDB e o `delete_message` (botocore) nascem dentro dele.
- O long-polling vazio a cada 20 s roda dentro de `suppress_instrumentation()`.
  Sem isso, viraria um trace inútil a cada ciclo.

Trace real validado localmente (o mesmo `trace_id` do começo ao fim):
```
[evaluation-service] GET /evaluate (SERVER)
  [evaluation-service] get (CLIENT)                       ← Redis
  [evaluation-service] HTTP GET (CLIENT)
    [targeting-service] GET /rules/<flag_name> (SERVER)
      [targeting-service] SELECT (CLIENT)                 ← Postgres
      [targeting-service] GET (CLIENT)
        [auth-service] GET /validate (SERVER)
          [auth-service] sql.conn.query (CLIENT)          ← Postgres
  [evaluation-service] HTTP GET (CLIENT)
    [flag-service] GET /flags/<name> (SERVER) ...
  [evaluation-service] set (CLIENT)                       ← Redis
  [evaluation-service] evaluation publish (PRODUCER)      ← SQS
    [analytics-service] evaluation process (CONSUMER)
      [analytics-service] DynamoDB.PutItem / SQS.DeleteMessage
```

---

## 5. Métricas, logs e o dashboard

**Prometheus** (kube-prometheus-stack): node-exporter (nós), kubelet/cAdvisor
(containers), kube-state-metrics (estado dos objetos K8s). As métricas das apps
chegam por **remote write** (`enableRemoteWriteReceiver: true`). Alertmanager
desligado: quem roteia alertas é o Grafana.

**Loki**: SingleBinary, schema `v13`/`tsdb` (exigido para OTLP). Atributos viram
labels: `k8s_namespace_name`, `service_name`, `k8s_pod_name`... Exemplos de busca:
```logql
{k8s_namespace_name="auth-service"} |= "ERRO"
{service_name="evaluation-service"} |= "trace_id=4bf92f35"
sum by (service_name) (count_over_time({k8s_namespace_name=~".+-service"} |~ "(?i)erro" [1m]))
```

**Dashboard "ToggleMaster - Saúde do Ecossistema"** (pasta ToggleMaster), gerado
por `scripts/gerar-dashboard.py`:

| Bloco | Painéis | Fonte |
|---|---|---|
| ☸️ Cluster | CPU/memória do cluster, nós prontos, pods, restarts, ações de self-healing, CPU/memória por serviço, réplicas (HPA/KEDA) | node-exporter, cAdvisor, kube-state-metrics, `self_healer_actions_total` |
| 🚦 RED | req/s, % de erro 5xx (linha em 5%), p95, respostas por status, % de 5xx do auth agora, produzidas × consumidas no SQS | `traces_span_metrics_*` (spanmetrics) |
| 📜 Logs | erros por serviço ao longo do tempo + painel de logs ao vivo, com variáveis `namespace` e `busca` | Loki |

Dashboard, datasources e alertas são **ConfigMaps** com label (`grafana_dashboard`,
`grafana_alert`), lidos pelos *sidecars* do Grafana. Nada é clicado na UI: está
tudo no git e é aplicado pelo Argo CD.

---

## 6. APM: New Relic

O Collector exporta para `https://otlp.nr-data.net` com o header
`api-key: <license key>`. A key vem do Secrets Manager via ExternalSecret, como
variável de ambiente opcional: o Collector sobe mesmo sem ela, e só o export
para o New Relic falha até a key ser cadastrada.

No New Relic:
- **APM & Services**: as 5 entidades (+ `self-healer`), criadas automaticamente pelo `service.name`.
- **Service Map**: arestas inferidas das relações pai/filho entre spans.
- **Distributed Tracing**: o trace completo do item 4.3.
- **Logs in context**: os logs das apps chegam com `trace_id` e aparecem ao lado do trace.

---

## 7. Alertas, PagerDuty e Discord

Tudo em `kubernetes/observability/config/alerting.yaml`:

**Regras** (avaliadas a cada 30 s):

| Alerta | Expressão (resumida) | `for` | Severidade → destino |
|---|---|---|---|
| auth-service 5xx > 5% | `rate(5xx)/rate(total)` do spanmetrics, janela 2m | 1m | **critical** → self-healer + PagerDuty + Discord |
| evaluation p95 > 1s | `histogram_quantile(0.95, ...)` | 5m | warning → Discord |
| Restarts > 3 em 15m | `increase(kube_pod_container_status_restarts_total)` | 2m | warning → Discord |

**Contra alert fatigue** (tema da disciplina):
- `for: 1m`: um pico isolado não abre incidente.
- `or vector(0)` + `noDataState: OK`: sem tráfego não é incidente, e ninguém é acordado de madrugada por isso.
- **Roteamento por severidade**: só `critical` vai ao PagerDuty; `warning` fica no Discord.
- `group_by: [alertname, service]`: 50 pods falhando juntos geram 1 notificação.
- `repeat_interval: 4h`: não repete a cada minuto.

**Árvore de notificação**: rota 1 `remediation=rollout-restart` → webhook do
self-healer (`continue: true`). Rota 2 `severity=critical` → PagerDuty
(`continue: true`). Rota 3 `team=togglemaster` → Discord.

**PagerDuty**: Events API v2. O *firing* abre o incidente (trigger), e o
*resolved* **fecha o mesmo incidente**, porque o Grafana usa o fingerprint do grupo como `dedup_key`.

**Discord**: template próprio com status, serviço, severidade, valor medido,
impacto, horário, ação de self-healing e link do runbook. O self-healer manda
mais duas mensagens: "ação executada" (com os pods antigos) e "rollout concluído"
(com os pods novos).

**Tokens**: `${PAGERDUTY_ROUTING_KEY}`, `${DISCORD_WEBHOOK_URL}` e
`${SELF_HEALER_TOKEN}` são interpolados pelo Grafana a partir de variáveis de
ambiente (Secret do ESO). Atenção: por isso um `$` literal dentro de template
precisa ser escrito `$$`.

---

## 8. Self-healing (Runbook Automation)

Das opções do PDF (Runbook Automation, Lambda, GitHub Action via webhook), foi
escolhido um **serviço in-cluster** (`self-healer`):

| | self-healer in-cluster | GitHub Action via webhook | AWS Lambda |
|---|---|---|---|
| Latência até agir | ~1 s | 20–60 s (fila do runner) | segundos |
| Credencial para o cluster | ServiceAccount (token efêmero, RBAC) | kubeconfig + chave AWS **no GitHub** (no Academy expira a cada sessão) | role IAM (proibido criar no Academy) + acesso à API do EKS |
| Funciona se a internet/GitHub cair | sim | não | sim |

**Fluxo** (`docker/self-healer/app.py`):
1. `POST /webhook/grafana` com `Authorization: Bearer <token>`, comparado com `hmac.compare_digest`.
2. Para cada alerta `firing` com `remediation=rollout-restart`, lê os labels `namespace` e `deployment`.
3. **Allowlist** (`ALLOWED_TARGETS`): um alerta não consegue mandar reiniciar qualquer coisa.
4. **Cooldown** de 300 s por alvo: sem loop de restart. Se não resolveu, o humano (PagerDuty) assume.
5. **PATCH** `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]`,
   que é **exatamente** o que o `kubectl rollout restart` faz: o Deployment cria um
   ReplicaSet novo e troca os pods em rolling update, sem downtime.
6. Thread em segundo plano acompanha o rollout (equivalente a `kubectl rollout status`)
   e avisa no Discord.
7. Métrica `self_healer_actions_total{target,result}` e trace `runbook rollout-restart`.

**Menor privilégio em 3 camadas**: ClusterRole só `get/list/patch deployments` e
`get/list pods` (sem delete e sem secrets) → vale só onde há RoleBinding (os 5
namespaces das apps) → allowlist no app. O container roda não-root, com root
filesystem read-only e sem capabilities.

**Como provocar a falha** (`chaos.go`): `POST /admin/chaos {"error_rate":0.5}`
(protegido pela MASTER_KEY) faz o auth responder 500 em metade das requisições.
O estado fica **só na memória**, simulando um processo degradado: é a classe de
falha que um restart realmente cura, então a demonstração fecha o ciclo
(alerta → restart → erro some → alerta resolve). `/health` não é afetado, então
o Kubernetes **sozinho não perceberia nada**. É a "falha silenciosa" do enunciado.

---

## 9. Mudanças para rodar no AWS Academy

A fase 3 rodou em conta normal com IRSA. No Academy, `iam:CreateRole` é negado
(testado: `AccessDenied`). Ajustes:

| Fase 3 (conta normal) | Fase 4 (Academy) | Onde |
|---|---|---|
| 5 roles IRSA + provider OIDC | sem IRSA: pods usam a **LabRole do nó via IMDS** | `iac/main.tf` (`app_stack_enabled` × `app_secrets_enabled`) |
| Secrets Manager dependia do IRSA | **desacoplado**: cofres existem nos dois modos | `iac/main.tf` |
| SAs anotadas com `eks.amazonaws.com/role-arn` | **anotação removida**. Uma role inexistente quebraria o SDK, que não cai para o nó | `kubernetes/*/serviceaccount.yaml` |
| `ClusterSecretStore` com `auth.jwt` | sem bloco `auth` (cadeia padrão do SDK) | `kubernetes/external-secrets/` |
| GitHub → AWS por OIDC | chaves temporárias do Lab + `AWS_MODE=academy` | `.github/workflows/*.yml`, `update-secrets-aws.sh` |
| 2× t3.medium (17 pods/nó) | **3× t3.large** (35 pods/nó): a stack passa de 60 pods | `iac/variables.tf` |
| IMDS hop limit 1 (padrão do AL2023) | **launch template com hop limit 2**: sem isso nenhum pod alcança a LabRole | `iac/modules/eks/main.tf` |
| — | ECR `self-healer` + cofre `togglemaster/prod/observability` | `iac/variables.tf`, `iac/modules/app-secrets` |

Em conta normal, `is_academy = false` em `prod.auto.tfvars` volta a criar o IRSA.
Só seria preciso devolver as anotações nas ServiceAccounts.

---

## 10. Tutorial: do zero ao incidente auto-curado

> Para replicar em outro cluster ou conta. Comandos a partir da raiz do repositório.

### 10.1 Pré-requisitos
`aws` (logado), `tofu` 1.11+, `kubectl`, `helm`, `gh` (logado), `jq`, `openssl`.
Contas: New Relic (free), PagerDuty (free), um servidor Discord seu.

### 10.2 Infraestrutura (Terraform/OpenTofu)
```bash
cd techchallange4/iac
./bootstrap-backend.sh                  # bucket S3 + lock DynamoDB do state (uma vez por conta)
echo "public_access_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]" > terraform.tfvars
tofu init
tofu apply                              # ~20 min
aws eks update-kubeconfig --region us-east-1 --name togglemaster-prod
kubectl get nodes                       # 3 nós Ready
cd ../..
```

### 10.3 Contas externas → Secrets Manager
1. **New Relic**: canto inferior esquerdo → *API Keys* → **INGEST - LICENSE** → copiar.
2. **PagerDuty**: *Services* → *New Service* ("ToggleMaster") → em *Integrations*
   escolher **Events API V2** → copiar a **Integration Key** (32 caracteres).
3. **Discord**: no canal → ⚙️ *Editar canal* → *Integrações* → *Webhooks* →
   *Novo webhook* → **Copiar URL**.
```bash
./techchallange4/scripts/set-observability-secrets.sh     # pede os 3 valores (entrada oculta)
```
O script também gera a senha do Grafana e o token do self-healer.

### 10.4 CI/CD no modo Academy
```bash
# Lab -> AWS Details -> AWS CLI -> Show -> colar num arquivo
./techchallange4/update-secrets-aws.sh creds.txt    # grava as 3 chaves + AWS_MODE=academy
gh variable set EKS_PUBLIC_ACCESS_CIDRS --body "[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
git push origin main          # 6 pipelines: build, lint, SAST, SCA, Trivy, push ECR, commit da tag
```
> As chaves do Lab expiram a cada sessão. Pipeline falhando com `ExpiredToken`? Rode o script de novo.

### 10.5 Traefik e Argo CD (o que não pode ser GitOps)
```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  -f techchallange4/kubernetes/traefik/values.yaml --wait

kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.rootpath":"/argocd"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl apply -f techchallange4/kubernetes/argocd/ingressroute.yaml
```

### 10.6 GitOps: uma linha sobe tudo
```bash
kubectl apply -f techchallange4/kubernetes/argocd/apps/root.yaml
kubectl get applications -n argocd -w
# depois que os namespaces das apps existirem: rotas públicas e strip-prefix
kubectl apply -f techchallange4/kubernetes/traefik/middleware.yaml -f techchallange4/kubernetes/traefik/ingressroute.yaml
```
Ondas: `-20` ESO/KEDA → `-10` ClusterSecretStore → `-8` config da observabilidade
→ `-6` Prometheus/Grafana e Loki → `-5` OTel Collector → `20` auth → `30` flag/targeting
→ `40` evaluation/analytics → `50` self-healer.

### 10.7 Verificação
```bash
ELB=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana: https://$ELB/grafana   Argo CD: https://$ELB/argocd"
kubectl get pods -n observability                # kps-*, loki-0, otel-collector-agent-* (1 por nó)
kubectl get externalsecret -A                    # todos SecretSynced
./techchallange4/scripts/gerar-trafego.sh        # deixe rodando
```
No Grafana: *Dashboards → ToggleMaster → Saúde do Ecossistema*. Em *Alerting →
Contact points*, use **Test** em cada um: chega no Discord e abre incidente no PagerDuty.

### 10.8 A prova real
```bash
# terminal 1
./techchallange4/scripts/gerar-trafego.sh
# terminal 2
kubectl get pods -n auth-service -w
# terminal 3
./techchallange4/scripts/chaos.sh on 0.5
kubectl logs -n self-healing deploy/self-healer -f
```
Linha do tempo esperada: **~1 min** com 5xx > 5% → *Pending* → *Firing* no Grafana
→ incidente no PagerDuty + mensagem no Discord → self-healer loga `SELF-HEALING`
→ pod novo nasce e o antigo termina (terminal 2) → Discord "Rollout concluído"
→ 5xx cai para 0 → alerta *Normal*, incidente resolvido no PagerDuty.

### 10.9 Checklist para outro cluster
- [ ] Trocar `198518420325` (conta) nos manifests: `grep -rn 198518420325 techchallange4/kubernetes`
- [ ] Trocar o `repoURL` das Applications se o repositório for outro
- [ ] Conta normal? `is_academy=false` + devolver as anotações IRSA
- [ ] Conta EU no New Relic? endpoint `https://otlp.eu01.nr-data.net`
- [ ] Rodar `set-observability-secrets.sh` na conta nova

---

## 11. Roteiro do vídeo (≤ 25 min)

| Tempo | Mostrar | Comando / tela |
|---|---|---|
| 0–3 | **Visão geral**: EKS via IaC e Argo CD com a stack nova | `kubectl get nodes`; UI do Argo CD com as 14 Applications *Synced/Healthy* (mostrar as ondas) |
| 3–5 | Código: instrumentação e o Collector | `telemetry.go`, `sqs.go`, Dockerfile Python, `values/otel-collector.yaml` (pipelines) |
| 5–10 | **Grafana**: dashboard + Loki + explicar o roteamento do OTel | dashboard rodando com o `gerar-trafego.sh`; *Explore → Loki*: `{k8s_namespace_name="auth-service"}`; desenho da seção 3.3 |
| 10–15 | **New Relic**: Service Map + trace distribuído | APM → Service Map (5 serviços); fazer 1 `curl` no `/evaluation/evaluate` e abrir o trace com os spans de Redis, Postgres e SQS → analytics |
| 15–23 | **A prova real** (seção 10.8) | 4 janelas: Grafana Alerting, terminal com `-w`, Discord, PagerDuty |
| 23–25 | Fechamento: alert fatigue, segurança do self-healer, limites | seções 7 e 8 |

**Prints para o relatório:** dashboard; um trace distribuído no New Relic;
mensagem no Discord; incidente no PagerDuty; log do self-healer
(`kubectl logs -n self-healing deploy/self-healer`) + Discord "Rollout concluído".

---

## 12. Justificativas técnicas (para o relatório)

**Arquitetura OTel:** Collector como gateway único, em DaemonSet. Os serviços
falam só OTLP, e o Collector enriquece (k8sattributes), deriva métricas RED de
traces (spanmetrics) e roteia: métricas → Prometheus, logs → Loki, traces/logs/métricas
das apps → New Relic. O resultado é vendor-neutral: trocar de APM é mudar um exporter.

**New Relic × Datadog:** New Relic.
1. **Ingestão OTLP nativa** (`otlp.nr-data.net`): o Collector usa o exporter
   `otlphttp` padrão, sem exporter proprietário.
2. **Free tier permanente** (100 GB/mês, 1 usuário full) contra trial de 14 dias
   do Datadog, que expiraria no meio do projeto.
3. Service Map e Distributed Tracing incluídos no free.

O Datadog teria vantagem em integrações de infra prontas (agent), mas aqui a
infra já é coberta por Prometheus/Grafana.

**PagerDuty × OpsGenie:** PagerDuty. A Atlassian **encerrou a venda do OpsGenie**
(migração para o Jira Service Management), então não faz sentido adotar hoje. O
PagerDuty tem plano free, integração **nativa** no Grafana e resolução automática do
incidente pelo `dedup_key` quando o alerta volta ao normal.

**Self-healing in-cluster** em vez de GitHub Action/Lambda: ver tabela da seção 8.
Resumo: menor latência e nenhuma credencial fora do cluster. Também é a única
opção que não depende de IAM role (proibida no Academy).

---

## 13. Armadilhas encontradas

| Sintoma | Causa | Correção |
|---|---|---|
| Spans de banco sumiam no Python | `cursor_factory` por cursor sobrescreve o da instrumentação | `RealDictCursor` no pool |
| Trace "quebrado" no evaluation | chamadas sem `context.Context` | `NewRequestWithContext` + ctx propagado |
| analytics solto no Service Map | SQS não tem cabeçalho | `traceparent` em `MessageAttributes` + span CONSUMER |
| Banco fora → auth respondia 401 | todo erro virava "chave inválida" | `sql.ErrNoRows` → 401, demais → 503 |
| Trivy bloqueando Go | `x/net` antigo (transitivo do gRPC/OTel) e Go 1.26.8 | `go get golang.org/x/net@latest`; CI usa a imagem `golang:1.26` atual |
| Chart do Collector renomeia componentes | versões novas usam `k8s_attributes`, `otlp_http`, `file_log` | normal: o chart traduz os nomes antigos |
| `$` some do template de alerta | Grafana interpola env vars no provisionamento | `$$values` |
| (Academy) role IRSA inexistente | anotação na SA faz o SDK tentar a role e não cair no nó | remover a anotação |
| (Academy) `ClusterSecretStore` em `InvalidProviderConfig`: *"no EC2 IMDS role found ... context deadline exceeded"* | AL2023 sobe com IMDSv2 **hop limit 1**: o pod está 1 salto além do host e a resposta é descartada | launch template com `http_put_response_hop_limit = 2` (mantendo `http_tokens = required`) |
| Trivy reprovou urllib3/gunicorn no CI, mas passou local horas antes | CVE nova publicada no meio do dia; `requirements.txt` herdados em CRLF faziam o `sed` não casar | subir versões + normalizar para LF. Gate de CVE é "vivo": o mesmo código pode reprovar amanhã |

---

## 14. Limites conhecidos

1. **Sem volume persistente** (o Academy não tem EBS CSI com IRSA): Prometheus, Loki
   e Grafana usam `emptyDir`. Se o pod for recriado, perde o histórico (o dashboard e
   os alertas voltam, porque são código).
2. **Chaves do Lab expiram**: os pipelines precisam do `update-secrets-aws.sh` a cada sessão.
3. **LabRole no nó** é mais ampla que o IRSA: com hop limit 2, qualquer pod alcança as permissões dela. É o preço de não haver IRSA no Academy; em conta normal o launch template volta a hop limit 1 sozinho (`is_academy = false`) e o IRSA assume.
4. **Sampling 100%**: adequado ao volume do desafio; em produção use `OTEL_TRACES_SAMPLER=parentbased_traceidratio` ou tail sampling no Collector.
5. **Cooldown em memória** no self-healer: com mais de 1 réplica, precisaria de estado compartilhado (lease/ConfigMap).
