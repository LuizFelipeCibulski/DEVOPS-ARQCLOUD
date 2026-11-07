package main

// =====================================================================
// Fase 4 - OpenTelemetry (traces + métricas) (compartilhado entre os serviços Go)
// ---------------------------------------------------------------------
// O serviço NÃO fala com Prometheus nem com New Relic. Ele só conhece o
// OTel Collector, via OTLP/gRPC, no endereço da variável padrão
// OTEL_EXPORTER_OTLP_ENDPOINT. Quem decide para onde cada sinal vai é o
// Collector (kubernetes/observability/otel-collector).
//
// Variáveis padrão da especificação lidas automaticamente pelo SDK:
//   OTEL_SERVICE_NAME            -> nome do serviço no APM e no Grafana
//   OTEL_RESOURCE_ATTRIBUTES     -> ex.: deployment.environment=prod
//   OTEL_EXPORTER_OTLP_ENDPOINT  -> ex.: http://otel-collector...:4317
// Sem OTEL_EXPORTER_OTLP_ENDPOINT (dev local) a telemetria fica desligada
// em vez de inundar o log com "connection refused".
// =====================================================================

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/runtime"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// setupTelemetry configura os providers globais de trace e métrica e
// devolve a função de shutdown (flush dos buffers ao encerrar o pod).
func setupTelemetry(ctx context.Context, defaultServiceName string) (func(context.Context) error, error) {
	// W3C Trace Context (traceparent) + Baggage: é o cabeçalho que liga os
	// spans de serviços diferentes no mesmo trace distribuído.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		log.Println("OTEL_EXPORTER_OTLP_ENDPOINT vazio: telemetria desligada (modo dev).")
		return func(context.Context) error { return nil }, nil
	}
	if os.Getenv("OTEL_SERVICE_NAME") == "" {
		_ = os.Setenv("OTEL_SERVICE_NAME", defaultServiceName)
	}

	res, err := resource.New(ctx,
		resource.WithFromEnv(), // OTEL_SERVICE_NAME + OTEL_RESOURCE_ATTRIBUTES
		resource.WithTelemetrySDK(),
		resource.WithHost(),
	)
	if err != nil {
		return nil, fmt.Errorf("resource: %w", err)
	}

	// ---- Traces --------------------------------------------------------
	traceExp, err := otlptracegrpc.New(ctx) // endpoint/insecure vêm das env OTEL_*
	if err != nil {
		return nil, fmt.Errorf("exporter de trace: %w", err)
	}
	tp := sdktrace.NewTracerProvider(
		// Batch: exporta em lote, fora do caminho da requisição.
		sdktrace.WithBatcher(traceExp),
		sdktrace.WithResource(res),
		// ParentBased(AlwaysOn): respeita a decisão de quem chamou e
		// amostra 100% das raízes - volume baixo, e no desafio cada trace
		// importa. Em produção real use OTEL_TRACES_SAMPLER_ARG.
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
	)
	otel.SetTracerProvider(tp)

	// ---- Métricas ------------------------------------------------------
	metricExp, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("exporter de métrica: %w", err)
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp, sdkmetric.WithInterval(15*time.Second))),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	// Métricas do runtime Go (goroutines, GC, heap).
	if err := runtime.Start(runtime.WithMinimumReadMemStatsInterval(15 * time.Second)); err != nil {
		log.Printf("aviso: métricas de runtime indisponíveis: %v", err)
	}

	log.Printf("OpenTelemetry ligado: service.name=%s endpoint=%s",
		os.Getenv("OTEL_SERVICE_NAME"), os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))

	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx))
	}, nil
}

// logf é o log.Printf com o trace_id/span_id do contexto. É isso que
// permite, no Grafana, sair de uma linha de log no Loki e achar o trace
// correspondente no New Relic (e vice-versa).
func logf(ctx context.Context, format string, args ...any) {
	sc := trace.SpanContextFromContext(ctx)
	if sc.IsValid() {
		format = fmt.Sprintf("trace_id=%s span_id=%s %s", sc.TraceID(), sc.SpanID(), format)
	}
	log.Printf(format, args...)
}
