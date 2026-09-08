# 🔧 Como funciona o CI/CD deste repositório

Guia dos arquivos em `.github/workflows/`. A ideia é que depois de ler isso você
consiga **abrir qualquer um dos YAMLs e saber o que cada bloco faz** — e criar um
workflow novo do zero sem copiar e colar no escuro.

---

## 1. O que existe aqui

| Arquivo | O que faz | Linguagem/alvo |
|---|---|---|
| `auth-service.yml` | Pipeline do auth-service | Go |
| `evaluation-service.yml` | Pipeline do evaluation-service | Go |
| `analytics-service.yml` | Pipeline do analytics-service | Python |
| `flag-service.yml` | Pipeline do flag-service | Python |
| `targeting-service.yml` | Pipeline do targeting-service | Python |
| `terraform.yml` | Pipeline da infraestrutura | Terraform / IaC |

São **3 moldes**, não 6 arquivos diferentes:

- **Molde Go** → `auth-service.yml` e `evaluation-service.yml` são idênticos, mudando
  só `SERVICE_NAME`, `SERVICE_PATH`, `ECR_REPOSITORY`, o `name:` e o `concurrency.group`.
- **Molde Python** → mesma coisa entre `analytics`, `flag` e `targeting`.
- **Molde Terraform** → arquivo único, lógica bem diferente (tem `plan`/`apply`).

> Se você mudar algo em um workflow de microsserviço, provavelmente precisa
> replicar nos outros 4. Não existe workflow reutilizável (`workflow_call`) aqui
> ainda — é uma melhoria natural pro futuro (ver seção 9).

---

## 2. Anatomia de um workflow

Todo arquivo `.yml` do Actions tem a mesma espinha dorsal:

```yaml
name: CI/CD - auth-service        # nome que aparece na aba "Actions"

on:                               # QUANDO roda
  workflow_dispatch:              # botão manual na UI do GitHub

concurrency:                      # evita 2 execuções concorrentes do mesmo alvo
  group: auth-service-${{ github.ref }}
  cancel-in-progress: true

env:                              # variáveis visíveis em TODOS os jobs
  SERVICE_NAME: auth-service
  SERVICE_PATH: techchallange3/docker/auth-service
  GO_VERSION: '1.25'
  AWS_REGION: us-east-1
  ECR_REPOSITORY: auth-service

jobs:                             # O QUE roda
  build-test:                     # <- id do job (usado em "needs:")
    name: "1. Build & Unit Test"  # <- nome bonito na UI
    runs-on: ubuntu-latest        # <- máquina virtual efêmera
    steps:                        # <- lista ordenada de passos
      - uses: actions/checkout@v4 # step que USA uma action pronta
      - run: go build ./...       # step que RODA um comando no shell
```

Conceitos que valem gravar:

- **Job** = uma máquina virtual limpa. Jobs diferentes **não compartilham disco**.
  Por isso todo job começa com `actions/checkout@v4` de novo, e por isso o
  `terraform.yml` precisa de `upload-artifact`/`download-artifact` para passar o
  plano do job 3 para o job 4.
- **Step `uses:`** = chama uma action de terceiros. Aceita `with:` (inputs),
  `if:`, `id:`, `env:`, `name:`, `continue-on-error:`.
  ⚠️ **Não aceita `working-directory:`** — isso só existe em step `run:`.
- **Step `run:`** = roda shell (bash por padrão no Ubuntu). Aceita `working-directory:`.
- **`needs:`** = cria a corrente. `needs: lint` significa "só começa se o job
  `lint` passou". É isso que transforma 4 jobs soltos num pipeline sequencial.
- **`${{ ... }}`** = expressão. Lê de `env`, `secrets`, `vars`, `github`,
  `steps.<id>.outputs`, etc.

### `on:` — os gatilhos

