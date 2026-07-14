## 1. Criar a fila no SQS (ministack)

Só precisa rodar **uma vez** (fica persistida no volume `ministack`, mas se
sumir — por exemplo depois de um `docker compose down` — é só rodar de novo,
é idempotente):

```powershell
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli --endpoint-url http://ministack:4566 sqs create-queue --queue-name MyStandardQueue
```

Confirma que existe:
```powershell
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli --endpoint-url http://ministack:4566 sqs list-queues
```

---

## 2. Criar a tabela no DynamoDB Local

```powershell
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=mock -e AWS_SECRET_ACCESS_KEY=mock -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli:2.15.30 --endpoint-url http://dynamodb:8000 dynamodb create-table `
    --table-name ToggleMasterAnalytics `
    --attribute-definitions AttributeName=event_id,AttributeType=S `
    --key-schema AttributeName=event_id,KeyType=HASH `
    --billing-mode PAY_PER_REQUEST
```

Confirma que existe:
```powershell
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=mock -e AWS_SECRET_ACCESS_KEY=mock -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli:2.15.30 --endpoint-url http://dynamodb:8000 dynamodb list-tables
```

---

## 3. Teste ponta a ponta

```powershell
# gera um evento (evaluation-service -> SQS)
curl "http://localhost:8004/evaluate?user_id=teste-final&flag_name=enable-new-screen"

# acompanha o worker consumindo (SQS -> analytics-service -> DynamoDB)
docker compose logs -f app-analytics
```

Espera aparecer:
```
Recebidas 1 mensagens.
Processando mensagem ID: ...
Evento ... (Flag: enable-new-screen) salvo no DynamoDB.
```
(`Ctrl+C` pra sair do `-f`)

---

## 4. Comandos de visualização (usar sempre que quiser conferir)

### Ver quantas mensagens estão na fila SQS
```powershell
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli --endpoint-url http://ministack:4566 sqs get-queue-attributes `
    --queue-url http://ministack:4566/000000000000/MyStandardQueue `
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```
- `ApproximateNumberOfMessages`: esperando ser consumida.
- `ApproximateNumberOfMessagesNotVisible`: já pega por um consumer, aguardando delete.
- Se o `app-analytics` estiver saudável, os dois ficam perto de `0` a maior parte do tempo.

⚠️ Não usa `receive-message` manualmente pra "espiar" a fila enquanto o
`app-analytics` estiver rodando — ele rouba a mensagem do worker de verdade
por um tempo.

### Ver os itens gravados no DynamoDB
```powershell
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=mock -e AWS_SECRET_ACCESS_KEY=mock -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli:2.15.30 --endpoint-url http://dynamodb:8000 dynamodb scan --table-name ToggleMasterAnalytics
```

### Ver as tabelas/filas existentes
```powershell
# tabelas
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=mock -e AWS_SECRET_ACCESS_KEY=mock -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli:2.15.30 --endpoint-url http://dynamodb:8000 dynamodb list-tables

# filas
docker run --rm --network tech-chall2_rede-app `
  -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
  amazon/aws-cli --endpoint-url http://ministack:4566 sqs list-queues
```

### Atalhos (cola no `$PROFILE` do PowerShell)
```powershell
function Check-Sqs {
  docker run --rm --network tech-chall2_rede-app `
    -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_DEFAULT_REGION=us-east-1 `
    amazon/aws-cli --endpoint-url http://ministack:4566 sqs get-queue-attributes `
      --queue-url http://ministack:4566/000000000000/MyStandardQueue `
      --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
}

function Check-Dynamo {
  docker run --rm --network tech-chall2_rede-app `
    -e AWS_ACCESS_KEY_ID=mock -e AWS_SECRET_ACCESS_KEY=mock -e AWS_DEFAULT_REGION=us-east-1 `
    amazon/aws-cli:2.15.30 --endpoint-url http://dynamodb:8000 dynamodb scan --table-name ToggleMasterAnalytics
}
```
Depois é só chamar `Check-Sqs` ou `Check-Dynamo` no terminal.

---

## Resumo dos problemas que apareceram (e a causa de cada um)

| Sintoma | Causa | Solução |
|---|---|---|
| `app-evaluation`/`app-analytics` ficavam em `Created`, nunca subiam | `depends_on` com `condition: service_healthy` apontando pra `dynamodb`/`ministack`, que não têm healthcheck configurado | Trocar para `condition: service_started` |
| `NonExistentQueue` / `QueueDoesNotExist` nos logs | Fila nunca tinha sido criada no ministack | `sqs create-queue` (seção 1) |
| AWS CLI (`latest`) travava/dava `Read timeout` só no Dynamo | Versões recentes do CLI/botocore mudaram o formato da requisição de um jeito que o `dynamodb-local` não responde | Fixar a tag `amazon/aws-cli:2.15.30` |
| `docker logs dynamodb` mostrando `SQLiteException: unable to open database file`, ciclo de `stopped abnormally, reincarnating` | Container roda como usuário não-root por padrão e não tem permissão de escrita no volume nomeado do Docker | `user: root` no serviço `dynamodb` no compose (+ apagar o volume antigo pra resetar a permissão) |
| Fila "sumiu" depois de recriar os containers | `docker compose down` recria os containers; dependendo do que foi feito no meio do caminho (recriar volume, etc.) o estado do `ministack` pode não persistir | Só recriar a fila (`create-queue` é idempotente, não dá erro se já existir) |