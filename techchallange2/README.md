# ToggleMaster — Tech Challenge Fase 2 (POSTECH)

## 1. Visão Geral da Implementação

Este documento descreve as decisões técnicas e a arquitetura adotadas na Fase 2 do Tech Challenge, cujo objetivo foi migrar o MVP monolítico do ToggleMaster para um ecossistema de 5 microsserviços conteinerizados, orquestrados em Kubernetes (EKS) e implantados com infraestrutura provisionada via Terraform/OpenTofu.

### 1.1 Containerização (Docker)

- Cada microsserviço possui um `Dockerfile` dedicado, localizado em `docker/<service>/Dockerfile`.
- O arquivo `docker/docker-compose.yaml` reproduz o ecossistema completo em ambiente local, contemplando os 5 microsserviços, 3 instâncias PostgreSQL, 1 instância Redis, DynamoDB Local e MiniStack (emulador leve e gratuito de SQS, utilizado como alternativa ao LocalStack).
- O script `docker/buildimages.sh` automatiza o build e o push de todas as imagens para o Amazon ECR, percorrendo iterativamente os diretórios de serviço em `docker/`.

### 1.2 Infraestrutura como Código (Terraform/OpenTofu)

A infraestrutura está definida em `iac/`, organizada nos seguintes módulos: `vpc`, `eks`, `ecr`, `rds`, `elasticache`, `dynamodb` e `sqs`. Essa estrutura cobre integralmente a infraestrutura especificado no desafio, VPC isolada, cluster EKS, 5 repositórios ECR, 3 instâncias RDS PostgreSQL, 1 cluster ElastiCache Redis e 1 tabela DynamoDB com 1 fila SQS, contemplando os dois cenários previstos:

- **AWS Academy**, reaproveitando a role gerenciada `LabRole`;
- **Conta AWS pessoal**, com provisionamento padrão de mercado.

Mesmo a infraestrutura como código não sendo cobrado no desafio, a implementação foi realiza para facilitar os testes e economizar durante a utilização dos recursos nas clouds públicas.

### 1.3 Orquestração (Kubernetes)

Os manifestos de cada serviço estão organizados em `kubernetes/<service>/`, contendo `namespace.yaml`, `configmap.yaml`, `secret.yaml`, `service.yaml` (tipo ClusterIP) e `deployment.yaml`.

O acesso externo é feito por meio de um Ingress Controller **Traefik** (`kubernetes/traefik/`), responsável por rotear as requisições por prefixo de path (`/auth`, `/flags`, `/target`, `/evaluation`, `/analytics`) e remover o prefixo antes de repassar a chamada ao serviço correspondente, via Middleware `stripPrefix`.

> **Nota:** optou-se por Traefik em vez do Nginx Ingress Controller sugerido no pdf. 

### 1.4 Escalabilidade (HPA)

Foi configurado um `HorizontalPodAutoscaler` baseado em utilização de CPU para os dois serviços definidos como requisito mínimo:

| Serviço | Critério de escala | Observação |
|---|---|---|
| `evaluation-service` | 70% de utilização de CPU | Hot path da aplicação, reage diretamente à carga de requisições |
| `analytics-service` | 50% de utilização de CPU (AWS Academy) | Na conta pessoal, a escalabilidade é implementada via **KEDA**, monitorando diretamente a fila SQS |

O `metrics-server` foi instalado no cluster `/kubernetes/metrics-service` como pré-requisito para o funcionamento do HPA.

### 1.5 Scripts Operacionais

| Script | Função |
|---|---|
| `docker/buildimages.sh` | Realiza o build e o push da imagem `:latest` de cada microsserviço para o ECR |

### 1.6 Comunicação Interna

Toda comunicação entre microsserviços dentro do cluster é realizada por meio do DNS interno do Kubernetes (`<service>.<namespace>.svc.cluster.local`). Por esse motivo, os `ConfigMap`s em `kubernetes/*/configmap.yaml` armazenam variáveis como `AUTH_SERVICE_URL` e `FLAG_SERVICE_URL` apontando exclusivamente para esse padrão interno, nunca para endpoints públicos.

