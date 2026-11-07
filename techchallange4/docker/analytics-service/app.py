import os
import sys
import threading
import json
import uuid
import time
import logging
import boto3
from botocore.exceptions import NoCredentialsError, ClientError
from flask import Flask, jsonify
from dotenv import load_dotenv

# --- Fase 4: OpenTelemetry ---------------------------------------------
# Os patches automáticos (Flask, botocore, logging) são aplicados pelo
# 'opentelemetry-instrument' do Dockerfile. Aqui só usamos a API para o
# que a instrumentação automática não sabe fazer: continuar o trace que
# chegou DENTRO da mensagem SQS (ver process_message).
from opentelemetry import trace, propagate
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.instrumentation.utils import suppress_instrumentation

tracer = trace.get_tracer("analytics-service.sqs-worker")

# Configura o logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

# Carrega .env para desenvolvimento local
load_dotenv()

# --- Configuração ---
AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")
DYNAMODB_LOCAL = os.getenv("DYNAMODB_LOCAL")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.critical("Erro: AWS_REGION, AWS_SQS_URL, e AWS_DYNAMODB_TABLE devem ser definidos.")
    sys.exit(1)

# --- Clientes Boto3 ---
# Criamos a sessão uma vez
try:
    if DYNAMODB_LOCAL:
        sessiondynamo = boto3.Session(
            aws_access_key_id=os.getenv("AWS_DYNAMODB_ACCESS_KEY_ID"),
            aws_secret_access_key=os.getenv("AWS_DYNAMODB_SECRET_ACCESS_KEY"),
            region_name=AWS_REGION,
        )
        sessionsqs = boto3.Session(
            aws_access_key_id=os.getenv("AWS_SQS_ACCESS_KEY_ID"),
            aws_secret_access_key=os.getenv("AWS_SQS_SECRET_ACCESS_KEY"),
            region_name=AWS_REGION,
        )
        sqs_client = sessionsqs.client("sqs", endpoint_url="http://ministack:4566")
        dynamodb_client = sessiondynamo.client("dynamodb", endpoint_url="http://dynamodb:8000")
        log.info("Clientes Boto3 inicializados em modo LOCAL (DynamoDB Local + ministack)")
    else:
        session = boto3.Session(region_name=AWS_REGION)
        sqs_client = session.client("sqs")
        dynamodb_client = session.client("dynamodb")
        log.info(f"Clientes Boto3 inicializados na região {AWS_REGION}")
except NoCredentialsError:
    log.critical("Credenciais da AWS não encontradas. Verifique seu ambiente.")
    sys.exit(1)
except Exception as e:
    log.critical(f"Erro ao inicializar o Boto3: {e}")
    sys.exit(1)


# --- SQS Worker ---

def _trace_context(message):
    """ Extrai o traceparent que o evaluation-service colocou nos
    MessageAttributes. É o "cabeçalho HTTP" da mensagem: sem ele o
    consumo apareceria como um trace novo e solto no APM. """
    attrs = message.get('MessageAttributes', {}) or {}
    carrier = {k: v.get('StringValue', '') for k, v in attrs.items() if v.get('DataType') == 'String'}
    return propagate.extract(carrier)


def process_message(message):
    """ Processa uma única mensagem SQS e a insere no DynamoDB """
    # Span CONSUMER filho do span PRODUCER do evaluation-service: é este
    # elo que faz o analytics aparecer conectado no Service Map. As
    # chamadas put_item/delete_message (botocore) viram filhas dele.
    with tracer.start_as_current_span(
        "evaluation process",
        context=_trace_context(message),
        kind=SpanKind.CONSUMER,
        attributes={
            "messaging.system": "aws_sqs",
            "messaging.destination.name": "evaluation",
            "messaging.operation.type": "process",
            "messaging.message.id": message['MessageId'],
        },
    ) as span:
        _process_message(message, span)


