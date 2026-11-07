package main

import (
	"context"
	"encoding/json"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/sqs"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

// Evento que será enviado para a fila
type EvaluationEvent struct {
	UserID    string    `json:"user_id"`
	FlagName  string    `json:"flag_name"`
	Result    bool      `json:"result"`
	Timestamp time.Time `json:"timestamp"`
}

var tracer = otel.Tracer("evaluation-service/sqs")

// sendEvaluationEvent envia um evento para a fila SQS.
//
// Fase 4 - trace através da fila: HTTP propaga o contexto sozinho pelo
// cabeçalho traceparent, mas o SQS não tem cabeçalho. A solução padrão é
// carregar o traceparent nos MessageAttributes da mensagem; o
// analytics-service lê de lá e continua o MESMO trace. Sem isso o
// analytics apareceria solto no APM, sem ligação com o evaluation, e o
// Service Map teria só 4 dos 5 serviços conectados.
func (a *App) sendEvaluationEvent(ctx context.Context, userID, flagName string, result bool) {
	// Se a URL da fila não foi configurada, apenas loga localmente e sai.
	if a.SqsSvc == nil || a.SqsQueueURL == "" {
		logf(ctx, "[SQS_DISABLED] Evento: User '%s', Flag '%s', Result '%t'", userID, flagName, result)
		return
	}

	// Span PRODUCER: semântica de mensageria do OpenTelemetry.
	ctx, span := tracer.Start(ctx, "evaluation publish",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "aws_sqs"),
			attribute.String("messaging.destination.name", "evaluation"),
			attribute.String("messaging.operation.type", "publish"),
			attribute.String("feature_flag.key", flagName),
		),
	)
	defer span.End()

	event := EvaluationEvent{
		UserID:    userID,
		FlagName:  flagName,
		Result:    result,
		Timestamp: time.Now().UTC(),
	}

	body, err := json.Marshal(event)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "serialização")
		logf(ctx, "Erro ao serializar evento SQS: %v", err)
		return
	}

	// Injeta traceparent/tracestate do span PRODUCER nos atributos.
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier)
	attrs := map[string]*sqs.MessageAttributeValue{}
	for k, v := range carrier {
		attrs[k] = &sqs.MessageAttributeValue{DataType: aws.String("String"), StringValue: aws.String(v)}
	}

	// Envia a mensagem
	out, err := a.SqsSvc.SendMessageWithContext(ctx, &sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: attrs,
	})

	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "SendMessage falhou")
		logf(ctx, "Erro ao enviar mensagem para SQS: %v", err)
		return
	}
	span.SetAttributes(attribute.String("messaging.message.id", aws.StringValue(out.MessageId)))
	logf(ctx, "Evento de avaliação enviado para SQS (Flag: %s)", flagName)
}
