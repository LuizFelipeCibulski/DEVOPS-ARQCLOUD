package main

import (
	"context"
	"encoding/json"
	"net/http"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

type EvaluationResponse struct {
	FlagName string `json:"flag_name"`
	UserID   string `json:"user_id"`
	Result   bool   `json:"result"`
}

func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (a *App) evaluationHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// 1. Parsear os query parameters
	userID := r.URL.Query().Get("user_id")
	flagName := r.URL.Query().Get("flag_name")

	if userID == "" || flagName == "" {
		http.Error(w, `{"error": "user_id e flag_name são obrigatórios"}`, http.StatusBadRequest)
		return
	}

	// 2. Obter a decisão (lógica de cache/serviço está em evaluator.go)
	// Atributos de negócio no span: permitem buscar no APM "todos os
	// traces da flag X" ou "do usuário Y".
	span := trace.SpanFromContext(r.Context())
	span.SetAttributes(attribute.String("feature_flag.key", flagName), attribute.String("enduser.id", userID))

	result, err := a.getDecision(r.Context(), userID, flagName)
	if err != nil {
		// Se o erro for "não encontrado", retornamos 'false' (comportamento seguro)
		if _, ok := err.(*NotFoundError); ok {
			result = false
		} else {
			// Outros erros (serviços offline, etc)
			logf(r.Context(), "ERRO ao avaliar flag '%s': %v", flagName, err)
			span.RecordError(err)
			http.Error(w, `{"error": "Erro interno ao avaliar a flag"}`, http.StatusBadGateway)
			return
		}
	}

	span.SetAttributes(attribute.Bool("feature_flag.result", result))

	// 3. Enviar evento para SQS (assincronamente)
	// Isso não bloqueia a resposta para o cliente.
	// O contexto da requisição é cancelado quando o handler retorna, então
	// a goroutine recebe um contexto NOVO que só carrega a identidade do
	// span (trace_id/span_id): o publish continua no mesmo trace sem
	// herdar o cancelamento.
	asyncCtx := trace.ContextWithSpanContext(context.Background(), span.SpanContext())
	go a.sendEvaluationEvent(asyncCtx, userID, flagName, result)

	// 4. Retornar a resposta
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(EvaluationResponse{
		FlagName: flagName,
		UserID:   userID,
		Result:   result,
	})
}