```yaml
on:
  workflow_dispatch:              # botão "Run workflow" na UI
  push:
    branches: [ main ]
    paths:                        # só dispara se ESSES arquivos mudarem
      - 'techchallange3/docker/auth-service/**'
      - '.github/workflows/auth-service.yml'
  pull_request:
    branches: [ main ]
    paths: [ ... ]
```

O `paths:` é o que impede os 5 pipelines de rodarem toda vez que você mexe em
um README. Cada serviço só acorda quando a **pasta dele** (ou o **próprio
workflow**) muda.

> **Estado atual:** nos 5 workflows de microsserviço, `push` e `pull_request`
> estão **comentados** — só sobra o `workflow_dispatch` (execução manual).
> Isso é proposital enquanto o ECR/OIDC não estiver configurado. Para ativar,
> descomente os blocos. O `terraform.yml` já está com os gatilhos ativos.

---

## 3. O pipeline de microsserviço, job a job

Os 4 jobs rodam **em cadeia** — se um falha, os seguintes nem começam:

```
┌──────────────────┐   ┌──────────────┐   ┌───────────────────┐   ┌─────────────────────┐
│ 1. Build & Test  │──▶│ 2. Lint      │──▶│ 3. Security Scan  │──▶│ 4. Docker Build/Push│
│    compila       │   │    qualidade │   │    SAST + SCA     │   │    imagem + scan    │
└──────────────────┘   └──────────────┘   └───────────────────┘   └─────────────────────┘
      needs: —            needs:            needs: lint              needs: security-scan
                          build-test
```

A ordem não é aleatória: o mais barato e mais rápido de falhar vem primeiro.
Não faz sentido gastar 3 minutos buildando uma imagem Docker se o código nem compila.

### Job 1 — `build-test` (o código compila? os testes passam?)

**Go:**
```yaml
    defaults:
      run:
        working-directory: ${{ env.SERVICE_PATH }}   # todo "run:" deste job roda aqui
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
          cache: true                                 # cache de módulos baseado no go.sum
          cache-dependency-path: ${{ env.SERVICE_PATH }}/go.sum
      - run: go mod download
      - run: go build -v ./...
      - run: go test -v -race -coverprofile=coverage.out ./...
```

**Python:** troca `setup-go` por `setup-python` (com `cache: 'pip'`),
`go build` por `python -m py_compile app.py`, e roda `pytest` **só se existirem**
arquivos `test_*.py`:

```yaml
      - run: |
          if find . -name "test_*.py" -o -name "*_test.py" | grep -q .; then
            pytest -v --cov=. --cov-report=xml
          else
            echo "Nenhum teste encontrado ainda - pulando."
          fi
```

Detalhe importante: `defaults.run.working-directory` vale só para steps `run:`.
Steps `uses:` continuam vendo a raiz do repositório — por isso o
`cache-dependency-path` precisa do caminho **completo** (`techchallange3/docker/...`),
e não só `go.sum`.

Ao final sobe o `coverage.out` como artefato (`actions/upload-artifact@v4`) com
`if: always()` — ou seja, sobe mesmo se o job falhou, que é justamente quando você
quer olhar o relatório.

### Job 2 — `lint` (qualidade de código, **não** segurança)

| Go | Python |
|---|---|
| `golangci/golangci-lint-action@v9` | `flake8 . --max-line-length=120` |

O `golangci-lint` é um agregador: roda `errcheck`, `govet`, `staticcheck` e
outros de uma vez. Config opcional em `.golangci.yml` dentro da pasta do serviço.

⚠️ **A versão da action importa:** `@v6` instala o golangci-lint **v1**, que não
suporta Go ≥ 1.25. A linha `@v9` é a que roda o **v2**. Se você subir a versão do
Go, confira essa action junto.

No lado Python, cada serviço tem um `.flake8` que ignora **só** avisos cosméticos
(espaçamento, linha em branco com espaço). A família `F` (import não usado, nome
indefinido) e `E9` (erro de sintaxe) continuam quebrando o build de propósito —
esses são bugs de verdade, não estilo.