Todas as credenciais e strings de conexão sensíveis são armazenadas em `Secret`, codificadas em base64, conforme boas práticas exigidas pelo desafio.

---

## 2. Desafios e Dificuldades Técnicas

Resumo dos principais obstáculos enfrentados durante a conteinerização local e o provisionamento da infraestrutura de nuvem.

### 2.1 Ambiente Local (Docker Compose)

- **Rede isolada:** os serviços de infraestrutura local (DynamoDB Local e o emulador de SQS) inicialmente não pertenciam à mesma rede Docker dos microsserviços, tornando-os inacessíveis por hostname mesmo com todos os containers em execução.
- **Configuração de endpoints ausente:** o código dos serviços `evaluation` e `analytics` ainda não possuía suporte para apontar explicitamente para endpoints locais. Tanto o AWS SDK quanto o boto3 calculam o host da AWS com base na região configurada por padrão, ignorando a URL informada — sem essa configuração explícita, as chamadas eram direcionadas à AWS real.
- **Permissão de escrita no DynamoDB Local:** o container é executado por padrão com um usuário não-root, enquanto o volume de dados era criado com outro proprietário. Essa divergência bloqueava silenciosamente qualquer operação de escrita — o serviço permanecia ativo, mas nunca respondia de fato às requisições.
- **Incompatibilidade de versão do AWS CLI:** versões recentes do CLI apresentam um comportamento de requisição não suportado adequadamente pelo DynamoDB Local, causando travamentos durante testes manuais. O problema foi contornado fixando uma versão mais antiga da imagem do CLI exclusivamente para esse uso.
- **Ausência de criação automática de recursos:** diferentemente da AWS real, os emuladores locais inicializam vazios, a fila e a tabela precisam ser criadas manualmente antes do primeiro uso.

### 2.2 Infraestrutura em Nuvem (EKS)

- **Acesso multiusuário ao cluster:** o EKS concede acesso administrativo implícito apenas à identidade IAM que criou o cluster. Como o time utiliza usuários IAM distintos, foi necessário mapear explicitamente cada usuário adicional dentro do cluster para viabilizar o uso do `kubectl`.
- **Modo de autenticação do cluster:** o cluster foi criado no modo legado (ConfigMap), incompatível com as "Access Entries" mais recentes disponíveis no console da AWS. Foi necessário editar diretamente o ConfigMap `aws-auth` via `kubectl` para liberar o acesso ao restante do time.
- **Ingress Controller diferente do sugerido:** a adoção do Traefik em vez do Nginx Ingress exigiu adaptação nos comandos de verificação e nas convenções de nomenclatura de Service e CRDs de roteamento em relação ao que a documentação do desafio descrevia.
- **EKS AWS Academy:** Durante os primeiros testes no ambiente da AWS academy tivemos alguns problemas de criação de nodes no eks por conta que a academy bloqueia a criação de novas permissões, assim as máquinas eram criadas, mas não se conectavam ao cluster.
- **Custo:** Outro ponto foi os $50 dolares sendo consumidos de forma bem rapida.
- **KEDA + IRSA:** Uma dificuldade que sofremos foi a configuração do keda com autenticação IRSA no SQS, a instalação foi feita utilizando o helm, sem problemas, porém na criação da service accounts (keda-operator) o eksctl não teve sucesso nesse processo assim, gerando o erro: "the server has asked for the client to provide credentials". Foi necessario reinstalar o keda, e recriar a IAM Policy com permissão para consultar a fila do SQS.

### 2.3 Aprendizados

A maior parte das dificuldades enfrentadas não esteve relacionada à lógica de negócio dos microsserviços, mas sim às camadas de infraestrutura menos visíveis: comunicação de rede entre containers, permissões de arquivo e volume, separação entre autenticação IAM e autorização RBAC do Kubernetes, e diferenças sutis de comportamento entre ferramentas locais e o ambiente real da AWS.