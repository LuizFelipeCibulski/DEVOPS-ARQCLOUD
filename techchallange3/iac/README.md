# IaC — ToggleMaster (Tech Challenge Fase 2)

Terraform (testado com **OpenTofu**) para provisionar, na AWS, toda a
infraestrutura pedida na Etapa 2 do desafio: VPC isolada, EKS, ECR, RDS,
ElastiCache, DynamoDB e SQS — nos dois cenários que o PDF permite (AWS
Academy com `LabRole` e conta AWS normal).

## Índice

- [Estrutura](#estrutura)
- [Pré-requisitos](#pré-requisitos)
- [Como rodar](#como-rodar)
- [Modo Academy x Normal](#modo-academy-x-normal)
- [Academy x Console: uma ressalva importante](#academy-x-console-uma-ressalva-importante)
- [Arquitetura de rede](#arquitetura-de-rede)
- [Peculiaridades de cada serviço](#peculiaridades-de-cada-serviço)
- [Como os serviços se comunicam](#como-os-serviços-se-comunicam)
- [Depois do apply: conectando com o Kubernetes](#depois-do-apply-conectando-com-o-kubernetes)
- [Custos e limpeza](#custos-e-limpeza)

## Estrutura

```
iac/
├── main.tf                  # conecta todos os módulos
├── variables.tf              # todas as variáveis (com defaults sensatos)
├── outputs.tf                 # "checklist de infraestrutura" do PDF
├── providers.tf                # versões + provider aws
├── terraform.tfvars.example
└── modules/
    ├── vpc/            # rede em 3 camadas (pública / app privada / db privada)
    ├── ecr/            # 5 repositórios (um por microsserviço)
    ├── eks/            # cluster + node group, dual-mode IAM (LabRole x normal)
    ├── rds/            # 3 instâncias Postgres independentes
    ├── elasticache/    # Redis (Serverless por padrão)
    ├── dynamodb/       # tabela de eventos de analytics
    └── sqs/            # fila + DLQ
```

## Pré-requisitos

- Terraform >= 1.5 ou OpenTofu (`tofu`) — os exemplos abaixo usam `tofu`,
  troque por `terraform` se preferir.
- Credenciais AWS configuradas (`aws configure` ou variáveis
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` no
  caso do Academy — a sessão do Academy expira em poucas horas, você vai
  precisar reexportar essas variáveis e rodar `tofu apply` de novo
  quando isso acontecer).
- No AWS Academy: entre no laboratório primeiro (isso cria a `LabRole` e
  as credenciais temporárias) antes de rodar qualquer comando Terraform.

## Como rodar

```bash
cd iac
cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars: confirme is_academy, região, tamanhos, etc.

tofu init
tofu plan   -out=tfplan
tofu apply  tfplan

# anote as saídas (ou rode de novo mais tarde):
tofu output                    # tudo que não é sensível
tofu output -json rds_database_urls   # strings de conexão (sensível)
```

Para destruir tudo no fim do dia/sessão do Academy:

```bash
tofu destroy
```

## Modo Academy x Normal

Uma única base de código atende as duas opções do desafio, controlada
por `var.is_academy`:

| | `is_academy = true` (Opção A) | `is_academy = false` (Opção B) |
|---|---|---|
| IAM do cluster/nós | Reaproveita a `LabRole` existente (`data "aws_iam_role"`, nunca `resource`) | Terraform cria `<cluster>-cluster-role` e `<cluster>-node-role` dedicadas, com a política mínima de cada uma |
| IRSA (IAM Roles for Service Accounts) | Desligado — Academy não permite criar as roles que o IRSA exige | Provider OIDC do cluster é criado (`enable_irsa = true`), liberando IRSA para o Ingress Controller, KEDA etc. |
| KEDA / Karpenter | Não funcionam (dependem de IRSA) — use o HPA por CPU (requisito mínimo do desafio) | Pode usar KEDA para o `analytics-service` escalar direto pela profundidade da fila SQS |
| Node group | `capacity_type = ON_DEMAND` (Spot é mais chato de garantir em Academy) | Pode trocar para `SPOT` em `node_capacity_type` para economizar |

## Academy x Console: uma ressalva importante

O PDF é específico: na Opção A, o cluster deve ser criado **pelo Console**
(ou seja, não usar `eksctl create cluster`) — porque o `eksctl` cria
IAM roles novas, e o Academy não permite isso. O motivo de fundo não é
"não pode usar IaC", é "não pode criar roles novas".

O módulo `eks/` deste projeto **nunca cria uma role nova quando
`is_academy = true`** — ele só faz um `data "aws_iam_role"` (leitura) e
aponta tanto o cluster quanto o node group para a `LabRole` existente,
exatamente como você faria clicando no Console e selecionando "Use
existing role: LabRole". Ou seja, tecnicamente o requisito de fundo (não
criar IAM role nova) é respeitado.

Ainda assim, se quem for corrigir o desafio for literal sobre "use o
Console", ligue `manage_eks_cluster = false` no `terraform.tfvars`: o
Terraform cria só a VPC/subnets (já com as tags `kubernetes.io/role/elb`,
`kubernetes.io/role/internal-elb` e `kubernetes.io/cluster/<nome>` que o
EKS/ALB Controller esperam) e você cria o cluster manualmente pelo
Console, usando essas subnets. Todo o resto (ECR, RDS, ElastiCache,
DynamoDB, SQS) continua sendo Terraform de qualquer forma — o PDF não
restringe esses.

## Arquitetura de rede

VPC isolada, `10.0.0.0/16`, 2 AZs, em 3 camadas de subnet:

```
                                   Internet
                                       │
                                 Internet GW
                                       │
        ┌──────────────────────────────┴──────────────────────────────┐
        │                         PUBLIC subnets                       │
        │        (10.0.0.0/24, 10.0.1.0/24 - uma por AZ)                │
        │                                                               │
        │   [NAT Gateway]        [Load Balancer do Nginx/Traefik] ◄─────┼── único ponto exposto à internet
        └──────────────────────────────┬──────────────────────────────┘
                                       │ (rota default via NAT)
        ┌──────────────────────────────┴──────────────────────────────┐
        │                     PRIVATE-APP subnets                      │
        │      (10.0.10.0/24, 10.0.11.0/24 - nós do EKS + todos os      │
        │       pods, incluindo o próprio Ingress Controller)           │
        └──────────────────────────────┬──────────────────────────────┘
                                       │ (sem rota para internet)
        ┌──────────────────────────────┴──────────────────────────────┐
        │                     PRIVATE-DB subnets                       │
        │   (10.0.20.0/24, 10.0.21.0/24 - RDS x3 + ElastiCache)         │
        │              totalmente isoladas, sem NAT nem IGW             │
        └───────────────────────────────────────────────────────────────┘
```

Pontos-chave:

- **Só a camada `public` tem rota para a Internet Gateway.** Nada roda
  ali além do NAT Gateway e do(s) ENI(s) do Load Balancer que o
  Kubernetes cria para o Ingress Controller.
- **Nenhum Pod é "exposto à internet" diretamente** — o que fica público
  é o Load Balancer (ALB/NLB) que o Service `type: LoadBalancer` do
  Ingress Controller cria nas subnets públicas (via as tags
  `kubernetes.io/role/elb`). Ele só encaminha tráfego para os pods do
  Ingress, que continuam rodando nos nós privados. Todo o resto (as 5
  APIs, RDS, Redis) nunca tem uma rota possível para a internet.
- **`private-app`** tem saída via NAT Gateway — os nós precisam disso
  para puxar imagem do ECR, resolver pacotes do SO, etc. Isso não é uma
  brecha de entrada: NAT só permite conexões *iniciadas de dentro* para
  fora, nunca o contrário.
- **`private-db`** não tem rota nenhuma para fora (nem NAT, nem IGW) —
  RDS e ElastiCache não têm motivo para iniciar conexão de saída, e essa
  ausência de rota é uma camada de defesa a mais além do Security Group.
- Cada camada de Security Group segue o princípio de menor privilégio:
  o SG do RDS só libera `5432` a partir do SG do cluster EKS; o do Redis
  só libera `6379` da mesma forma. Nunca `0.0.0.0/0`.

## Peculiaridades de cada serviço

### VPC / Rede
- 3 camadas de subnet (acima) em vez das 2 camadas mais comuns
  (`public`/`private`) — separar "onde rodam os nós" de "onde ficam os
  dados" é o que garante que um pod comprometido não consegue nem
  *tentar* uma rota de rede para fora do VPC a partir do banco.
- 1 único NAT Gateway por padrão (`single_nat_gateway = true`) — mais
  barato (cobra por hora + tráfego), mas é um ponto único de falha para
  a saída de internet dos nós. Para produção "de verdade" isso viraria
  1 NAT por AZ (`single_nat_gateway = false`); mantive o default barato
  porque isso aqui é um ambiente de estudo/desafio.

### EKS
- Control plane é gerenciado pela AWS (multi-AZ automaticamente); o que
  o Terraform de fato cria é o *node group* (EC2) e as IAM roles (ou
  reaproveita a `LabRole`).
- Nós ficam só em `private-app`. O tráfego externo chega neles através
  do Load Balancer criado pelo Ingress Controller, nunca diretamente.
- `endpoint_public_access = true` — o endpoint da API do Kubernetes
  (usado pelo `kubectl`) é público por padrão, por conveniência de
  desenvolvimento. Isso é diferente de "os pods estão expostos": é só a
  API administrativa do cluster, protegida por IAM/RBAC. Se quiser
  travar mais, dá pra restringir por CIDR ou desligar
  `endpoint_public_access` e usar VPN/bastion.
- **`.terraform`/HPA não escala nós, só pods.** O `node_desired_size`/
  `node_min_size`/`node_max_size` é o tamanho do *node group* (quantas
  EC2 existem) — isso é fixo pelo Terraform, igual ao que o PDF pede
  para configurar no Console (Mínimo=1, Desejado=2, Máximo=4). Quem
  escala os *pods dentro dessa capacidade fixa* é o HPA (Requisito 5 do
  desafio). Se um dia os pods não couberem mais nos nós existentes, é
  aí que entraria um Cluster Autoscaler ou Karpenter (fora do escopo
  mínimo do desafio, e Karpenter não funciona em Academy mesmo).

### ECR
- Um repositório por microsserviço, `image_tag_mutability = IMMUTABLE`
  (uma tag já publicada não pode ser sobrescrita — evita o clássico bug
  de "empurrei uma imagem nova como `:latest` mas o Kubernetes não
  percebeu porque o digest já estava em cache").
- `scan_on_push = true` (scan de vulnerabilidades gratuito da AWS,
  Basic Scanning) e uma lifecycle policy que mantém só as últimas N
  imagens tagueadas e expira imagens sem tag depois de 1 dia — sem
  isso, cada `docker push` acumula lixo pra sempre.

### RDS (PostgreSQL) — auth-service, flag-service, targeting-service
- **3 instâncias independentes**, não uma só compartilhada — isso é
  "database per service": cada microsserviço é dono do seu schema, pode
  migrar/versionar seu banco sem coordenar com os outros dois, e uma
  instância lenta ou fora do ar não derruba as outras. É o motivo pelo
  qual o desafio pede 3 RDS em vez de 1 com 3 schemas.
  Isso mapeia a decisão de arquitetura de dados: essas 3 tabelas
  guardam **entidades com relacionamento e integridade que importam**
  (chaves de API, definições de feature flag, regras de segmentação) —
  o caso de uso clássico para um banco relacional.
- Senha gerada por `random_password` (nunca fica hardcoded em lugar
  nenhum do `.tf`) e exposta só via `output` marcado `sensitive`.
- `publicly_accessible = false`, subnets `private-db`, storage
  criptografado.

### ElastiCache (Redis) — evaluation-service
- Por padrão, **ElastiCache Serverless** (escala sozinho, cobra por uso
  em vez de por instância provisionada 24/7 — combina bem com uma carga
  imprevisível de um desafio/estudo). Dá pra trocar para um cluster
  tradicional (`cache.t3.micro`) via `redis_serverless = false`.
- Único propósito: cache do **hot path**. O `evaluation-service` é
  literalmente descrito no PDF como "o caminho quente de alta
  performance que retorna a decisão final" — ele não pode pagar o custo
  de ida-e-volta numa chamada síncrona a cada avaliação de flag; o Redis
  guarda o resultado computado (ou dados intermediários) com latência
  de sub-milissegundo. Diferente do RDS: aqui não importa durabilidade
  de longo prazo, importa velocidade — se o Redis perder o cache, a
  pior consequência é recalcular, não perder dado.

### DynamoDB — analytics-service
- Tabela única `ToggleMasterAnalytics`, chave primária `event_id`
  (String, um UUID gerado a cada evento) — confirmado lendo
  `analytics-service/app.py`, que monta o item com
  `{'event_id': {'S': ...}, 'user_id': ..., 'flag_name': ..., 'result':
  ..., 'timestamp': ...}`. Não há sort key: cada evento é um item
  isolado, sem necessidade de consultas por intervalo dentro do mesmo
  UUID.
- `billing_mode = PAY_PER_REQUEST` (on-demand) — o tráfego de eventos
  vem em rajadas conforme a fila SQS enche/esvazia; não dá pra (nem faz
  sentido) planejar capacidade provisionada fixa pra isso.
- Por que NoSQL aqui e não mais um Postgres: isso é um **log de
  eventos** (write-heavy, append-only, sem necessidade de JOIN com
  outras tabelas, schema que pode evoluir por evento sem migração). É
  exatamente o caso de uso onde DynamoDB compensa a rigidez que ganha em
  troca de escala/latência previsível.

### SQS — entre evaluation-service e analytics-service
- Fila `Standard` (não FIFO): o PDF não exige ordenação estrita entre
  eventos de avaliação, e Standard tem throughput maior e custo menor.
- Acrescentei uma **Dead Letter Queue** (`evaluation-dlq`) com
  `maxReceiveCount = 5` — não pedida explicitamente no PDF, mas o
  próprio código do `analytics-service` comenta que uma mensagem
  malformada ("poison pill") não é deletada, ficando para
  reprocessamento; sem DLQ ela ficaria sendo entregue de novo pra sempre
  e nunca sairia da fila principal.
- **Por que existe fila em vez de flag-service chamar analytics
  diretamente:** desacopla o hot path (evaluation-service, que precisa
  responder rápido) do trabalho pesado/lento (gravar no DynamoDB). O
  evaluation-service só publica o evento e responde ao cliente
  imediatamente; o analytics-service consome no próprio ritmo, sem
  atrasar a decisão de flag. É também o mecanismo de escalabilidade que
  o Requisito 5 do desafio explora: quando a fila enche, a CPU do
  analytics-service sobe (processando mais mensagens) e o HPA reage a
  isso — é literalmente o "workaround" que o PDF descreve para
  escalonar via fila usando só HPA por CPU (sem precisar de KEDA).

## Como os serviços se comunicam

```
Internet
   │  HTTPS
   ▼
[Load Balancer criado pelo Ingress Controller] (subnet pública)
   │
   ▼
[Nginx/Traefik Ingress Controller pods] (subnet privada-app)
   │  roteamento por path: /auth /flags /target /evaluation /analytics
   ▼
[Service ClusterIP de cada microsserviço]
   │
   ├─ auth-service        ── RDS (auth_db)
   ├─ flag-service         ── RDS (flag_db)      + chama auth-service (valida API key)
   ├─ targeting-service   ── RDS (targeting_db)  + chama auth-service (valida API key)
   ├─ evaluation-service  ── Redis (cache)
   │                         + chama flag-service e targeting-service via DNS interno
   │                           (Service.namespace.svc.cluster.local)
   │                         + publica evento no SQS (fire-and-forget, não bloqueia a resposta)
   └─ analytics-service   ── consome do SQS
                              + grava no DynamoDB
```

Toda comunicação *entre* microsserviços dentro do cluster usa o DNS
interno do Kubernetes (`<service>.<namespace>.svc.cluster.local`) — é
por isso que os `ConfigMap`s em `kubernetes/*/configmap.yaml` guardam
`AUTH_SERVICE_URL`, `FLAG_SERVICE_URL` etc. apontando para esse padrão,
nunca para um endpoint público.