### Job 3 — `security-scan` (o coração do DevSecOps)

Esse job roda **duas ferramentas com propósitos diferentes**. A confusão entre
elas é o erro mais comum:

| | **SCA** | **SAST** |
|---|---|---|
| Pergunta | "as bibliotecas que eu **importo** têm CVE?" | "o código que **eu escrevi** tem falha?" |
| Ferramenta | **Trivy** (`scan-type: fs`) | **gosec** (Go) / **bandit** (Python) |
| Lê o quê | `go.mod`, `go.sum`, `requirements.txt` | os `.go` / `.py` |
| Exemplo de achado | `urllib3 1.26.20` tem CVE-2026-xxxx | SQL montado por concatenação, SSRF |

**SCA — Trivy filesystem:**
```yaml
      - uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: 'fs'
          scan-ref: ${{ env.SERVICE_PATH }}
          scanners: 'vuln'
          severity: 'HIGH,CRITICAL'   # só o que interessa, sem ruído
          exit-code: '1'              # <- ISSO é o que bloqueia o pipeline
          ignore-unfixed: true        # ignora CVE que ainda não tem correção
```

`exit-code: '1'` é o que transforma o Trivy de "relatório" em "portão".
Sem ele o job passa verde mesmo cheio de vulnerabilidade.
`ignore-unfixed: true` evita travar o time por CVE que **ninguém pode corrigir**
ainda (não existe versão com fix publicada).

**SAST — gosec (Go):**
```yaml
      - uses: actions/setup-go@v5          # gosec é um binário Go, precisa de Go
        with: { go-version: '${{ env.GO_VERSION }}' }

      - name: "SAST - gosec"
        working-directory: ${{ env.SERVICE_PATH }}
        run: |
          go install github.com/securego/gosec/v2/cmd/gosec@latest
          gosec -severity high -confidence high \
                -fmt sarif -out gosec-results.sarif -stdout -verbose text ./...
```

Rodamos via `run:` **de propósito**. A action `securego/gosec@master` é um step
`uses:`, e step `uses:` não aceita `working-directory:` — o Actions rejeita o
arquivo inteiro com *"unexpected key working-directory"*. Sem conseguir fixar o
diretório, o gosec varreria o repositório inteiro (incluindo `techchallange2`) e
gravaria o SARIF no lugar errado.

**SAST — bandit (Python):**
```yaml
      - run: pip install bandit
      - name: "SAST - bandit"
        working-directory: ${{ env.SERVICE_PATH }}
        run: bandit -r . -lll -f json -o bandit-results.json
```
`-lll` = só severidade **alta** derruba o build (`-l` baixa, `-ll` média, `-lll` alta).

**O relatório SARIF:** o gosec gera `.sarif` e o
`github/codeql-action/upload-sarif@v3` publica na aba **Security → Code scanning**
do repositório. É o formato padrão pra ferramenta de análise estática — o achado
vira um alerta clicável, ancorado na linha do arquivo.

Quando um achado é **falso positivo**, a saída certa não é desligar a
ferramenta — é suprimir de forma pontual e documentada. Exemplo real que está no
`evaluation-service/evaluator.go`:

```go
// #nosec G704 -- host/esquema vêm de env (FLAG/TARGETING_SERVICE_URL), não do usuário;
// o único trecho influenciado pela requisição é o path, já sanitizado com neturl.PathEscape.
req, err := http.NewRequest(http.MethodGet, url, nil)
```

O equivalente no bandit é `# nosec B608`.

### Job 4 — `docker-build-push`

Aqui tem 3 sutilezas que valem entender.

