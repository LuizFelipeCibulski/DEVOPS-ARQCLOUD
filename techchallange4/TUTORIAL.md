# Tutorial — Observabilidade e Resposta Ativa no ToggleMaster (Fase 4)

Este é o guia de **aprendizado**: o que foi feito, **na ordem em que foi feito**,
com o porquê de cada decisão e como verificar cada passo. A referência técnica
compacta (tabelas, roteiro do vídeo, justificativas) está em [`FASE4.md`](FASE4.md).

Objetivo: depois de ler, você consegue montar isso do zero em outro cluster
**e explicar cada peça** no vídeo.

**Resultado validado em 07/11/2026**, falha injetada no auth-service:

```
17:08:14  chaos ligado (50% de HTTP 500)                         t = 0
17:09:02  alerta PENDING  (5xx > 5%, esperando o "for: 1m")      t = 48 s
17:09:58  alerta FIRING → PagerDuty + Discord + self-healer      t = 1m44s
17:10:13  pod novo pronto, pod doente removido                   t = 1m59s
17:12:32  alerta NORMAL, incidente resolvido sozinho             t = 4m18s
```
Do problema à cura: **~4 minutos e nenhum humano**. O PDF partiu de "6 h para
ser avisado + 4 h para achar a causa".

---

## Sumário