def _process_message(message, span):
    try:
        log.info(f"Processando mensagem ID: {message['MessageId']}")
        body = json.loads(message['Body'])
        span.set_attribute("feature_flag.key", body.get('flag_name', ''))

        # Gera um ID único para o item no DynamoDB
        event_id = str(uuid.uuid4())

        # Constrói o item no formato do DynamoDB
        item = {
            'event_id': {'S': event_id},
            'user_id': {'S': body['user_id']},
            'flag_name': {'S': body['flag_name']},
            'result': {'BOOL': body['result']},
            'timestamp': {'S': body['timestamp']}
        }

        # Insere no DynamoDB
        dynamodb_client.put_item(
            TableName=DYNAMODB_TABLE_NAME,
            Item=item
        )

        log.info(f"Evento {event_id} (Flag: {body['flag_name']}) salvo no DynamoDB.")

        # Se tudo deu certo, deleta a mensagem da fila
        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=message['ReceiptHandle']
        )

    except json.JSONDecodeError as e:
        span.record_exception(e)
        span.set_status(Status(StatusCode.ERROR, "JSON inválido"))
        log.error(f"Erro ao decodificar JSON da mensagem ID: {message['MessageId']}")
        # Não deleta a mensagem, pode ser uma "poison pill"
    except ClientError as e:
        span.record_exception(e)
        span.set_status(Status(StatusCode.ERROR, "erro AWS"))
        log.error(f"Erro do Boto3 (DynamoDB ou SQS) ao processar {message['MessageId']}: {e}")
        # Não deleta a mensagem, tenta novamente
    except Exception as e:
        span.record_exception(e)
        span.set_status(Status(StatusCode.ERROR, "erro inesperado"))
        log.error(f"Erro inesperado ao processar {message['MessageId']}: {e}")
        # Não deleta a mensagem, tenta novamente


def sqs_worker_loop():
    """ Loop principal do worker que ouve a fila SQS """
    log.info("Iniciando o worker SQS...")
    while True:
        try:
            # Long-polling: espera até 20s por mensagens
            # suppress_instrumentation: o long-polling roda a cada 20s
            # mesmo com a fila vazia. Sem isso, cada ciclo viraria um
            # trace "SQS.ReceiveMessage" sem valor nenhum, poluindo o APM.
            with suppress_instrumentation():
                response = sqs_client.receive_message(
                    QueueUrl=SQS_QUEUE_URL,
                    MaxNumberOfMessages=10,  # Processa em lotes de até 10
                    WaitTimeSeconds=20,
                    # Sem isto o SQS NÃO devolve os MessageAttributes, e o
                    # traceparent enviado pelo evaluation se perde.
                    MessageAttributeNames=['All'],
                )

            messages = response.get('Messages', [])
            if not messages:
                # Nenhuma mensagem, continua o loop
                continue

            log.info(f"Recebidas {len(messages)} mensagens.")

            for message in messages:
                process_message(message)

        except ClientError as e:
            log.error(f"Erro do Boto3 no loop principal do SQS: {e}")
            time.sleep(10)   # Pausa antes de tentar novamente
        except Exception as e:
            log.error(f"Erro inesperado no loop principal do SQS: {e}")
            time.sleep(10)

# --- Servidor Flask (Apenas para Health Check) ---


app = Flask(__name__)


@app.route('/health')
def health():
    # Uma verificação de saúde real poderia checar a conexão com o DynamoDB/SQS
    return jsonify({"status": "ok"})

# --- Inicialização ---


def start_worker():
    """ Inicia o worker SQS em uma thread separada """
    worker_thread = threading.Thread(target=sqs_worker_loop, daemon=True)
    worker_thread.start()

# Inicia o worker SQS em uma thread de background
# Isso garante que ele inicie tanto com 'flask run' quanto com 'gunicorn'


start_worker()


if __name__ == '__main__':
    port = int(os.getenv("PORT", 8005))
    app.run(host='0.0.0.0', port=port, debug=False)