**(a) Build primeiro, push depois — com scan no meio.**
```yaml
      - uses: docker/build-push-action@v6
        with:
          context: ${{ env.SERVICE_PATH }}
          push: false        # <- ainda NÃO envia
          load: true         # <- carrega no daemon local pro Trivy alcançar
          tags: ${{ env.ECR_REPOSITORY }}:${{ steps.vars.outputs.IMAGE_TAG }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: 'image'
          image-ref: ${{ env.ECR_REPOSITORY }}:${{ steps.vars.outputs.IMAGE_TAG }}
          severity: 'HIGH,CRITICAL'
          exit-code: '1'
          ignore-unfixed: true
```
`load: true` é obrigatório: sem ele a imagem fica só no cache do buildx e o Trivy
não acha. `cache-from/to: type=gha` usa o cache do próprio GitHub Actions entre
execuções.

> Esse scan é **diferente** do Trivy do job 3. O job 3 olhou `requirements.txt`.
> Este aqui olha a **imagem inteira** — inclusive os pacotes do sistema
> operacional da imagem base (musl, libuuid, openssl...) e tudo que o `pip`/`go`
> arrastou junto. É comum a imagem acusar CVE que o `requirements.txt` não mostrava.

**(b) A tag da imagem** vem de um *step output*:
```yaml
      - id: vars
        run: echo "IMAGE_TAG=v1.0.0-$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"
```
Escrever no arquivo `$GITHUB_OUTPUT` é como um step publica um valor; outro step
lê com `${{ steps.vars.outputs.IMAGE_TAG }}`. Resultado: `v1.0.0-a1b2c3d`, então
toda imagem é rastreável até o commit exato.

**(c) Push só em `push` na `main`.** Os 3 últimos steps têm:
```yaml
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```
Isso é uma **proteção de segurança**, não frescura: em Pull Request o pipeline
builda e escaneia, mas **não publica nada** no ECR. Sem isso, um PR de fora
conseguiria subir imagem no seu registry.

**Autenticação AWS por OIDC:**
```yaml
    permissions:
      id-token: write   # <- sem isso o OIDC não funciona
      contents: read
```
Com OIDC o GitHub troca um token efêmero por credenciais temporárias da AWS via
`role-to-assume`. **Não existe `AWS_SECRET_ACCESS_KEY` guardado no repositório** —
que é o jeito certo. Requer uma IAM Role com *trust policy* apontando pro GitHub.

---

## 4. Tabela-resumo dos portões de segurança

| Etapa | Ferramenta | Olha | Bloqueia quando |
|---|---|---|---|
| Job 2 | golangci-lint / flake8 | estilo e bugs de código | qualquer achado |
| Job 3 (SCA) | Trivy `fs` | `go.mod` / `requirements.txt` | HIGH ou CRITICAL com fix |
| Job 3 (SAST) | gosec / bandit | código-fonte | severidade `high` |
| Job 4 | Trivy `image` | imagem + SO da base | HIGH ou CRITICAL com fix |
| terraform.yml Job 2 | Trivy `config` | arquivos `.tf` | HIGH ou CRITICAL |

Em todos, o que bloqueia é o **`exit-code: '1'`** (Trivy) ou o exit code natural
da ferramenta. Tirar isso transforma o pipeline em teatro.

---

## 5. Go × Python — o que muda entre os moldes

| | Go | Python |
|---|---|---|
| Setup | `actions/setup-go@v5` | `actions/setup-python@v5` |
| Var. de versão | `GO_VERSION: '1.25'` | `PYTHON_VERSION: '3.11'` |
| Cache | `cache: true` + `go.sum` | `cache: 'pip'` + `requirements.txt` |
| "Build" | `go build -v ./...` | `pip install -r` + `py_compile` |
| Teste | `go test -race` | `pytest` (se existir) |
| Lint | `golangci-lint-action@v9` | `flake8` |
| SAST | `gosec` (via `run:`) | `bandit -lll` |
| Relatório | SARIF → aba Security | JSON → artefato |

O resto (jobs 3-SCA e 4) é **igual palavra por palavra**.

---

## 6. O workflow do Terraform é diferente — e por quê