- [Parte 0 — O mapa mental](#parte-0--o-mapa-mental)
- [Parte 1 — Conhecer o terreno antes de construir](#parte-1--conhecer-o-terreno-antes-de-construir)
- [Parte 2 — Infraestrutura (OpenTofu)](#parte-2--infraestrutura-opentofu)
- [Parte 3 — Instrumentar o código](#parte-3--instrumentar-o-código)
- [Parte 4 — Testar a instrumentação localmente](#parte-4--testar-a-instrumentação-localmente)
- [Parte 5 — O OTel Collector, peça por peça](#parte-5--o-otel-collector-peça-por-peça)
- [Parte 6 — Backends: Prometheus, Loki e Grafana](#parte-6--backends-prometheus-loki-e-grafana)
- [Parte 7 — Dashboard como código](#parte-7--dashboard-como-código)
- [Parte 8 — Alertas inteligentes](#parte-8--alertas-inteligentes)
- [Parte 9 — PagerDuty, Discord e New Relic](#parte-9--pagerduty-discord-e-new-relic)
- [Parte 10 — O self-healer](#parte-10--o-self-healer)
- [Parte 11 — Ligando tudo no GitOps](#parte-11--ligando-tudo-no-gitops)
- [Parte 12 — CI/CD no modo Academy](#parte-12--cicd-no-modo-academy)
- [Parte 13 — A execução real, comando a comando](#parte-13--a-execução-real-comando-a-comando)
- [Parte 14 — Depuração: os 7 problemas reais e como foram achados](#parte-14--depuração-os-7-problemas-reais-e-como-foram-achados)
- [Parte 15 — Exercícios para fixar](#parte-15--exercícios-para-fixar)
- [Glossário](#glossário)

---

## Parte 0 — O mapa mental

### Os três pilares + resposta

| Pergunta | Sinal | Ferramenta aqui |
|---|---|---|
| **Está quebrado?** Quanto? | Métricas (números no tempo) | Prometheus |
| **Por que** quebrou? | Logs (eventos em texto) | Loki |
| **Onde** quebrou, no caminho entre serviços? | Traces (a viagem de uma requisição) | New Relic (APM) |
| **Quem** precisa saber? | Alerta | Grafana → PagerDuty + Discord |
| **O que fazer** sem esperar humano? | Automação | self-healer |

### A ideia que organiza tudo: separar quem *produz* de quem *guarda*

```
 PRODUZEM (apps)            TRANSPORTAM (OTel Collector)        GUARDAM / MOSTRAM
 ─────────────────          ───────────────────────────         ──────────────────
 SDK OpenTelemetry  ──OTLP──▶ recebe → enriquece → roteia ──▶   Prometheus (métricas)
 stdout dos pods    ─arquivo─▶                              ──▶ Loki (logs)
                                                            ──▶ New Relic (traces, APM)
```

As aplicações **só falam OTLP** (o protocolo padrão do OpenTelemetry) com **um**
endereço. Não sabem que o Prometheus, o Loki ou o New Relic existem. Isso é a
"padronização" que o PDF pede: trocar de New Relic para Datadog amanhã é mudar
um bloco de YAML no Collector, sem rebuild de nenhuma imagem.

### O que já existia (fase 3) e foi reaproveitado

EKS via OpenTofu, 5 microsserviços, Argo CD com app-of-apps e *sync waves*,
External Secrets Operator lendo do AWS Secrets Manager e pipelines DevSecOps com
Trivy. A fase 4 é uma **camada em cima**. Por isso o primeiro passo foi copiar
`techchallange3/` para `techchallange4/` e apontar pipelines e Argo CD para a
pasta nova, deixando a entrega da fase 3 intacta.

---

## Parte 1 — Conhecer o terreno antes de construir

Antes de escrever uma linha, três verificações mudaram o projeto inteiro.

### 1.1 A conta permite criar IAM role?

```bash
aws sts get-caller-identity                 # ...assumed-role/voclabs/... → é Academy
aws iam create-role --role-name teste ...   # AccessDenied
aws eks list-clusters                       # [] → conta vazia, subir tudo do zero
```

**Consequência:** sem IAM role não há **IRSA** (a forma de dar a cada pod a
própria identidade AWS). No Academy, a única credencial disponível é a
**LabRole**, presa ao nó EC2. Os pods precisam alcançá-la pelo **IMDS** (o
serviço de metadados em `169.254.169.254`). Guarde isso: volta na Parte 14.

### 1.2 O cluster aguenta a stack nova?

Cada t3.medium aceita só **17 pods** (limite de IPs da VPC CNI). Contando
Argo CD (7), ESO (3), KEDA (3), Traefik, 5 apps, jobs, Prometheus, Grafana,
kube-state-metrics, node-exporter (×nós), Loki e Collector (×nós), passa de 60.
Solução: **3× t3.large** (35 pods por nó, 8 GiB).

> **Lição:** antes de instalar algo no Kubernetes, conte **pods**, não só CPU/RAM.
> `kubectl describe node | grep -A5 Allocatable` mostra o limite `pods:`.

### 1.3 Quais ferramentas e versões?

```bash
helm search repo prometheus-community/kube-prometheus-stack   # 93.0.0
helm search repo grafana/loki                                 # 7.5.0
helm search repo open-telemetry/opentelemetry-collector       # 0.178.2
```

Versões **sempre fixadas** (`targetRevision`) no Argo CD: um chart que muda
sozinho é um deploy que ninguém aprovou.

---

## Parte 2 — Infraestrutura (OpenTofu)

### 2.1 Desacoplar "secrets" de "IRSA"

Na fase 3, uma única chave ligava Secrets Manager **e** IRSA juntos. No Academy
isso desligava os dois, e sem Secrets Manager o ESO não tem de onde ler.

```hcl
# techchallange4/iac/main.tf
locals {
  app_secrets_enabled = var.manage_eks_cluster && var.enable_app_platform  # cofres: sempre
  app_stack_enabled   = local.app_secrets_enabled && !var.is_academy       # IRSA: só conta normal
}
```

**Por quê:** são preocupações diferentes. Onde o segredo **mora** (cofre) não
depende de **como** o pod se autentica (IRSA ou nó).

### 2.2 O cofre de observabilidade (vazio de propósito)

```hcl
# iac/modules/app-secrets/main.tf
resource "aws_secretsmanager_secret" "observability" {
  name = "${var.name_prefix}/observability"   # togglemaster/prod/observability
}
# SEM aws_secretsmanager_secret_version
```

O Terraform cria só o **container**. Os valores (tokens do New Relic, PagerDuty
e Discord) vêm de contas pessoais. Se passassem pelo Terraform, ficariam em
texto puro no **tfstate**. Quem preenche é o `scripts/set-observability-secrets.sh`.
É o mesmo padrão que a fase 3 já usava para a `SERVICE_API_KEY`.

### 2.3 Repositório ECR para o self-healer

Adicionado `"self-healer"` à lista `microservices`: a automação é uma imagem
nossa e passa pelo **mesmo pipeline DevSecOps** dos outros serviços.

### 2.4 Nós maiores e o launch template (IMDS)

```hcl
resource "aws_launch_template" "nodes" {
  metadata_options {
    http_tokens                 = "required"                 # IMDSv2 obrigatório
    http_put_response_hop_limit = var.is_academy ? 2 : 1     # ← o detalhe crucial
  }
}
resource "aws_eks_node_group" "this" {
  node_group_name_prefix = "${var.cluster_name}-ng-"
  launch_template { id = aws_launch_template.nodes.id, version = aws_launch_template.nodes.latest_version }
  lifecycle { create_before_destroy = true }
}
```

O **hop limit** é quantos "saltos de rede" a resposta do IMDS pode atravessar.
Com 1, só o próprio host recebe. O pod fica **um salto além** (interface virtual
→ host), então a resposta morre no caminho. Com 2, o pod alcança.

`name_prefix` + `create_before_destroy`: trocar o launch template **substitui**
o node group. Do jeito padrão, o Terraform destruiria os nós antes de criar os
novos, e o cluster ficaria ~10 min sem nó. Assim, os novos sobem primeiro e os
pods migram.

> Como confirmar que o plano é seguro: `tofu plan` deve dizer
> **"create replacement and then destroy"**, não "destroy and then create replacement".

### 2.5 Backend e execução

```bash
cd techchallange4/iac
./bootstrap-backend.sh        # bucket S3 com sufixo = ID da conta (nome globalmente único)
echo "public_access_cidrs = [\"$(curl -s https://checkip.amazonaws.com)/32\"]" > terraform.tfvars
tofu init && tofu plan        # 60 recursos
tofu apply                    # ~20 min
aws eks update-kubeconfig --region us-east-1 --name togglemaster-prod
```

---

## Parte 3 — Instrumentar o código

"Instrumentar" = fazer o código **emitir** traces e métricas. Existem dois
estilos, e o projeto usa os dois, porque são duas linguagens.

### 3.1 Go: instrumentação manual (auth-service, evaluation-service)

Go é compilado e não dá para "injetar" código depois. Então se escreve.

**Passo 1: o arquivo de setup** (`docker/auth-service/telemetry.go`). Em ordem:

```go
// (a) Propagador: COMO o contexto viaja entre serviços (cabeçalho W3C "traceparent")
otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{}, propagation.Baggage{}))

// (b) Sem endpoint configurado (dev local) → desliga, em vez de logar erro eterno
if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" { return noop }

// (c) Resource: QUEM está emitindo (service.name etc., lidos das env OTEL_*)
res, _ := resource.New(ctx, resource.WithFromEnv(), resource.WithTelemetrySDK(), resource.WithHost())

// (d) Traces: exporter OTLP/gRPC + envio em lote, fora do caminho da requisição
traceExp, _ := otlptracegrpc.New(ctx)
tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(traceExp), sdktrace.WithResource(res),
    sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())))
otel.SetTracerProvider(tp)

// (e) Métricas: mesmo esquema, a cada 15 s, + métricas do runtime Go
```

Repare que **nenhum endereço está no código**. Tudo vem de variáveis padrão da
especificação (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`), definidas no
ConfigMap `kubernetes/<svc>/otel-configmap.yaml`.

**Passo 2: embrulhar as bordas.** Cada lugar por onde a requisição entra ou sai
ganha um "embrulho" que cria spans:

| Borda | Código | O que ganha |
|---|---|---|
| HTTP entrando | `otelhttp.NewHandler(mux, ...)` | span SERVER por requisição + lê o `traceparent` de quem chamou |
| HTTP saindo | `&http.Client{Transport: otelhttp.NewTransport(...)}` | span CLIENT + **escreve** o `traceparent` |
| Postgres | `otelsql.Open("pgx", url, ...)` | span por query |
| Redis | `redisotel.InstrumentTracing(rdb)` (go-redis migrado para **v9**) | span por GET/SET |

**Passo 3: propagar o `context.Context`.** Esse é o passo que mais se esquece.
O span ativo mora **dentro** do `ctx`. Se uma função cria uma requisição sem o
`ctx` de quem a chamou, o embrulho não sabe a que trace pertence e começa um
novo. O trace "quebra".

```go
// ANTES (fase 3)                         // DEPOIS (fase 4)
func (a *App) fetchFlag(name string)      func (a *App) fetchFlag(ctx context.Context, name string)
http.NewRequest(GET, url, nil)            http.NewRequestWithContext(ctx, GET, url, nil)
a.DB.QueryRow(sql, ...)                   a.DB.QueryRowContext(r.Context(), sql, ...)
```

**Passo 4: a goroutine assíncrona.** O evaluation responde ao cliente e **depois**
publica no SQS numa goroutine. Só que o `r.Context()` é **cancelado** quando o
handler retorna. Solução: um contexto novo que carrega só a **identidade** do span:

```go
asyncCtx := trace.ContextWithSpanContext(context.Background(), span.SpanContext())
go a.sendEvaluationEvent(asyncCtx, userID, flagName, result)
```

**Passo 5: log com trace_id** (`logf`). Cada linha sai com
`trace_id=... span_id=...`. É a ponte entre o pilar "logs" e o pilar "traces".

**Passo 6: encerramento gracioso.** Ao receber SIGTERM (que é o que o rollout
restart manda), o servidor termina as requisições em voo e faz **flush** dos
spans do buffer. Sem isso, os últimos traces do pod doente, justamente os mais
interessantes, se perderiam.

### 3.2 Python: instrumentação automática (flag, targeting, analytics)

Python é interpretado e permite *monkey patching*: trocar funções de bibliotecas
em tempo de execução. O pacote `opentelemetry-instrument` faz isso **antes** de
importar o seu código:

```dockerfile
# ANTES: CMD ["gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
```

E no `requirements.txt`, uma lib por coisa a instrumentar:

```
opentelemetry-distro==0.66b2                 # o comando opentelemetry-instrument
opentelemetry-sdk==1.45.2                    # SDK  ┐ publicados em par:
opentelemetry-exporter-otlp-proto-http==1.45.2  #   ┘ 1.45.x ↔ 0.66bX
opentelemetry-instrumentation-flask==0.66b2     # spans SERVER
opentelemetry-instrumentation-requests==0.66b2  # spans CLIENT + traceparent → auth
opentelemetry-instrumentation-psycopg2==0.66b2  # spans de query
opentelemetry-instrumentation-logging==0.66b2   # trace_id no formato do log
```

Configuração só por env (`otel-configmap.yaml`):

| Variável | Por quê |
|---|---|
| `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` | exporter puro Python, sem compilar `grpcio` no Alpine |
| `OTEL_LOGS_EXPORTER=none` | logs já vão pelo arquivo (Parte 5); evita duplicar |
| `OTEL_PYTHON_LOG_CORRELATION=true` | injeta `trace_id=` no log |
| `OTEL_PYTHON_FLASK_EXCLUDED_URLS=health` | probes do kubelet virariam milhares de traces inúteis |
| `OTEL_SEMCONV_STABILITY_OPT_IN=http` | atributo `http.response.status_code`, **igual ao Go**: uma query serve para todos |

### 3.3 O caso especial: trace atravessando a fila SQS

HTTP tem cabeçalho e o `traceparent` vai nele automaticamente. Mensagem SQS não
tem cabeçalho, mas tem **MessageAttributes**. A técnica é a mesma, feita à mão:

```go
// evaluation-service/sqs.go: PRODUTOR
ctx, span := tracer.Start(ctx, "evaluation publish", trace.WithSpanKind(trace.SpanKindProducer))
carrier := propagation.MapCarrier{}
otel.GetTextMapPropagator().Inject(ctx, carrier)          // carrier["traceparent"] = "00-<trace>-<span>-01"
// cada chave do carrier vira um MessageAttribute da mensagem
```

```python
# analytics-service/app.py: CONSUMIDOR
sqs_client.receive_message(..., MessageAttributeNames=['All'])   # sem isto o SQS não devolve os atributos!
ctx = propagate.extract({k: v['StringValue'] for k, v in attrs.items()})
with tracer.start_as_current_span("evaluation process", context=ctx, kind=SpanKind.CONSUMER):
    dynamodb_client.put_item(...)      # span automático (botocore), filho do CONSUMER
```

Sem isso, o analytics apareceria como uma ilha no Service Map, com 4 serviços
conectados em vez de 5.

### 3.4 Mudanças de comportamento que a observabilidade exigiu

- **`/validate` retornava 401 para qualquer erro**, inclusive banco fora do ar.
  Para o alerta, "banco caiu" precisa ser **5xx**. Agora `sql.ErrNoRows` → 401
  (chave inválida) e qualquer outro erro → **503**.
- **`/admin/chaos`** (protegido pela MASTER_KEY): injeta falha **em memória**.
  Simula um processo degradado, a classe de problema que um restart realmente
  cura. O `/health` não é afetado, então o Kubernetes **sozinho não percebe**
  (é a "falha silenciosa" do enunciado).

---

## Parte 4 — Testar a instrumentação localmente

Antes de subir para o cluster, foi montado um ambiente Docker com Postgres,
Redis, os serviços e um **Collector que grava em arquivo**:

```yaml
# otel.yaml (do teste)
receivers: { otlp: { protocols: { grpc: {endpoint: 0.0.0.0:4317}, http: {endpoint: 0.0.0.0:4318} } } }
exporters: { file/t: { path: /out/traces.json } }
service:   { pipelines: { traces: { receivers: [otlp], exporters: [file/t] } } }
```

Depois de **uma** chamada em `/evaluate`, um script Python montou a árvore do
trace a partir do `traces.json` (agrupando por `traceId` e ligando
`parentSpanId` → `spanId`):

```
[evaluation-service] GET /evaluate (SERVER)
  [evaluation-service] get (CLIENT)                 ← Redis
  [evaluation-service] HTTP GET (CLIENT)
    [targeting-service] GET /rules/<flag_name> (SERVER)
      [targeting-service] GET (CLIENT)
        [auth-service] GET /validate (SERVER)
          [auth-service] sql.conn.query (CLIENT)    ← Postgres
  ...
```

**Esse teste achou um bug real:** os spans de banco do Python não apareciam.
Investigação: `Psycopg2Instrumentor` troca o `cursor_factory` da **conexão**, e
o código passava `cursor_factory=RealDictCursor` em **cada cursor**,
sobrescrevendo o instrumentado. Correção: o `RealDictCursor` foi para o pool.

> **Lição:** teste a telemetria como se testa código. "O SDK está instalado"
> não significa "os spans estão chegando".

O mesmo ambiente validou o chaos (`500 500 500`, com `health=200`) e o 503 com o
banco parado.

---

## Parte 5 — O OTel Collector, peça por peça

Arquivo: `kubernetes/observability/values/otel-collector.yaml`. A config de um
Collector tem 5 blocos, e entender **cada um** é o que você precisa explicar no vídeo.

### 5.1 `mode: daemonset`: um Collector por nó

1. O receiver `filelog` lê `/var/log/pods/*` **do disco do nó**. Só um
   DaemonSet vê os logs de **todos** os nós.
2. Com `internalTrafficPolicy: Local` no Service, cada pod manda OTLP para o
   Collector **do próprio nó**, sem atravessar a rede.

Imagem **contrib**: a "core" não tem `filelog`, `k8sattributes`, `spanmetrics`
nem `prometheusremotewrite`.

### 5.2 `receivers`: por onde os dados ENTRAM

| Receiver | Recebe |
|---|---|
| `otlp` (4317 gRPC / 4318 HTTP) | traces e métricas dos SDKs |
| `filelog` (preset `logsCollection`) | stdout/stderr de **todos** os containers |

### 5.3 `processors`: o que se FAZ com os dados (em ordem)

| Processor | Faz | Sem ele... |
|---|---|---|
| `memory_limiter` (sempre 1º) | recusa dados acima de 80% de memória | um pico derruba o Collector (OOMKill) |
| `k8sattributes` | pelo IP de origem, descobre o pod e adiciona `k8s.namespace.name`, `k8s.pod.name`, `k8s.deployment.name` | logs sem namespace: não dá para filtrar no Loki |
| `resource/identity` | `service.instance.id` = UID do pod | 3 Collectors gerariam a **mesma** série no Prometheus → amostras rejeitadas |
| `resource/logs-service-name` | log sem `service.name` herda o nome do Deployment | logs sem dono no Loki/New Relic |
| `filter/apps-only` | só logs das apps vão ao New Relic | logs de infra consumiriam a cota grátis |
| `batch` | agrupa antes de enviar | uma requisição HTTP por span |

### 5.4 `connectors`: o `spanmetrics`, o truque mais importante

Um *connector* é exporter de um pipeline e receiver de outro ao mesmo tempo. O
`spanmetrics` **lê traces e produz métricas**:

```
cada span SERVER que passa  ──▶  traces_span_metrics_calls_total{service_name, span_kind,
                                     status_code, http_response_status_code, http_request_method} += 1
                                 traces_span_metrics_duration_seconds_bucket{...}  (histograma)
```

**Por que isso é tão útil:** Go e Python emitem métricas HTTP com nomes e
rótulos ligeiramente diferentes. O spanmetrics gera **a mesma métrica, com os
mesmos rótulos, para todo mundo**. Dashboard e alerta usam **uma** query.

### 5.5 `exporters`: para onde os dados SAEM

| Exporter | Destino | Detalhe |
|---|---|---|
| `otlphttp/newrelic` | `https://otlp.nr-data.net` | header `api-key: ${env:NEW_RELIC_LICENSE_KEY}` |
| `prometheusremotewrite` | `kps-prometheus:9090/api/v1/write` | **empurra** métricas (o Prometheus precisa de `enableRemoteWriteReceiver`) |
| `otlphttp/loki` | `loki:3100/otlp` | Loki 3 aceita OTLP nativo: sem Promtail |

### 5.6 `service.pipelines`: a fiação

```
traces:         otlp ─▶ [memory_limiter, k8sattributes, resource/identity, batch] ─▶ newrelic, spanmetrics
metrics:        otlp, spanmetrics ─▶ [...] ─▶ prometheusremotewrite, newrelic
logs:           filelog ─▶ [..., logs-service-name, ...] ─▶ loki
logs/newrelic:  filelog ─▶ [..., filter/apps-only, ...] ─▶ newrelic
```

### 5.7 Validar antes de aplicar

```bash
helm template otel-collector open-telemetry/opentelemetry-collector --version 0.178.2 \
  -f values/otel-collector.yaml > /tmp/otel.yaml       # extrair o data.relay do ConfigMap
docker run --rm -v /tmp/relay.yaml:/c.yaml -e MY_POD_IP=127.0.0.1 -e K8S_NODE_NAME=n \
  otel/opentelemetry-collector-contrib validate --config=/c.yaml
```

Curiosidade vista aqui: o chart novo **renomeia** componentes (`k8sattributes`
→ `k8s_attributes`, `otlphttp` → `otlp_http`). É normal e ele faz a tradução sozinho.

---

## Parte 6 — Backends: Prometheus, Loki e Grafana

### 6.1 kube-prometheus-stack (`values/kube-prometheus-stack.yaml`)

O chart traz Prometheus + Operator + Grafana + node-exporter + kube-state-metrics.
As escolhas, cada uma com motivo:

| Configuração | Motivo |
|---|---|
| `alertmanager.enabled: false` | quem roteia alerta é o Grafana; dois roteadores confundem |
| `kubeEtcd/Scheduler/ControllerManager/Proxy: false` | o EKS não expõe; virariam alvos DOWN e alertas falsos (**alert fatigue**) |
| `admissionWebhooks.enabled: false` | são hooks do Helm que o Argo CD trata mal (OutOfSync eterno) |
| `enableRemoteWriteReceiver: true` | para o Collector empurrar métricas |
| `retention: 2d`, sem `storageSpec` | sem EBS CSI no Academy: `emptyDir` |
| `grafana.admin.existingSecret` | senha gerada pelo chart muda a cada render do Argo → Secret eternamente OutOfSync |
| `grafana.envFromSecrets` | tokens como env var, usados como `${VAR}` nos arquivos de alerta |
| `serve_from_sub_path` + `root_url .../grafana/` | publicado em `https://<ELB>/grafana` (mesmo padrão do Argo CD) |
| `sidecar.dashboards/alerts` | ConfigMaps com label viram dashboard/alerta: **tudo como código** |

### 6.2 Loki (`values/loki.yaml`)

`deploymentMode: SingleBinary` (um pod com tudo), `schema: v13` + `store: tsdb`
(**obrigatórios** para OTLP), memcached desligado (pede ~10 GiB por padrão!) e
`emptyDir`. Os atributos OTel viram labels: `k8s_namespace_name`,
`service_name`, `k8s_pod_name`.

LogQL para praticar:
```logql
{k8s_namespace_name="auth-service"}                         # tudo do auth
{k8s_namespace_name="auth-service"} |= "ERRO"               # filtra texto
{service_name="flag-service"} |= "trace_id=4ff418dd"        # segue um trace nos logs
sum by (service_name) (count_over_time({k8s_namespace_name=~".+-service"} |~ "(?i)erro" [1m]))
```

### 6.3 Valores medidos no cluster real

```
req/s (spanmetrics):  evaluation 1.23 | auth 1.40 | flag 1.25 | targeting 0.03
SQS:                  producer (evaluation) 1.24/s → consumer (analytics) 0.49/s (KEDA ainda escalando)
Loki (5 min):         11 namespaces com logs, inclusive argocd, kube-system, keda
```

---

## Parte 7 — Dashboard como código

O dashboard não foi desenhado clicando: é gerado por
`scripts/gerar-dashboard.py`, que monta o JSON e o embrulha num ConfigMap com
`labels: {grafana_dashboard: "1"}`. O sidecar do Grafana vê o ConfigMap e carrega.

```bash
python3 techchallange4/scripts/gerar-dashboard.py     # edite os painéis no .py, rode, commite
```

**Por que código e não clique:** o dashboard sobrevive à recriação do Grafana
(que é `emptyDir`!), tem histórico no git e passa por revisão.

As 3 seções que o PDF pede:

| Seção | Exemplo de query |
|---|---|
| Recursos do cluster | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Taxa de requisições | `sum by (service_name)(rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[1m]))` |
| Logs em tempo real | `{k8s_namespace_name=~"$namespace"} \|~ "(?i)$busca"` (variáveis no topo) |

---

## Parte 8 — Alertas inteligentes

Arquivo: `kubernetes/observability/config/alerting.yaml`, com 3 partes.

### 8.1 A regra (anatomia)

```yaml
- uid: auth-5xx-rate
  data:
    - refId: A        # a QUERY: fração de 5xx nos últimos 2 min
      model:
        expr: (sum(rate(..._calls_total{service_name="auth-service",...,http_response_status_code=~"5.."}[2m])) or vector(0))
              / sum(rate(..._calls_total{service_name="auth-service",...}[2m]))
    - refId: C        # a CONDIÇÃO: A > 0.05
      model: { type: threshold, expression: A, conditions: [{evaluator: {type: gt, params: [0.05]}}] }
  for: 1m             # precisa ficar acima por 1 min SEGUIDO
  noDataState: OK     # sem tráfego ≠ incidente
  labels:             # usados para ROTEAR e para o self-healer AGIR
    severity: critical
    remediation: rollout-restart
    namespace: auth-service
    deployment: auth-service
```

Os truques:
- **`or vector(0)`**: sem nenhum 5xx, o numerador *some* (vira "sem dados") e a
  divisão também. Com isso, ele vale 0 e o resultado é 0%.
- **`for: 1m`**: um erro isolado não acorda ninguém. No teste: Pending em 48 s,
  Firing 56 s depois.
- **Labels como contrato**: o alerta diz ao self-healer **o que** fazer e **onde**.

### 8.2 Contact points: os destinos

```yaml
- name: pagerduty-oncall      type: pagerduty   integrationKey: ${PAGERDUTY_ROUTING_KEY}
- name: discord-togglemaster  type: discord     url: ${DISCORD_WEBHOOK_URL}   message: template detalhado
- name: self-healer-webhook   type: webhook     url: http://self-healer.self-healing.svc.cluster.local/webhook/grafana
                                                authorization_credentials: ${SELF_HEALER_TOKEN}
```

`${VAR}` é interpolado pelo Grafana a partir das env vars (Secret do ESO).
**Pegadinha:** por causa disso, um `$` literal dentro de template precisa ser
`$$` (por exemplo `$$values.A.Value`).

### 8.3 A política: a árvore de roteamento

```
raiz → discord (padrão)
 ├─ remediation=rollout-restart → self-healer   (continue: true → segue avaliando)
 ├─ severity=critical           → PagerDuty     (continue: true)
 └─ team=togglemaster           → Discord
```

Um alerta **critical com remediação** passa pelas três rotas. Um **warning**
(latência, restarts) só cai no Discord.

### 8.4 Alert fatigue: como foi combatido

| Técnica | Onde |
|---|---|
| Esperar persistência | `for: 1m` / `5m` |
| Sem tráfego não é incidente | `noDataState: OK` |
| Só o grave acorda alguém | `severity=critical` → PagerDuty; `warning` → Discord |
| Agrupar | `group_by: [alertname, service]`: 50 pods falhando = 1 mensagem |
| Não repetir à toa | `repeat_interval: 4h` |
| Não alertar o impossível | monitores do control plane do EKS desligados |
| Auto-resolver | o PagerDuty fecha o incidente quando o Grafana manda *resolved* |

---

## Parte 9 — PagerDuty, Discord e New Relic

### 9.1 New Relic (APM)

1. Criar a conta (Free) na região **US**. Uma conta EU exige trocar o endpoint para `otlp.eu01.nr-data.net`.
2. *API Keys* → chave **`INGEST - LICENSE`** (40 caracteres, termina em `NRAL`).
   Não use a `USER` key (`NRAK-...`): ela é para a API de consulta e daria 403.
3. Não há agente: o Collector exporta via OTLP. As entidades aparecem pelo `service.name`.

### 9.2 PagerDuty

1. Conta Free → *Services* → *New Service* "ToggleMaster" → escalation policy padrão.
2. Integração **Events API V2** (a genérica, não a "Grafana" da lista) → copiar a **Integration Key** (32 caracteres).
3. No perfil: e-mail + celular + app instalado, e *High urgency*.

Como funciona: *firing* manda um evento `trigger` e o PagerDuty abre o incidente;
*resolved* manda `resolve` com o mesmo `dedup_key` e o PagerDuty fecha o **mesmo** incidente.

### 9.3 Discord

Canal → ⚙️ → *Integrações* → *Webhooks* → *Novo* → copiar a URL.

### 9.4 Gravar tudo

```bash
./techchallange4/scripts/set-observability-secrets.sh
```
O script lê com entrada oculta (não fica no histórico), preserva o que já
existe (ENTER = mantém), gera a senha do Grafana e o token do self-healer, grava
no Secrets Manager, força o ESO a sincronizar e reinicia quem lê no boot.

---

## Parte 10 — O self-healer

`docker/self-healer/app.py` + `kubernetes/self-healing/self-healer.yaml`.

### 10.1 Por que um serviço no cluster (e não GitHub Action ou Lambda)

| | self-healer | GitHub Action | Lambda |
|---|---|---|---|
| Tempo até agir | **~1 s** (medido) | 20–60 s de fila | segundos |
| Credencial do cluster | ServiceAccount + RBAC (efêmera) | kubeconfig + chave AWS **no GitHub** | IAM role (**proibida no Academy**) |

### 10.2 O que `kubectl rollout restart` realmente é

Não é mágica: o comando grava uma anotação com a hora atual no **template do pod**:

```json
{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"2026-11-07T20:09:58Z"}}}}}
```

Template mudou → o controller do Deployment cria um **ReplicaSet novo** → sobe
o pod novo → espera ficar *Ready* → derruba o antigo (rolling update, **sem
downtime**). O self-healer faz exatamente esse `PATCH` na API do Kubernetes,
autenticado com o token da própria ServiceAccount. Assim a imagem não precisa
do binário `kubectl`, o que significa menos superfície de ataque e menos CVE.

### 10.3 O fluxo dentro do código

```
POST /webhook/grafana
 1. Authorization == "Bearer <token>"?  (hmac.compare_digest: comparação em tempo constante)
 2. para cada alerta com status "firing" e label remediation=rollout-restart:
 3.   alvo = namespace/deployment (dos labels)
 4.   alvo está na ALLOWED_TARGETS?  senão → recusa
 5.   restart há menos de 300 s?      senão → cooldown (anti-loop)
 6.   lista os pods → PATCH restartedAt → mensagem no Discord "🤖 acionado"
 7.   thread em segundo plano: espera o rollout (como `kubectl rollout status`) → Discord "✅ concluído"
```

Log real do teste:
```
20:09:58 SELF-HEALING: alerta 'auth-service - taxa de erros 5xx acima de 5%' -> kubectl rollout restart
         deployment/auth-service -n auth-service (pods atuais: ['auth-service-6845756bdc-jjtrd'])
20:10:13 SELF-HEALING OK: auth-service/auth-service com pods novos e prontos: ['auth-service-6f5844c85f-tfw4j']
```

### 10.4 Segurança em camadas

1. **ClusterRole** mínima: `get/list/patch` em deployments e `get/list` em pods. Sem delete, sem secrets.
2. **RoleBinding só nos 5 namespaces das apps**: no `argocd` e no `kube-system` ela não vale.
3. **Allowlist** no app: mesmo com RBAC, só os pares listados.
4. **Token** no webhook: outro pod do cluster não consegue disparar restarts.
5. Container não-root, root filesystem **read-only**, `drop: ALL`.

---

## Parte 11 — Ligando tudo no GitOps

### 11.1 Multi-source: chart de um lugar, values de outro

```yaml
sources:
  - repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 93.0.0
    helm: { valueFiles: [ $values/techchallange4/kubernetes/observability/values/kube-prometheus-stack.yaml ] }
  - repoURL: https://github.com/LuizFelipeCibulski/DEVOPS-ARQCLOUD
    ref: values        # ← "$values" aponta para este repositório
```

Vantagem: o values é um arquivo YAML normal, com diff legível e testável com `helm template`.

**Cuidado aprendido na fase 3:** o diretório `values/` **não** pode estar dentro
de um path sincronizado como manifesto. Values não têm `kind`, e o Argo CD
falha a Application inteira (`Object 'Kind' is missing`). Por isso existem
`observability/values/` (Helm) e `observability/config/` (manifestos) separados.

### 11.2 Ondas (sync waves): a ordem de subida

```
-20  external-secrets, keda          → instalam CRDs que os outros usam
-10  secret-stores                   → ClusterSecretStore
 -8  observability-config            → ExternalSecret dos tokens, dashboard, alertas, rota /grafana
 -6  kube-prometheus-stack, loki     → backends
 -5  otel-collector                  → antes das apps: nenhum span da subida se perde
 20  auth-service                    → + Job que cunha a SERVICE_API_KEY
 30  flag, targeting
 40  evaluation, analytics
 50  self-healer                     → RoleBindings nos namespaces criados nas ondas 20-40
```

---

## Parte 12 — CI/CD no modo Academy

### 12.1 Credenciais

Sem IAM role não há OIDC entre GitHub e AWS. Os pipelines ganharam um passo
condicional:

```yaml
- name: Configurar credenciais AWS (OIDC - conta normal)
  if: ... && vars.AWS_MODE != 'academy'
  with: { role-to-assume: ${{ secrets.AWS_ROLE_TO_ASSUME }} }
- name: Configurar credenciais AWS (AWS Academy - sessão temporária)
  if: ... && vars.AWS_MODE == 'academy'
  with: { aws-access-key-id: ..., aws-secret-access-key: ..., aws-session-token: ... }
```

| GitHub | Valor |
|---|---|
| secrets `AWS_ACCESS_KEY_ID` / `SECRET` / `SESSION_TOKEN` | chaves do Lab (`./techchallange4/update-secrets-aws.sh` lê do `~/.aws/credentials`) |
| variable `AWS_MODE` | `academy` |
| variable `EKS_PUBLIC_ACCESS_CIDRS` | **seu IP atual**. Com o IP errado, o `terraform.yml` cortaria o seu `kubectl` |

As chaves do Lab expiram a cada sessão. Pipeline falhou com `ExpiredToken`?
Rode o script de novo.

### 12.2 O Trivy é um gate "vivo"

O mesmo código passou no Trivy local às 15h e **reprovou no CI às 17h**: duas
CVEs do `urllib3` foram publicadas no meio do dia. Isso não é falha do pipeline.
É o pipeline **funcionando**: código que não mudou pode ficar vulnerável.
Correção: subir a versão (`urllib3 2.8.0`, `gunicorn 22.0.0`) e reescanear
**fs + imagem** localmente antes do push.

### 12.3 O fecho GitOps

Imagem publicada → o job reescreve a tag em `kubernetes/<svc>/deployment.yaml`
com `sed` → commit do bot na main → o Argo CD sincroniza. O pipeline **nunca**
roda `kubectl apply`. Visto no histórico:
`chore(auth-service): imagem v1.0.0-26dec76`.

---

## Parte 13 — A execução real, comando a comando

A sequência que foi de fato executada, na ordem:

```bash
# 1. Infra
cd techchallange4/iac && ./bootstrap-backend.sh && tofu init && tofu apply
aws eks update-kubeconfig --region us-east-1 --name togglemaster-prod

# 2. Tokens
./techchallange4/scripts/set-observability-secrets.sh

# 3. Componentes que não podem ser GitOps (quem gerencia o GitOps não é gerenciado por ele)
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace -f techchallange4/kubernetes/traefik/values.yaml --wait
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.rootpath":"/argocd"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl apply -f techchallange4/kubernetes/argocd/ingressroute.yaml

# 4. CI/CD
./techchallange4/update-secrets-aws.sh
gh api -X PATCH repos/<dono>/<repo>/actions/variables/EKS_PUBLIC_ACCESS_CIDRS -f name=EKS_PUBLIC_ACCESS_CIDRS -f "value=[\"<IP>/32\"]"
git push origin main                                   # 6 pipelines

# 5. GitOps: uma linha sobe tudo
kubectl apply -f techchallange4/kubernetes/argocd/apps/root.yaml
kubectl apply -f techchallange4/kubernetes/traefik/middleware.yaml -f techchallange4/kubernetes/traefik/ingressroute.yaml

# 6. Validação
./techchallange4/scripts/gerar-trafego.sh               # tráfego contínuo
./techchallange4/scripts/chaos.sh on 0.5                # a prova real
kubectl get pods -n auth-service -w                     # ver o pod ser trocado
kubectl logs -n self-healing deploy/self-healer -f      # ver a automação agir
```

### Checklist de verificação (o que olhar e o que esperar)

| Verificação | Comando | Esperado |
|---|---|---|
| Nós | `kubectl get nodes` | 3 Ready |
| IMDS | `aws ec2 describe-instances --query '...HttpPutResponseHopLimit'` | 2 |
| Cofre | `kubectl get clustersecretstore` | `Valid / True` |
| Secrets | `kubectl get externalsecret -A` | todos `SecretSynced` |
| Argo CD | `kubectl get applications -n argocd` | 14 × Synced/Healthy |
| Collector | `kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector --since=2m \| grep -c 'Exporting failed'` | 0 |
| Rotas | `curl -sk https://<ELB>/auth/health` (e flags, target, evaluation, grafana) | 200 (analytics: 503 = scale-to-zero, normal) |
| Grafana | *Alerting → Alert rules* | 3 regras, health OK |
| KEDA | `kubectl get hpa -n analytics-service` | `keda-hpa-sqs-scaledobject` |

---

## Parte 14 — Depuração: os 7 problemas reais e como foram achados

O mais valioso para aprender não é a config final, é **o caminho até ela**.
Em todos os casos o método foi o mesmo: **sintoma → onde olhar → evidência → causa → correção**.

### 1. Spans de banco ausentes no Python (achado no teste local)
- **Sintoma:** trace sem `SELECT` nos serviços Python.
- **Evidência:** `get_dependency_conflicts()` retornou `None`, então a lib **estava** ativa. Lendo o código da lib: ela troca o `cursor_factory` da conexão.
- **Causa:** `conn.cursor(cursor_factory=RealDictCursor)` sobrescrevia.
- **Correção:** `RealDictCursor` no pool.

### 2. Trivy: `x/net` antigo no Go (achado no scan local)
- **Evidência:** `golang.org/x/net v0.59.0`, fixed `0.62.0`; stdlib `1.26.8`.
- **Causa:** dependência transitiva do gRPC/OTel + imagem `golang:1.26` local desatualizada.
- **Correção:** `go get golang.org/x/net@latest` + `docker pull`.

### 3. Trivy: urllib3/gunicorn no CI
- **Sintoma:** 4 pipelines vermelhos em "SCA - Trivy".
- **Evidência:** `gh run view <id> --log-failed`.
- **Causa extra:** o `sed` não trocava a versão porque os `requirements.txt` estavam em **CRLF** (`cat -A` mostra `^M$`).
- **Correção:** normalizar para LF + versões novas + reescanear fs e imagem antes do push.

### 4. ESO não lê o cofre: o IMDS (o mais instrutivo)
- **Sintoma:** todos os ExternalSecret em `SecretSyncedError`; nada sobe em cascata.
- **Onde olhar:** `kubectl get clustersecretstore` → `InvalidProviderConfig`. Logs do ESO:
  `no EC2 IMDS role found, operation error ec2imds: GetMetadata, context deadline exceeded`.
- **Raciocínio:** "deadline exceeded" no IMDS significa que a requisição **não volta**, não que foi negada. Hipótese: hop limit.
- **Evidência:** `aws ec2 describe-instances` → `HttpPutResponseHopLimit: 1`.
- **Por que na fase 3 não aconteceu:** lá os pods usavam IRSA, que não passa pelo IMDS.
- **Correção:** launch template com hop limit 2 (Parte 2.4).

### 5. Argo CD preso com a imagem antiga
- **Sintoma:** git com tag nova, pod com tag velha em `ImagePullBackOff`.
- **Evidência:** `operationState.phase=Running`, `revision=26dec76` (anterior ao commit do bot), `message=waiting for healthy state`.
- **Causa:** uma operação de sync **fixa a revisão** do começo e não pega commits novos enquanto roda (já documentado na fase 3).
- **Correção:** `kubectl patch application X -n argocd --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'` + hard refresh.

### 6. KEDA recusando o ScaledObject (bug herdado da fase 3)
- **Mensagem:** `the workload 'analytics-service' ... is already managed by the hpa 'hpa-analytics'`.
- **Causa:** `hpa.yaml` manual **e** KEDA, que cria o próprio HPA, no mesmo Deployment.
- **Correção:** apagar o `hpa.yaml`. Resultado: o KEDA escalou o analytics de 0 para 4 com 51 mensagens na fila.

### 7. New Relic 401/403 com a chave certa
- **Evidência:** chave com formato válido (40 caracteres, `NRAL`, sem espaços); Collectors iniciados às 19:52; secret materializado ~20:00.
- **Causa:** env var é lida **só no boot**, e a chave é `optional`, então o pod subiu com ela vazia.
- **Correção:** `kubectl rollout restart daemonset/otel-collector-agent` → 0 erros.

---

## Parte 15 — Exercícios para fixar

1. **Siga um trace pelos 3 pilares:** pegue um `trace_id` num log do Loki
   (`{k8s_namespace_name="flag-service"} |= "trace_id="`), abra no New Relic e
   veja a métrica do mesmo serviço no dashboard.
2. **Crie um alerta novo** no `alerting.yaml`: "flag-service p95 > 500 ms",
   severidade `warning`. Antes do push, preveja para onde ele vai na árvore.
3. **Teste o cooldown:** rode `chaos.sh on` duas vezes em menos de 5 min e veja
   o log `COOLDOWN` do self-healer. Pergunta: por que o PagerDuty continua aberto?
4. **Falha que restart não cura:** pare o RDS do auth
   (`aws rds stop-db-instance`). O alerta dispara (503), o self-healer reinicia
   e **não resolve**. É aí que o humano do PagerDuty entra. Explique por que o
   cooldown é essencial nesse cenário.
5. **Troque de APM sem rebuild:** escreva (sem aplicar) o exporter `datadog`
   no Collector. Quantos arquivos de aplicação mudariam? (Resposta: zero.)
6. **Quebre o contexto de propósito:** troque `NewRequestWithContext` por
   `NewRequest` no `fetchFlag`, rode o teste local da Parte 4 e veja o trace se partir.

---

## Glossário

| Termo | Significado |
|---|---|
| **Span** | uma operação com início e fim (uma requisição, uma query). Tem `trace_id`, `span_id` e `parent_span_id` |
| **Trace** | a árvore de spans de uma requisição, atravessando serviços |
| **SERVER / CLIENT / PRODUCER / CONSUMER** | o papel do span: recebeu, chamou, publicou ou consumiu uma mensagem |
| **traceparent** | cabeçalho W3C que leva `trace_id` + `span_id` de um serviço para o próximo |
| **OTLP** | protocolo do OpenTelemetry (gRPC na 4317, HTTP na 4318) |
| **Resource** | atributos de **quem** emite (`service.name`, `k8s.pod.name`) |
| **RED** | Rate, Errors, Duration: as 3 métricas de saúde de um serviço |
| **spanmetrics** | connector que transforma spans em métricas RED |
| **remote write** | o Prometheus **recebe** métricas empurradas, em vez de buscar (scrape) |
| **IMDS / hop limit** | serviço de metadados do EC2 / quantos saltos de rede a resposta atravessa |
| **IRSA** | IAM Roles for Service Accounts: identidade AWS por pod (indisponível no Academy) |
| **Sync wave** | ordem de aplicação no Argo CD |
| **Alert fatigue** | excesso de alertas → o time passa a ignorá-los |
| **Runbook Automation** | o procedimento de resposta executado por máquina |
| **dedup_key** | chave que faz o *resolve* fechar o mesmo incidente que o *trigger* abriu |
