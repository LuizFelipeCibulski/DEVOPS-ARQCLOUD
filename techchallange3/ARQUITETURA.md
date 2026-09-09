# ToggleMaster — arquitetura e configuração completa

Documento de referência: **tudo que existe, como está ligado e por quê**.
Leia este primeiro; o [`FLUXO.md`](FLUXO.md) é o aprofundamento operacional
(passo a passo do push, bootstrap, depuração).

- [1. O sistema em uma tela](#1-o-sistema-em-uma-tela)
- [2. Os 5 microsserviços](#2-os-5-microsserviços)
- [3. Infraestrutura AWS](#3-infraestrutura-aws)
- [4. Rede](#4-rede)
- [5. Identidade: as 7 roles e nenhuma chave](#5-identidade-as-7-roles-e-nenhuma-chave)
- [6. Secrets e configuração](#6-secrets-e-configuração)
- [7. Entrega contínua: as duas esteiras](#7-entrega-contínua-as-duas-esteiras)
- [8. GitOps: Argo CD e as ondas](#8-gitops-argo-cd-e-as-ondas)
- [9. Ordem de partida](#9-ordem-de-partida)
- [10. Escalabilidade](#10-escalabilidade)
- [11. Inventário de arquivos](#11-inventário-de-arquivos)
- [12. As armadilhas que já custaram caro](#12-as-armadilhas-que-já-custaram-caro)
- [13. Limites conhecidos](#13-limites-conhecidos)

---

## 1. O sistema em uma tela

ToggleMaster é um serviço de *feature flags*: decide se uma funcionalidade está
ligada para um usuário específico. Cinco microsserviços num EKS, com Postgres,
Redis, SQS e DynamoDB atrás.

```
                            Internet
                               │ HTTPS
                    ┌──────────▼───────────┐
                    │  ELB → Traefik       │  subnet pública
                    └──────────┬───────────┘
                               │  roteamento por path
   ┌──────────┬────────────────┼────────────────┬──────────────┐
   │ /auth    │ /flags         │ /target        │ /evaluation  │ /analytics
   ▼          ▼                ▼                ▼              ▼
┌───────┐ ┌────────┐ ┌──────────────┐ ┌────────────────┐ ┌──────────────┐
│ auth  │ │ flag   │ │  targeting   │ │  evaluation    │ │  analytics   │
│  Go   │ │ Python │ │   Python     │ │      Go        │ │   Python     │
└───┬───┘ └───┬────┘ └──────┬───────┘ └───┬────────┬───┘ └───┬──────┬───┘
    │         │             │             │        │         │      │
    ▼         ▼             ▼             │        ▼         ▼      ▼
 ┌─────┐  ┌─────┐      ┌─────┐            │     ┌─────┐  ┌─────┐ ┌────────┐
 │ RDS │  │ RDS │      │ RDS │            │     │ SQS │─▶│ SQS │ │DynamoDB│
 │auth │  │flag │      │targ.│            ▼     └─────┘  └─────┘ └────────┘
 └─────┘  └─────┘      └─────┘        ┌───────┐
                                      │ Redis │
   ▲         ▲             ▲          └───────┘
   └─────────┴─────────────┘
     evaluation chama flag e targeting por DNS interno,
     autenticando com a SERVICE_API_KEY emitida pelo auth
```

**A decisão de uma flag** entra pelo `/evaluation`: ele consulta o cache Redis,
pergunta ao `flag-service` se a flag existe e está ligada, ao `targeting-service`
qual a regra de segmentação, responde ao cliente — e **só então** publica um
evento no SQS. O `analytics-service` consome no próprio ritmo e grava no
DynamoDB.

Esse desacoplamento é deliberado: o caminho quente (responder a decisão) nunca
espera o caminho frio (registrar a métrica).

---

## 2. Os 5 microsserviços

| Serviço | Stack | Porta | Guarda estado em | Fala com |
|---|---|---|---|---|
| `auth-service` | Go 1.25 | 8001 | RDS `auth_db` | — |
| `flag-service` | Python 3.11 | 8002 | RDS `flag_db` | auth (valida chave) |
| `targeting-service` | Python 3.11 | 8003 | RDS `targeting_db` | auth (valida chave) |
| `evaluation-service` | Go 1.25 | 8004 | Redis (cache) | flag, targeting, SQS |
| `analytics-service` | Python 3.11 | 8005 | DynamoDB | SQS (consome) |

Comunicação interna sempre por DNS do Kubernetes
(`<service>.<namespace>.svc.cluster.local`) — nenhum serviço é exposto
diretamente na internet. Cada um vive no seu próprio namespace, de mesmo nome.

**O `auth-service` é especial**: além de validar chaves, ele as *emite*. Um
`POST /admin/keys` autenticado com a `MASTER_KEY` devolve `tm_key_<64 hex>` em
texto plano **uma única vez** — o banco guarda só o hash SHA-256. Isso é o que
dita a ordem de partida do sistema (seção 9).

---

## 3. Infraestrutura AWS

Tudo em `us-east-1`, conta `628409561285`, criado por OpenTofu em
`techchallange3/iac/`.

| Módulo | Recurso | Detalhe que importa |
|---|---|---|
| `vpc` | VPC `10.0.0.0/16`, 6 subnets, 1 NAT | 3 camadas: pública, app privada, db privada |
| `eks` | Cluster `togglemaster-prod` 1.36 | + provider OIDC, que é a base de todo o IRSA |
| `ecr` | 5 repositórios | `IMMUTABLE` + scan on push + lifecycle de 10 imagens |
| `rds` | 3 Postgres `db.t3.micro` | **instâncias separadas**, senha por `random_password` |
| `elasticache` | Redis Serverless | **TLS obrigatório** — ver seção 12 |
| `sqs` | fila `evaluation` + DLQ | desacopla evaluation de analytics |
| `dynamodb` | `ToggleMasterAnalytics` | eventos de avaliação |
| `app-secrets` | 5 secrets no Secrets Manager | + gera a `MASTER_KEY` |
| `irsa` | fábrica de roles (usada 5×) | trust por `system:serviceaccount:<ns>:<sa>` |
| `github-oidc` | 2 roles do GitHub Actions | ECR e Terraform, separadas |

**Três bancos e não um compartilhado** é escolha de arquitetura: cada serviço é
dono do seu schema, e uma migração num não trava os outros.

---

## 4. Rede

```
VPC 10.0.0.0/16
├── pública        10.0.0.0/24,  10.0.1.0/24   → ELB do Traefik, NAT Gateway
├── app privada    10.0.10.0/24, 10.0.11.0/24  → nós do EKS (todos os pods)
└── db privada     10.0.20.0/24, 10.0.21.0/24  → RDS, ElastiCache
```

Os pods têm IP da subnet app-privada e saem para a internet pelo NAT. RDS e
Redis só aceitam conexão vinda do security group do cluster — não têm rota da
internet.

**Acesso à API do cluster**: endpoint público **restrito ao seu IP**, vindo da
variable de repositório `EKS_PUBLIC_ACCESS_CIDRS`. O IP não está no git porque
muda quando a operadora troca. Trocou? Um comando, sem commit:

```bash
gh api -X PATCH repos/LuizFelipeCibulski/DEVOPS-ARQCLOUD/actions/variables/EKS_PUBLIC_ACCESS_CIDRS \
  -f name=EKS_PUBLIC_ACCESS_CIDRS -f "value=[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

Sintoma de IP desatualizado: `kubectl` dá **timeout**. Se der **Unauthorized**,
é outra coisa — é IAM (`aws-auth`), não rede.

---

## 5. Identidade: as 7 roles e nenhuma chave

O princípio que atravessa todo o projeto: **não existe credencial de longa
duração em lugar nenhum**. Nem no GitHub, nem no cluster, nem em Secret do
Kubernetes.

### GitHub Actions → AWS (OIDC)

O GitHub apresenta um JWT assinado; a AWS valida contra o provider OIDC e
devolve credencial temporária. O secret `AWS_ROLE_TO_ASSUME` guarda só um ARN —
não é segredo. Quem protege é a *trust policy*.

| Role | Secret | Pode | Confia em |
|---|---|---|---|
| `github-actions-ecr-push` | `AWS_ROLE_TO_ASSUME` | push nos 5 repos ECR | `...:ref:refs/heads/main` |
| `togglemaster-github-terraform` | `AWS_TERRAFORM_ROLE_ARN` | PowerUser + IAM + state | `...:ref:refs/heads/main` **e** `...:environment:production` |

São duas de propósito: uma role capaz de destruir RDS e EKS não deve ser a mesma
que 5 pipelines de microsserviço usam para publicar imagem.

O `:environment:production` na segunda não é detalhe — ver seção 12.

### Pod → AWS (IRSA)

Mesma mecânica, dentro do cluster: o kubelet injeta um JWT assinado pelo issuer
do EKS e o SDK troca por credencial temporária. A amarração é o claim
`sub = system:serviceaccount:<namespace>:<sa>` — uma ServiceAccount de outro
namespace não assume a role nem sabendo o ARN.

| Role | ServiceAccount | Permissão |
|---|---|---|
| `togglemaster-external-secrets` | `external-secrets/external-secrets` | ler os 5 secrets do projeto |
| `togglemaster-auth-bootstrap` | `auth-service/auth-bootstrap` | escrever **só** o `service-api-key` |
| `togglemaster-analytics-service` | `analytics-service/analytics-service` | consumir SQS + gravar DynamoDB |
| `togglemaster-evaluation-service` | `evaluation-service/evaluation-service` | só `SendMessage` na fila |
| `togglemaster-keda-operator` | `keda/keda-operator` | ler profundidade da fila |

Repare no que **não** está na lista: o `auth-service`. Ele não fala com a AWS —
quem fala é o Job de bootstrap, com identidade própria e escopo de um único
secret. Se o pod do auth for comprometido, não há credencial AWS para roubar.

### Serviço → serviço

Pela `SERVICE_API_KEY`, emitida pelo auth e distribuída via Secrets Manager.

---

## 6. Secrets e configuração

**Nenhum valor sensível está no git.** O que é versionado é um `ExternalSecret`,
que só cita o *caminho* do segredo no cofre.

```
Terraform gera (random_password)
        │
        ▼
AWS Secrets Manager   togglemaster/prod/auth-service
        │             {"DATABASE_URL":"…","MASTER_KEY":"…"}
        │  External Secrets Operator lê via IRSA
        ▼
Secret do Kubernetes  auth-secrets
        │  secretKeyRef
        ▼
variável de ambiente no container
```

| Cofre | Chaves | Escrito por | Vira o Secret | Refresh |
|---|---|---|---|---|
| `togglemaster/prod/auth-service` | `DATABASE_URL`, `MASTER_KEY` | Terraform | `auth-secrets` | 1h |
| `togglemaster/prod/flag-service` | `DATABASE_URL` | Terraform | `flag-secrets` | 1h |
| `togglemaster/prod/targeting-service` | `DATABASE_URL` | Terraform | `targeting-secrets` | 1h |
| `togglemaster/prod/evaluation-service` | `REDIS_URL` | Terraform | `evaluation-secrets` | 1m |
| `togglemaster/prod/service-api-key` | `SERVICE_API_KEY` | **Job de bootstrap** | `evaluation-secrets` | 1m |

**Por que o `service-api-key` tem cofre próprio.** O Terraform cria o *container*
do secret mas **nenhuma versão** dele. Se ele gerenciasse o conteúdo, todo
`apply` sobrescreveria a chave cunhada pelo Job — e o evaluation-service, que já
tem a antiga em memória, passaria a levar 403 do flag e do targeting.

**O `analytics-service` não tem ExternalSecret nenhum.** Ele não precisa de
segredo: acesso à AWS é IRSA, e o resto é config.

**O que é config e não secret.** `AWS_SQS_URL`, `AWS_DYNAMODB_TABLE` e
`AWS_REGION` vivem no ConfigMap, versionados. Nunca foram segredo — são nomes de
recurso. Guardá-los no cofre só dificultava a operação sem proteger nada.

### Schema dos bancos

O Terraform cria a instância e o banco, mas **não cria tabela**. Cada serviço com
Postgres tem um `db-migration.yaml`: ConfigMap com o schema + Job que roda
`psql` na onda 1, antes do Deployment (onda 2).

É hook de `Sync` e não `PreSync` porque precisa rodar **depois** do
`ExternalSecret` materializar a `DATABASE_URL`; um `PreSync` travaria toda
instalação nova.

O SQL espelha `docker/<svc>/db/init.sql` sem o `CREATE DATABASE` e o `\c`, que só
fazem sentido num Postgres local. **Mudou o schema? Atualize os dois arquivos.**

---

## 7. Entrega contínua: as duas esteiras

| | Esteira A — infra | Esteira B — aplicação |
|---|---|---|
| Dispara com | `techchallange3/iac/**` | `techchallange3/docker/<svc>/**` |
| Workflow | `terraform.yml` | `<svc>-service.yml` (×5) |
| Ferramenta | OpenTofu 1.11.6 | Docker + Trivy + ECR |
| Aprovação manual | **sim**, no apply | não |
| Termina em | recursos na AWS | tag nova commitada na main |

### Portões de segurança

| Etapa | Ferramenta | Bloqueia quando |
|---|---|---|
| Lint | golangci-lint / flake8 | qualquer achado |
| SCA | Trivy `fs` | HIGH/CRITICAL com correção |
| SAST | gosec / bandit | severidade alta |
| Imagem | Trivy `image` | HIGH/CRITICAL com correção |
| IaC | Trivy `config` | HIGH/CRITICAL |

O que bloqueia é o `exit-code: '1'`. Tirar isso transforma o pipeline em teatro.

### O último step: GitOps

Depois do push no ECR, o job reescreve a tag em
`kubernetes/<svc>/deployment.yaml` e commita na main. O Argo CD sincroniza a
partir daí — **o pipeline nunca roda `kubectl apply`**.

Duas escolhas nesse step que parecem estranhas até você tropeçar nelas:

- **`sed` e não uma action de "update yaml"**: o `yq` reescreve o arquivo inteiro
  no estilo dele, e cada deploy viraria um diff de ~40 linhas no histórico que o
  Argo CD usa como fonte da verdade.
- **Laço de rebase-e-retry e não `concurrency`**: cinco serviços podem terminar
  juntos e commitar na main ao mesmo tempo. A fila do GitHub guarda só **um** job
  pendente por grupo e cancela os anteriores — com `concurrency`, três
  atualizações sumiriam caladas. Já foi validado em produção com 5 commits
  simultâneos, nenhum perdido.

O push do bot usa `GITHUB_TOKEN`, que por design não dispara workflows: sem loop.

---

## 8. GitOps: Argo CD e as ondas

As Applications são arquivos em `kubernetes/argocd/apps/`. A `root` aplica o
diretório e gerencia a si mesma.

Todas com `automated: {prune: true, selfHeal: true}` — o git é a verdade
absoluta: mudança feita à mão via `kubectl` é desfeita, e manifesto apagado do
repositório é removido do cluster.

| Onda | Application | Por que nessa posição |
|---|---|---|
| −20 | `external-secrets`, `keda` | instalam as CRDs que os outros usam |
| −10 | `secret-stores` | o `ClusterSecretStore` precisa da CRD do ESO |
| 20 | `auth-service` | emite a chave que o evaluation espera |
| 30 | `flag-service`, `targeting-service` | validam chave contra o auth |
| 40 | `evaluation-service`, `analytics-service` | dependem da chave e da fila |

Dentro de cada app com banco há uma segunda ordenação: ExternalSecret (0) →
migração (1) → Deployment (2).

O Argo CD faz *polling* do git a cada 3 minutos. O deploy não é instantâneo — é o
padrão, não defeito.

**`ignoreDifferences` em `/spec/replicas`** nas apps de `analytics` e
`evaluation`: o HPA e o KEDA são os donos do número de réplicas. Sem essa
exceção, o git diz `replicas: 1`, o KEDA zera quando a fila esvazia, o `selfHeal`
devolve para 1 — cabo de guerra que nunca converge e ainda anula o scale-to-zero.

---

## 9. Ordem de partida

O único ponto do sistema com ordem obrigatória.

**A `MASTER_KEY` não é gerada pelo auth-service** — ela é *entrada* dele
(`main.go:36`, `log.Fatal` se faltar). Quem gera é o Terraform.

**O que o auth gera é a `SERVICE_API_KEY`**, e o texto plano aparece uma única
vez (`handlers.go:58`). Não há como recuperá-la depois nem como o Terraform
adivinhá-la. Daí a sequência:

```
1. Terraform          MASTER_KEY  →  Secrets Manager
2. ESO                materializa auth-secrets
3. Job de migração    cria a tabela api_keys          (onda 1)
4. auth-service       sobe                            (onda 2 da app, onda 20 global)
5. Job auth-bootstrap hook PostSync, roda quando o auth está Healthy
                      → espera /health (até 2 min)
                      → POST /admin/keys
                      → grava em togglemaster/prod/service-api-key
6. ESO                materializa SERVICE_API_KEY (refresh de 1 min)
7. evaluation-service sobe                            (onda 40)
```

**O Job é idempotente**: consulta o cofre antes de cunhar. Sem isso, cada
sincronização emitiria uma chave nova e o evaluation começaria a receber 403.

---

## 10. Escalabilidade

| Serviço | Mecanismo | Gatilho |
|---|---|---|
| `evaluation-service` | HPA | CPU |
| `analytics-service` | KEDA `ScaledObject` | profundidade da fila SQS, 0→10 réplicas |

O `analytics` faz **scale-to-zero**: fila vazia, nenhum pod. Ver o deployment em
`0/0` é o comportamento correto, não uma falha. O KEDA lê a fila via IRSA
(`TriggerAuthentication` com `podIdentity: aws`), sem chave.

O `metrics-server` está instalado — sem ele o HPA por CPU não funciona.

---

## 11. Inventário de arquivos

```
techchallange3/
├── ARQUITETURA.md          ← este documento
├── FLUXO.md                ← passo a passo operacional e depuração
├── update-secrets-aws.sh   ← só para modo AWS Academy (não usado hoje)
│
├── docker/<svc>/           ← código-fonte + Dockerfile + db/init.sql
│
├── iac/
│   ├── main.tf             ← liga os módulos; as 5 roles IRSA vivem aqui
│   ├── variables.tf  outputs.tf  providers.tf
│   ├── prod.auto.tfvars    ← VERSIONADO: sem ele o CI destruiria a role do ECR
│   ├── .terraform.lock.hcl ← VERSIONADO: fixa versões entre sua máquina e o CI
│   └── modules/            ← vpc ecr eks rds elasticache sqs dynamodb
│                              app-secrets irsa github-oidc
└── kubernetes/
    ├── argocd/apps/        ← app-of-apps (9 Applications)
    ├── external-secrets/   ← ClusterSecretStore
    ├── <svc>/              ← namespace, configmap, deployment, service
    │                          + externalsecret, serviceaccount,
    │                            db-migration, hpa, conforme o serviço
    ├── traefik/            ← IngressRoute e middlewares de strip-prefix
    ├── keda/               ← só documentação: o install virou Application
    └── metrics-server/
```

Secrets e variables esperados no repositório:

| Nome | Tipo | Usado por |
|---|---|---|
| `AWS_ROLE_TO_ASSUME` | secret | os 5 pipelines de microsserviço |
| `AWS_TERRAFORM_ROLE_ARN` | secret | `terraform.yml` |
| `AWS_MODE` | variable | `terraform.yml` (`normal`) |
| `EKS_PUBLIC_ACCESS_CIDRS` | variable | `terraform.yml` |

---

## 12. As armadilhas que já custaram caro

Todas essas foram encontradas na prática neste projeto. Estão aqui para não
custarem de novo.

**`environment: production` muda o token OIDC.** Um job com `environment:` recebe
o claim `sub` como `repo:<owner>/<repo>:environment:production`, e não
`...:ref:refs/heads/main`. O `plan` autenticava e o `apply` morria com
*"Not authorized to perform sts:AssumeRoleWithWebIdentity"*. A role do Terraform
aceita os dois formatos; a variável `terraform_environments` controla a lista.
**Adicionar um environment novo exige adicioná-lo ali.**

**ElastiCache Serverless exige TLS, sempre.** Não é opcional nem desligável. Com
`redis://` o TCP conecta, o servidor espera um handshake que nunca chega, e o
cliente morre com `read tcp …: i/o timeout` — nunca com "conexão recusada". A URL
tem que ser `rediss://`. O módulo expõe `url_scheme` justamente para isso.

**O Terraform não cria tabela.** Criar a instância RDS e o banco não cria schema.
Foi o que derrubou o auth-service com `relation "api_keys" does not exist` e, em
cascata, o evaluation. Resolvido pelos `db-migration.yaml`.

**Um hook PostSync pode travar a Application.** Enquanto uma operação está em
andamento, o Argo CD **não pega a revisão nova** — inclusive a que corrigiria o
problema. Com `backoffLimit: 5` e 5 minutos por tentativa, um auth quebrado
segurava a sync por meia hora. Hoje é `backoffLimit: 2` e espera de 2 minutos:
falhar rápido devolve o controle ao loop de retry.

**Cancelar uma sync no meio de um hook deixa lixo.** O Job fica preso no
finalizer `argocd.argoproj.io/hook-finalizer` e não some nem com
`kubectl delete`. Remova o finalizer:

```bash
kubectl patch job <nome> -n <ns> --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

**Arquivo que não é manifesto derruba a Application inteira.** Um
`keda-sqs-policy.json` dentro do path sincronizado fazia o Argo CD falhar com
`Object 'Kind' is missing`, e nem os manifestos válidos eram avaliados. Só
manifesto Kubernetes dentro de diretório sincronizado.

**`:latest` não existe.** Os repositórios ECR são `IMMUTABLE` e os pipelines só
publicam `v1.0.0-<sha>`. Um manifesto apontando para `:latest` dá
`ImagePullBackOff` para sempre. E "Re-run jobs" no mesmo commit falha com
`ImageTagAlreadyExistsException` — faça um commit novo.

**`terraform.tfvars` não é versionado.** Por isso existe o `prod.auto.tfvars`: o
runner do CI não tem o seu arquivo local, e com os defaults o apply destruiria a
role do ECR e cortaria o acesso ao cluster.

**O lock file é do OpenTofu.** Referencia `registry.opentofu.org`; o binário da
HashiCorp o recusa. Use `tofu`, não `terraform`.

**CRDs grandes precisam de `ServerSideApply=true`.** ESO e KEDA estouram o limite
do apply client-side: `metadata.annotations: Too long`.

---

## 13. Limites conhecidos

Honestidade sobre o que não está automatizado:

1. **Bootstrap inicial** — alguém precisa criar a primeira credencial. Sequência
   em [`FLUXO.md`](FLUXO.md#8-bootstrap-o-que-rodar-uma-vez).
2. **Instalação do Argo CD** — quem gerencia o GitOps não pode ser gerenciado por
   ele mesmo.
3. **`aws-auth` em `CONFIG_MAP`** — só o principal que criou o cluster tem
   acesso. Migrar para `API_AND_CONFIG_MAP` permitiria gerenciar acessos por
   Terraform (`aws_eks_access_entry`).
4. **Polling de 3 minutos** — um webhook do GitHub para o Argo CD deixaria o
   deploy quase instantâneo.
5. **Sem rotação automática de secrets** — o Secrets Manager suporta rotação por
   Lambda; hoje a troca é manual via `tofu taint`.
6. **`PowerUserAccess` + `IAMFullAccess` na role do Terraform** — cobre tudo, mas
   é mais amplo que o necessário.
7. **Schema duplicado** — `docker/<svc>/db/init.sql` e o ConfigMap em
   `kubernetes/<svc>/db-migration.yaml` precisam ser mantidos em sincronia à mão.
8. **Sem observabilidade** — não há Prometheus, Grafana nem tracing. O que existe
   é `kubectl logs` e as métricas de CPU do metrics-server.