`terraform.yml` também tem 4 jobs em cadeia, mas a lógica muda porque
**infraestrutura é mais perigosa que uma imagem Docker**:

```
1. fmt-validate  →  2. security-scan  →  3. plan  →  4. apply
   fmt -check         Trivy config       sempre      só push na main
   init -backend=false  (.tf)            roda,       + APROVAÇÃO MANUAL
   validate                              nunca       (environment: production)
                                         aplica
```

Pontos que não existem nos outros workflows:

- **`concurrency: { group: terraform-iac, cancel-in-progress: false }`** — grupo
  fixo (não por branch) e **sem cancelar**. Dois `apply` simultâneos corrompem o
  state; e cancelar um `apply` no meio é pior que deixar terminar.
- **`scan-type: 'config'`** — o Trivy tem um terceiro modo, que lê os `.tf`
  procurando *misconfiguration* (security group aberto pro mundo, bucket público,
  RDS sem criptografia). Não é CVE, é configuração errada.
- **O plano vira artefato.** O job `plan` faz `upload-artifact` do `tfplan`, e o
  `apply` faz `download-artifact` e roda `terraform apply tfplan`. Ele **nunca
  gera um plano novo na hora do apply** — assim você aplica exatamente o que foi
  revisado, e não algo que mudou entre a revisão e o apply.
- **`environment: production`** — é isso, e só isso, que liga o gate de aprovação
  manual. Configure em *Settings → Environments → production → Required reviewers*.
- **Comentário automático no PR** via `actions/github-script@v7`: lê o `tfplan.txt`
  e posta como comentário (truncando em 60k, que é o limite do GitHub). Precisa de
  `permissions: pull-requests: write`.
- **`continue-on-error: true` no `plan`** seguido de um step
  `if: steps.plan.outcome == 'failure' → exit 1`. Truque útil: deixa o job seguir
  para conseguir **comentar o erro no PR**, e só então falha de verdade.
- **Dois modos de login AWS**, escolhidos por uma *variable* de repositório:
  ```yaml
      - if: vars.AWS_MODE == 'academy'      # chaves temporárias do AWS Academy
      - if: vars.AWS_MODE != 'academy'      # OIDC, conta normal
  ```
  Note `vars.` (Settings → Variables, valor público) contra `secrets.`
  (valor mascarado nos logs).

---

## 7. Secrets e variables que o pipeline espera

Em **Settings → Secrets and variables → Actions**:

| Nome | Tipo | Usado por | Quando |
|---|---|---|---|
| `AWS_ROLE_TO_ASSUME` | secret | 5 microsserviços | push na main (ECR) |
| `AWS_TERRAFORM_ROLE_ARN` | secret | terraform.yml | modo OIDC |
| `AWS_ACCESS_KEY_ID` | secret | terraform.yml | modo Academy |
| `AWS_SECRET_ACCESS_KEY` | secret | terraform.yml | modo Academy |
| `AWS_SESSION_TOKEN` | secret | terraform.yml | modo Academy |
| `AWS_MODE` | **variable** | terraform.yml | `academy` ou `normal` |

Além disso: os repositórios ECR precisam existir com os nomes de
`ECR_REPOSITORY` (o módulo `iac/modules/ecr` já cria os 5 a partir da variável
`microservices`).

---

## 8. Receita: criando o workflow de um serviço novo

1. Copie o molde mais próximo (`auth-service.yml` para Go, `flag-service.yml` para Python).
2. Troque **6 lugares**:
   - `name:` no topo
   - `concurrency.group:`
   - os 4 caminhos comentados em `on.push.paths` / `on.pull_request.paths`
   - `env.SERVICE_NAME`
   - `env.SERVICE_PATH`
   - `env.ECR_REPOSITORY`
3. Confirme a versão da linguagem (`GO_VERSION` / `PYTHON_VERSION`) contra o
   `go.mod` / `Dockerfile` do serviço. **Se o `go.mod` pede 1.25, o workflow com
   1.21 não compila.**
