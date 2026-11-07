package main

// =====================================================================
// Fase 4 - Injeção de falha (chaos) para a "Prova Real" do desafio
// ---------------------------------------------------------------------
// POST /admin/chaos {"error_rate": 0.5}  (protegido pela MASTER_KEY)
//   -> a partir daí, ~50% das requisições respondem HTTP 500.
// POST /admin/chaos {"error_rate": 0}    -> desliga.
// GET  /admin/chaos                       -> estado atual.
//
// O estado vive SÓ NA MEMÓRIA do processo, de propósito: simula um
// processo "degradado" (vazamento, pool envenenado, deadlock parcial) -
// exatamente a classe de falha que um `kubectl rollout restart` cura.
// Assim a automação de self-healing tem efeito real e observável:
// alerta dispara -> restart -> pods novos nascem sem a falha -> a taxa de
// 5xx volta a zero -> o alerta resolve sozinho.
//
// /health e /admin/* nunca são afetados: a probe continua verde (o
// Kubernetes sozinho NÃO perceberia o problema, que é o cenário do PDF:
// "o serviço começou a falhar silenciosamente").
// =====================================================================

import (
	"encoding/json"
	"math"
	"math/rand/v2"
	"net/http"
	"strings"
	"sync/atomic"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

type Chaos struct {
	rateBits atomic.Uint64 // float64 em bits: leitura sem lock no caminho quente
}

func (c *Chaos) Rate() float64     { return math.Float64frombits(c.rateBits.Load()) }
func (c *Chaos) SetRate(r float64) { c.rateBits.Store(math.Float64bits(r)) }

type chaosRequest struct {
	ErrorRate *float64 `json:"error_rate"`
}

// chaosHandler liga/desliga a falha. Fica atrás do masterKeyAuthMiddleware.
func (a *App) chaosHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		var req chaosRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ErrorRate == nil ||
			*req.ErrorRate < 0 || *req.ErrorRate > 1 {
			http.Error(w, `{"error":"envie {\"error_rate\": <0.0 a 1.0>}"}`, http.StatusBadRequest)
			return
		}
		a.Chaos.SetRate(*req.ErrorRate)
		logf(r.Context(), "CHAOS: taxa de erro injetada ajustada para %.0f%%", *req.ErrorRate*100)
	default:
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]float64{"error_rate": a.Chaos.Rate()})
}

// chaosMiddleware devolve 500 para a fração configurada das requisições.
func (a *App) chaosMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rate := a.Chaos.Rate()
		if rate > 0 && r.URL.Path != "/health" && !strings.HasPrefix(r.URL.Path, "/admin/") &&
			rand.Float64() < rate { // #nosec G404 -- sorteio de falha simulada, não é uso criptográfico
			span := trace.SpanFromContext(r.Context())
			span.SetAttributes(attribute.Bool("chaos.injected", true))
			logf(r.Context(), "ERRO: falha injetada (chaos) em %s %s", r.Method, r.URL.Path)
			http.Error(w, "Erro interno (falha injetada)", http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}
