# ToggleMaster — o fluxo completo, do push ao pod rodando

Passo a passo operacional: o que acontece quando você dá `git push`, o bootstrap,
a operação do dia a dia e como depurar quando trava.

> Para a visão de arquitetura — o que existe, como está ligado e por quê —
> comece por [`ARQUITETURA.md`](ARQUITETURA.md).

- [1. Visão geral em 60 segundos](#1-visão-geral-em-60-segundos)
- [2. As duas esteiras](#2-as-duas-esteiras)
- [3. Esteira A — infraestrutura (Terraform)](#3-esteira-a--infraestrutura-terraform)
- [4. Esteira B — aplicação (imagem + GitOps)](#4-esteira-b--aplicação-imagem--gitops)
- [5. Como os secrets chegam no pod](#5-como-os-secrets-chegam-no-pod)
- [6. A ordem de partida e o problema da SERVICE_API_KEY](#6-a-ordem-de-partida-e-o-problema-da-service_api_key)
- [7. Autenticação: nenhuma chave estática em lugar nenhum](#7-autenticação-nenhuma-chave-estática-em-lugar-nenhum)
- [8. Bootstrap: o que rodar uma vez](#8-bootstrap-o-que-rodar-uma-vez)
- [9. Operação do dia a dia](#9-operação-do-dia-a-dia)
- [10. Depuração: sintoma → causa](#10-depuração-sintoma--causa)
- [11. Decisões de projeto e seus porquês](#11-decisões-de-projeto-e-seus-porquês)
- [12. O que continua manual](#12-o-que-continua-manual)

---

## 1. Visão geral em 60 segundos

```
                          git push na main
                                 │
                 ┌───────────────┴────────────────┐
                 ▼                                ▼
      mexeu em iac/**                   mexeu em docker/<svc>/**
                 │                                │
        [terraform.yml]                  [<svc>-service.yml]
     fmt → scan → plan → apply         test → lint → scan → build
                 │      (aprovação)      → Trivy → push no ECR
                 │       manual)                  │
                 ▼                                ▼
      AWS: VPC, EKS, RDS,              reescreve a tag em
      Redis, SQS, DynamoDB,            kubernetes/<svc>/deployment.yaml
      Secrets Manager, IAM             e commita na main
                 │                                │
                 └───────────────┬────────────────┘
                                 ▼
                          [Argo CD] observa a main
                                 │
                    aplica os manifestos no cluster
                                 │
                    ExternalSecret puxa do Secrets Manager
                                 ▼
                             pod rodando
```

Duas coisas nunca se cruzam: **valor de segredo nunca entra no git**, e
**credencial estática da AWS não existe** — nem no GitHub, nem no cluster.

---

## 2. As duas esteiras

| | Esteira A — infra | Esteira B — aplicação |
|---|---|---|
| Dispara com | mudança em `techchallange3/iac/**` | mudança em `techchallange3/docker/<svc>/**` |
| Workflow | `.github/workflows/terraform.yml` | `.github/workflows/<svc>-service.yml` |
| Ferramenta | OpenTofu 1.11.6 | Docker + Trivy + ECR |
| Autentica com | `AWS_TERRAFORM_ROLE_ARN` | `AWS_ROLE_TO_ASSUME` |
| Termina em | recursos na AWS | tag nova commitada na main |
| Quem aplica no cluster | — | Argo CD |
| Aprovação manual | **sim**, no apply | não |

As duas são independentes. Um push que mexe só na app não roda Terraform, e
vice-versa. Um push que mexe nos dois roda as duas em paralelo.

---

## 3. Esteira A — infraestrutura (Terraform)

`terraform.yml`, 4 jobs em cadeia:

```
1. fmt-validate  →  2. security-scan  →  3. plan  →  4. apply
   tofu fmt -check    Trivy config        sempre      só push na main
   tofu validate      nos .tf             roda        + APROVAÇÃO MANUAL
                                                      (environment: production)
```

Pontos que valem entender:

**O plano vira artefato.** O job `plan` faz upload do `tfplan`; o `apply` baixa
e roda `tofu apply tfplan`. Ele nunca gera um plano novo na hora de aplicar —
então você aplica exatamente o que foi revisado.

**`concurrency: terraform-iac`, sem cancelar.** Dois applies simultâneos
corrompem o state, e cancelar um apply no meio é pior que deixar terminar.

**OpenTofu, não Terraform.** O `.terraform.lock.hcl` do repositório foi gerado
pelo `tofu` e referencia `registry.opentofu.org`. O Terraform da HashiCorp
recusa esse lock file. Se algum dia trocar de ferramenta, apague o lock e
regenere.

### O arquivo que impede o CI de destruir tudo

`techchallange3/iac/prod.auto.tfvars` é **versionado de propósito**. O runner do
CI não tem o seu `terraform.tfvars` local, e sem esse arquivo o apply usaria os
defaults de `variables.tf` — que fariam duas coisas graves:

- `enable_github_oidc = false` → **destruiria** a role `github-actions-ecr-push`,
  quebrando os 5 pipelines de microsserviço na hora seguinte;
- `endpoint_public_access = false` → **cortaria o seu acesso via kubectl**.

Não há nada sensível nesse arquivo: são liga/desliga e nomes de recurso.

A única exceção é o CIDR liberado na API do cluster — o IP de quem administra.
Ele muda sozinho quando a operadora troca e não pertence ao repositório, então
vem da **variable de repositório** `EKS_PUBLIC_ACCESS_CIDRS`, que o
`terraform.yml` injeta como `TF_VAR_public_access_cidrs`.

Trocou de IP? Um comando, sem commit:

```bash
gh api -X PATCH repos/LuizFelipeCibulski/DEVOPS-ARQCLOUD/actions/variables/EKS_PUBLIC_ACCESS_CIDRS \
  -f name=EKS_PUBLIC_ACCESS_CIDRS -f "value=[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

Localmente nada muda: `terraform.tfvars` tem precedência sobre `TF_VAR_*`.

### O que o Terraform cria

| Módulo | Entrega |
|---|---|
| `vpc` | rede em 3 camadas (pública / app privada / db privada) |
| `eks` | cluster + node group + provider OIDC (base do IRSA) |
| `ecr` | 5 repositórios, tags imutáveis |
| `rds` | 3 Postgres independentes, senha via `random_password` |
| `elasticache` | Redis serverless |
| `sqs` / `dynamodb` | fila + DLQ, tabela de eventos |
| `github-oidc` | role de push no ECR **+** role do próprio `terraform.yml` |
| `app-secrets` | 5 secrets no Secrets Manager + a `MASTER_KEY` |
| `irsa` (×5) | uma role por identidade que fala com a AWS de dentro do cluster |

---

## 4. Esteira B — aplicação (imagem + GitOps)

Os 5 workflows são idênticos exceto pelo molde de linguagem (Go × Python).
Quatro jobs:

```
1. build-test  →  2. lint  →  3. security-scan  →  4. docker-build-push
                                SCA (Trivy fs)      build → Trivy image
                                SAST (gosec/bandit) → OIDC → push ECR
                                                    → reescreve a tag no git
```

O último step é o que fecha o ciclo com o Argo CD. Duas escolhas nele que
parecem estranhas até você tropeçar nelas:

**`sed` em vez de uma action de "update yaml".** O `yq` e as actions que o
embrulham reescrevem o arquivo inteiro no estilo de indentação delas — cada
deploy viraria um diff de ~40 linhas em vez de 1, poluindo justamente o
histórico que o Argo CD usa como fonte da verdade. O `sed` é ancorado no nome do
repositório ECR, com verificação antes (existe exatamente uma linha `image:`) e
depois (a nova tag entrou).

**Laço de rebase-e-tenta-de-novo, e não `concurrency`.** Um commit que toca dois
serviços dispara dois workflows; os dois terminam o build juntos e tentam
commitar na `main` ao mesmo tempo. O segundo push morre com non-fast-forward e
o manifesto fica com a tag velha — **sem erro visível**, o Argo CD sincroniza a
imagem antiga. `concurrency` não resolveria: a fila do GitHub guarda só **um**
job pendente por grupo e cancela os anteriores, então com 5 serviços
simultâneos três atualizações sumiriam caladas.

O push do bot usa `GITHUB_TOKEN`, que por design **não dispara** novos
workflows — não há loop. O `paths` de cada workflow também não cobre
`kubernetes/**`.

### Argo CD: app-of-apps

As Applications deixaram de ser criadas pela UI e viraram arquivos em
`techchallange3/kubernetes/argocd/apps/`. A `root` aplica o diretório inteiro e
gerencia a si mesma.

Todas com `automated: {prune: true, selfHeal: true}` — o git é a verdade
absoluta: mudança feita à mão via `kubectl` é desfeita, e manifesto apagado do
repositório é removido do cluster.

As ondas (`argocd.argoproj.io/sync-wave`) resolvem a ordem:

| Onda | Application | Por quê nessa posição |
|---|---|---|
| −20 | `external-secrets`, `keda` | instalam as CRDs que os outros usam |
| −10 | `secret-stores` | o `ClusterSecretStore` precisa da CRD do ESO |
| 20 | `auth-service` | emite a `SERVICE_API_KEY` que o evaluation espera |
| 30 | `flag-service`, `targeting-service` | validam API key contra o auth |
| 40 | `evaluation-service`, `analytics-service` | dependem da chave e da fila |

Argo CD faz *polling* do repositório a cada 3 minutos. É por isso que o deploy
não é instantâneo depois do push — e é o comportamento padrão, não um defeito.

---

## 5. Como os secrets chegam no pod

O ponto central: **nenhum valor de segredo existe no repositório**. O que está
versionado é um `ExternalSecret`, que só cita o *caminho* do segredo no cofre.

```
Terraform gera a senha (random_password)
        │
        ▼
AWS Secrets Manager        togglemaster/prod/auth-service
   {"DATABASE_URL": "...", "MASTER_KEY": "..."}
        │
        │  External Secrets Operator lê (IRSA, sem chave)
        ▼
Secret do Kubernetes       auth-secrets (namespace auth-service)
        │
        │  secretKeyRef no Deployment
        ▼
variável de ambiente no container
```

### O mapa completo

| Cofre no Secrets Manager | Chaves | Quem escreve | Vira o Secret |
|---|---|---|---|
| `togglemaster/prod/auth-service` | `DATABASE_URL`, `MASTER_KEY` | Terraform | `auth-secrets` |
| `togglemaster/prod/flag-service` | `DATABASE_URL` | Terraform | `flag-secrets` |
| `togglemaster/prod/targeting-service` | `DATABASE_URL` | Terraform | `targeting-secrets` |
| `togglemaster/prod/evaluation-service` | `REDIS_URL` | Terraform | `evaluation-secrets` |
| `togglemaster/prod/service-api-key` | `SERVICE_API_KEY` | **Job de bootstrap** | `evaluation-secrets` |

### Schema dos bancos

O Terraform cria a instância RDS e o banco, mas **não cria tabela**. Cada serviço
com Postgres tem um `db-migration.yaml` (ConfigMap com o schema + Job que roda
`psql`), na onda 1, antes do Deployment (onda 2).

É hook de `Sync` e não `PreSync`: precisa rodar depois do `ExternalSecret`
materializar a `DATABASE_URL`. Um `PreSync` travaria toda instalação nova.

O `analytics-service` não tem `ExternalSecret` nenhum: ele não precisa de
segredo. Tudo que ele consome — URL da fila, nome da tabela — é identificador
público e mora no ConfigMap; e o acesso à AWS é via IRSA.

**O que é config e o que é secret.** `AWS_SQS_URL` e `AWS_DYNAMODB_TABLE`
saíram do Secret e foram para o ConfigMap. Eles nunca foram segredo — são nomes
de recurso. Colocá-los no cofre só tornava a operação mais difícil sem
proteger nada.

### Por que dois cofres para o evaluation-service

O `SERVICE_API_KEY` fica num cofre separado porque **o Terraform não pode
gerenciá-lo**. Se ele estivesse no mesmo `aws_secretsmanager_secret_version` dos
outros valores, todo `tofu apply` sobrescreveria a chave cunhada pelo Job — e o
evaluation-service passaria a levar 403 do flag e do targeting.

Por isso o Terraform cria o *container* do secret (para o ESO ter um caminho
estável e a IAM policy ter um ARN para referenciar) mas **nenhuma versão** dele.
Ver `iac/modules/app-secrets/main.tf`.

---

## 6. A ordem de partida e o problema da SERVICE_API_KEY

Este é o único ponto do sistema com ordem obrigatória, e vale entender o porquê.

**A `MASTER_KEY` não é gerada pelo auth-service.** Ela é *entrada* dele
(`docker/auth-service/main.go:36` — `log.Fatal` se faltar). Quem a gera é o
Terraform, com `random_password`.

**O que o auth-service gera é a `SERVICE_API_KEY`.** Um `POST /admin/keys`
autenticado com a `MASTER_KEY` devolve `tm_key_<64 hex>` **em texto plano uma
única vez** — o banco guarda apenas o hash SHA-256
(`docker/auth-service/handlers.go:58` e `key.go`). Não há como recuperar a chave
depois, nem como o Terraform adivinhá-la.

Daí a sequência:

```
1. Terraform          gera MASTER_KEY  →  Secrets Manager
2. ESO                materializa auth-secrets no cluster
3. auth-service       sobe com DATABASE_URL + MASTER_KEY        (onda 20)
4. Job auth-bootstrap hook PostSync, roda quando o auth está Healthy
                      → espera /health responder (até 5 min)
                      → POST /admin/keys com a MASTER_KEY
                      → grava a chave em togglemaster/prod/service-api-key
5. ESO                materializa SERVICE_API_KEY em evaluation-secrets
                      (refreshInterval de 1 minuto neste caso)
6. evaluation-service sobe                                      (onda 40)
```

**O Job é idempotente.** Antes de cunhar, ele consulta o cofre: se
`SERVICE_API_KEY` já existe, sai com sucesso sem fazer nada. Sem isso, cada
sincronização do Argo CD emitiria uma chave nova e sobrescreveria a anterior —
e o evaluation-service, que já tem a antiga em memória, começaria a receber 403.

**Por que `PostSync` e não um Job comum.** Um Job comum subiria junto com o
Deployment e tentaria falar com um Service que ainda não tem endpoint. O hook
`PostSync` do Argo CD só dispara depois que o auth-service está `Healthy`.

O `refreshInterval` do `ExternalSecret` do evaluation é de **1 minuto** (contra
1 hora dos outros) exatamente por causa deste passo: com 1h, a primeira
implantação deixaria o evaluation esperando até uma hora por uma chave que já
existe.

---

## 7. Autenticação: nenhuma chave estática em lugar nenhum

Três fronteiras, três mecanismos, zero segredos de longa duração.

### GitHub Actions → AWS (OIDC)

O GitHub apresenta um JWT assinado; a AWS valida contra o provider OIDC e
devolve credencial temporária. O secret `AWS_ROLE_TO_ASSUME` guarda só um ARN —
não é segredo de verdade. Quem protege é a *trust policy*:

```
repo:LuizFelipeCibulski/DEVOPS-ARQCLOUD:ref:refs/heads/main
```

Isso casa com o `if: github.ref == 'refs/heads/main'` dos workflows: **um PR de
terceiros não consegue credencial**, nem que alguém remova o `if` do YAML. Duas
camadas.

São duas roles separadas de propósito. Uma capaz de destruir RDS e EKS não deve
ser a mesma que 5 pipelines de microsserviço usam para publicar imagem:

| Role | Secret | Pode |
|---|---|---|
| `github-actions-ecr-push` | `AWS_ROLE_TO_ASSUME` | push só nos 5 repos ECR deste projeto |
| `togglemaster-github-terraform` | `AWS_TERRAFORM_ROLE_ARN` | PowerUser + IAM + state no S3/DynamoDB |

### Pod → AWS (IRSA)

Mesma ideia, para dentro do cluster: o kubelet injeta um JWT assinado pelo
issuer do EKS, o SDK troca por credencial temporária. A amarração é o claim
`sub` = `system:serviceaccount:<namespace>:<sa>` — uma ServiceAccount de outro
namespace não assume a role nem sabendo o ARN.

| Role | ServiceAccount | Pode |
|---|---|---|
| `togglemaster-external-secrets` | `external-secrets/external-secrets` | ler os 5 secrets do projeto |
| `togglemaster-auth-bootstrap` | `auth-service/auth-bootstrap` | escrever **só** o `service-api-key` |
| `togglemaster-analytics-service` | `analytics-service/analytics-service` | consumir SQS + gravar DynamoDB |
| `togglemaster-evaluation-service` | `evaluation-service/evaluation-service` | só `SendMessage` na fila |
| `togglemaster-keda-operator` | `keda/keda-operator` | ler a profundidade da fila |

O auth-service em si **não tem role nenhuma** — ele não fala com a AWS. Quem
fala é o Job de bootstrap, com uma SA separada e escopo de um único secret.

### Serviço → serviço (SERVICE_API_KEY)

Dentro do cluster, via DNS interno (`<svc>.<ns>.svc.cluster.local`), com a API
key emitida pelo auth-service. Nenhum serviço é exposto diretamente; a entrada
é o Traefik.

---

## 8. Bootstrap: o que rodar uma vez

Ovo e galinha: quem cria a role do Terraform é o Terraform. Resolve-se com um
apply local, e daí em diante o pipeline se sustenta.

```bash
cd techchallange3/iac

# 1. Cria as roles IRSA, os secrets e a role do próprio pipeline.
tofu init
tofu apply

# 2. Cadastra o ARN da role do Terraform como secret do repositório.
gh secret set AWS_TERRAFORM_ROLE_ARN --body "$(tofu output -raw github_terraform_role_arn)"

# 3. Liga o pipeline de infra (estava desabilitado).
gh workflow enable terraform.yml

# 4. Coloca o Argo CD sob controle do git (app-of-apps).
kubectl apply -f ../kubernetes/argocd/apps/root.yaml
```

Se você tinha instalado o KEDA à mão, remova o release antes do passo 4 para o
Argo CD poder assumir a posse sem conflito:

```bash
helm uninstall keda -n keda
```

Acompanhe as ondas subindo:

```bash
kubectl get applications -n argocd -w
```

---

## 9. Operação do dia a dia

**Mudou código de um serviço** → push em `techchallange3/docker/<svc>/`. O
pipeline testa, escaneia, publica no ECR, reescreve a tag e commita. O Argo CD
sincroniza em até 3 minutos. Nada a fazer à mão.

**Mudou infraestrutura** → push em `techchallange3/iac/`. O plan roda e comenta
no PR; o apply espera sua aprovação em *Settings → Environments → production*.

**Mudou manifesto do Kubernetes** → push em `techchallange3/kubernetes/<svc>/`.
O Argo CD aplica. Nenhum pipeline roda (é GitOps puro).

**Rodar a mesma imagem de novo** não funciona: os repositórios ECR são
`IMMUTABLE` e a tag é `v1.0.0-<sha curto>`. Um "Re-run jobs" no mesmo commit
falha com `ImageTagAlreadyExistsException`. Faça um commit novo.

**Girar a MASTER_KEY**: `tofu taint` no `random_password.master_key`, apply,
depois apague a `SERVICE_API_KEY` do cofre e deixe o Job cunhar outra.

---

## 10. Depuração: sintoma → causa

| Sintoma | Provável causa |
|---|---|
| `kubectl` dá **timeout** | rede: seu IP saiu do `public_access_cidrs`. Atualize `EKS_PUBLIC_ACCESS_CIDRS` e aplique |
| `kubectl` dá **Unauthorized** | IAM, não rede: seu principal não está no `aws-auth` |
| Application `Unknown` + `ComparisonError` | arquivo que não é manifesto dentro do path sincronizado (foi o que o `keda-sqs-policy.json` causava) |
| Pod em `CreateContainerConfigError` | o Secret ainda não existe — veja o `ExternalSecret` |
| `ExternalSecret` em `SecretSyncedError` | IRSA do ESO: anotação errada na SA, ou o secret não existe no cofre |
| evaluation-service em 403 | `SERVICE_API_KEY` dessincronizada: o Job cunhou uma nova por cima |
| Job `auth-bootstrap` falhando | auth-service não respondeu em 5 min, ou `MASTER_KEY` divergente |
| Pipeline falha antes da AWS | é o gate do Trivy (`exit-code: 1` em HIGH/CRITICAL), não o OIDC |
| `tofu init` reclama do lock | alguém rodou `terraform` no lugar de `tofu` |
| Pod em `CrashLoopBackOff` com `i/o timeout` no Redis | falta o TLS: ElastiCache Serverless só aceita `rediss://` |
| `relation "..." does not exist` | o Job de migração não rodou: `kubectl logs -n <ns> job/<svc>-migrate` |
| apply do Terraform dá `Not authorized to ... AssumeRoleWithWebIdentity` mas o plan passa | o job tem `environment:`, que muda o claim `sub` do token OIDC |
| Application presa em `Running`, ignorando commits novos | hook travado: enquanto há operação em andamento o Argo CD não pega revisão nova |
| Job não some com `kubectl delete` | finalizer `argocd.argoproj.io/hook-finalizer` — remova com `kubectl patch ... --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'` |
| Deployment fica alternando entre 0 e 1 réplica | falta `ignoreDifferences` em `/spec/replicas`: Argo CD brigando com HPA/KEDA |

Comandos que respondem rápido:

```bash
kubectl get applications -n argocd
kubectl get externalsecrets -A
kubectl describe externalsecret <nome> -n <ns>
kubectl logs -n external-secrets deploy/external-secrets
kubectl logs -n auth-service job/auth-bootstrap
```

---

## 11. Decisões de projeto e seus porquês

**External Secrets em vez de Sealed Secrets.** O Terraform já gera as senhas do
RDS; com o ESO elas vão direto do `random_password` para o cofre e de lá para o
cluster, sem passar por humano nem por git. Sealed Secrets exigiria re-selar à
mão a cada rotação.

**`ClusterSecretStore` em vez de um `SecretStore` por namespace.** Os 5 serviços
leem do mesmo cofre com a mesma identidade; um objeto só evita repetir cinco
vezes a mesma configuração.

**`ServerSideApply=true` no ESO e no KEDA.** As CRDs deles são grandes demais
para o apply client-side, que falharia com
`metadata.annotations: Too long: must have at most 262144 bytes`.

**`recovery_window_in_days = 0` nos secrets.** O default da AWS (30 dias) é um
problema em ambiente de estudo: depois de um `destroy`, o nome fica reservado e
o próximo `apply` falha até a janela vencer.

**`check` block no `endpoint_public_access`.** Ligar o endpoint público sem
restringir o CIDR expõe a API do cluster à internet inteira. O bloco emite um
**aviso** em todo plan (não bloqueia) — visível o suficiente para não passar
despercebido, sem travar o pipeline.

**`environment: production` e o claim OIDC.** Um job que declara `environment:`
recebe o `sub` como `repo:<owner>/<repo>:environment:<nome>`, e não o formato de
branch. Por isso a role do Terraform tem trust policy própria, aceitando os dois.
Adicionar um environment novo (staging, por exemplo) exige incluí-lo em
`terraform_environments`.

**`rediss://` para o ElastiCache Serverless.** TLS não é opcional ali. Com
`redis://` o TCP conecta e o cliente morre por timeout de leitura — nunca por
"conexão recusada", o que torna o diagnóstico bem menos óbvio.

**KEDA migrado para o Argo CD.** Estava instalado por `helm install` e
`eksctl create iamserviceaccount`, ambos fora de qualquer versionamento. Agora
o chart é uma Application e a role vem do `module.irsa_keda`.

---

## 12. O que continua manual

Honestidade sobre os limites da automação atual:

1. **O bootstrap da seção 8** — inevitável: alguém precisa criar a primeira
   credencial.
2. **A instalação do Argo CD** (`kubernetes/argocd/install.txt`) — quem
   gerencia o GitOps não pode ser gerenciado por ele mesmo.
3. **O `aws-auth`** — o cluster está em `authenticationMode: CONFIG_MAP`, então
   só o principal que o criou tem acesso. Migrar para `API_AND_CONFIG_MAP`
   permitiria gerenciar acessos por Terraform (`aws_eks_access_entry`).
4. **Webhook do GitHub para o Argo CD** — hoje é polling de 3 minutos.
   Configurar o webhook deixaria o deploy quase instantâneo.
5. **Rotação automática de secrets** — o Secrets Manager suporta rotação
   agendada por Lambda; aqui a troca é manual via `tofu taint`.
6. **`terraform_policy_arns` usa `PowerUserAccess` + `IAMFullAccess`** — cobre
   tudo, mas é mais amplo que o necessário. Uma policy escrita à mão com o
   escopo exato seria o passo seguinte para produção de verdade.