4. Crie o repositório ECR (ou adicione o nome em `var.microservices` no Terraform).
5. Valide **antes de commitar** (seção 10).

---

## 9. Armadilhas que já pegaram este repositório

Lista real de coisas que quebraram aqui — vale conferir todas ao escrever um workflow novo:

1. **`working-directory:` em step `uses:`** → o Actions recusa o arquivo inteiro.
   Só funciona em step `run:`. Foi o que quebrou os 2 workflows Go.
2. **Versão da action de lint desalinhada da versão da linguagem** →
   `golangci-lint-action@v6` instala o v1, que não suporta Go 1.25.
3. **`GO_VERSION` do workflow atrás do `go.mod`** → o job 1 nem compila.
4. **Nome do arquivo diferente do `paths:` interno** → o `analystics-service.yml`
   (com typo) filtrava por `analytics-service.yml`, então nunca dispararia sozinho.
5. **`cache-dependency-path` relativo** → step `uses:` não enxerga
   `defaults.run.working-directory`; precisa do caminho completo.
6. **Esquecer `load: true`** no build → o Trivy não encontra a imagem pra escanear.
7. **Esquecer `permissions: id-token: write`** → OIDC falha com erro obscuro de credencial.
8. **Lint cosmético bloqueando o pipeline** → decida cedo: ou formata o código,
   ou configura o linter (`.flake8` / `.golangci.yml`). O pior cenário é
   desabilitar o job inteiro.

---

## 10. Testando localmente antes de commitar

Você não precisa dar push pra descobrir que o YAML está errado:

```bash
# valida a SINTAXE de todos os workflows (pega o erro de "working-directory")
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest

# SCA - o mesmo scan do job 3
docker run --rm -v "$PWD":/scan aquasec/trivy:latest fs \
  --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
  /scan/techchallange3/docker/auth-service

# scan de imagem - o mesmo do job 4
docker build -t auth-service:test techchallange3/docker/auth-service
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest \
  image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 auth-service:test

# SAST + lint Go
docker run --rm -v "$PWD":/w -w /w golang:1.26-alpine sh -c \
  'go install github.com/securego/gosec/v2/cmd/gosec@latest &&
   cd techchallange3/docker/auth-service && gosec -severity high -confidence high ./...'
docker run --rm -v "$PWD":/w -w /w golangci/golangci-lint:v2.13.2-alpine sh -c \
  'cd /w/techchallange3/docker/auth-service && golangci-lint run --timeout=5m'

# SAST + lint Python
docker run --rm -v "$PWD":/w -w /w python:3.11-alpine sh -c \
  'pip install -q flake8 bandit &&
   cd techchallange3/docker/flag-service &&
   flake8 . --max-line-length=120 && bandit -r . -lll'
```

O `actionlint` sozinho já pega erro de sintaxe YAML, expressão `${{ }}` inválida,
chave desconhecida e `needs:` apontando pra job que não existe — rode ele sempre.

---

## 11. Pendências conhecidas

- [ ] Gatilhos `push`/`pull_request` estão **comentados** nos 5 microsserviços.
- [ ] Não existem testes unitários (`_test.go` / `test_*.py`) em nenhum serviço —
      os jobs de teste passam vazios de propósito, esperando os testes chegarem.
- [ ] `terraform.yml` cita `TUTORIAL-IAC-ACADEMY.md`, que **não existe** no repositório.
- [ ] Os 5 workflows são cópias. Um `workflow_call` reutilizável
      (`.github/workflows/_microservice.yml` recebendo `service-name`, `service-path`
      e `language` como `inputs`) eliminaria a duplicação.
- [ ] Nenhum workflow faz **deploy no Kubernetes** — o pipeline termina no push
      pro ECR. Os manifests em `techchallange3/kubernetes/` ainda são aplicados à mão.
