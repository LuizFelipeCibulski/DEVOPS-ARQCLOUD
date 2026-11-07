package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/XSAM/otelsql"
	// Driver PostgreSQL registrado via blank import: sem isso o
	// sql.Open("pgx", ...) falha com `unknown driver "pgx"`.
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// App struct (para injeção de dependência)
type App struct {
	DB        *sql.DB
	MasterKey string
	Chaos     *Chaos
}

func main() {
	// Carrega o .env para desenvolvimento local. Em produção, isso não fará nada.
	_ = godotenv.Load()

	// --- Telemetria (Fase 4) ---
	ctx := context.Background()
	shutdownTelemetry, err := setupTelemetry(ctx, "auth-service")
	if err != nil {
		log.Fatalf("Falha ao iniciar OpenTelemetry: %v", err)
	}

	// --- Configuração ---
	port := os.Getenv("PORT")
	if port == "" {
		port = "8001" // Porta padrão
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL deve ser definida")
	}

	masterKey := os.Getenv("MASTER_KEY")
	if masterKey == "" {
		log.Fatal("MASTER_KEY deve ser definida")
	}

	// --- Conexão com o Banco ---
	db, err := connectDB(databaseURL)
	if err != nil {
		log.Fatalf("Não foi possível conectar ao banco de dados: %v", err)
	}
	defer func() { _ = db.Close() }()

	app := &App{
		DB:        db,
		MasterKey: masterKey,
		Chaos:     &Chaos{},
	}

	// --- Rotas da API ---
	mux := http.NewServeMux()
	mux.HandleFunc("/health", app.healthHandler)

	// Endpoint público para validar uma chave
	mux.HandleFunc("/validate", app.validateKeyHandler)

	// Endpoints de "admin" para criar/gerenciar chaves
	// Eles são protegidos pelo middleware de autenticação
	mux.Handle("/admin/keys", app.masterKeyAuthMiddleware(http.HandlerFunc(app.createKeyHandler)))
	// Fase 4: injeção de falha para demonstrar alerta + self-healing
	mux.Handle("/admin/chaos", app.masterKeyAuthMiddleware(http.HandlerFunc(app.chaosHandler)))

	// otelhttp cria um span SERVER por requisição (lendo o traceparent de
	// quem chamou) e registra a métrica http.server.request.duration.
	// O chaos fica DENTRO do otelhttp para que o 500 injetado apareça no
	// trace e na métrica - senão o alerta nunca veria a falha.
	handler := otelhttp.NewHandler(app.chaosMiddleware(mux), "auth-service",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" }),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Encerramento gracioso: no rollout restart o kubelet manda SIGTERM;
	// esperamos as requisições em voo e fazemos flush da telemetria.
	go func() {
		log.Printf("Serviço de Autenticação (Go) rodando na porta %s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	log.Println("SIGTERM recebido: encerrando...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	_ = shutdownTelemetry(shutdownCtx)
}

// connectDB inicializa e testa a conexão com o PostgreSQL.
// otelsql embrulha o driver: cada query vira um span filho da requisição
// (aparece no trace distribuído como a chamada ao banco).
func connectDB(databaseURL string) (*sql.DB, error) {
	db, err := otelsql.Open("pgx", databaseURL,
		otelsql.WithAttributes(semconv.DBSystemPostgreSQL),
		otelsql.WithSpanOptions(otelsql.SpanOptions{OmitConnResetSession: true, OmitRows: true}),
	)
	if err != nil {
		return nil, err
	}
	if _, err := otelsql.RegisterDBStatsMetrics(db, otelsql.WithAttributes(semconv.DBSystemPostgreSQL)); err != nil {
		log.Printf("aviso: métricas do pool de conexões indisponíveis: %v", err)
	}

	if err = db.Ping(); err != nil {
		return nil, err
	}

	log.Println("Conectado ao PostgreSQL com sucesso!")
	return db, nil
}
