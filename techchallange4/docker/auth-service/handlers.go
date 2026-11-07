package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

// Estrutura para o corpo da requisição de criação de chave
type CreateKeyRequest struct {
	Name string `json:"name"`
}

// Estrutura para a resposta da criação de chave
type CreateKeyResponse struct {
	Name    string `json:"name"`
	Key     string `json:"key"` // A chave em texto plano é retornada APENAS uma vez
	Message string `json:"message"`
}

// healthHandler é um simples endpoint de verificação de saúde
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// validateKeyHandler verifica se uma chave de API (enviada via Header) é válida
func (a *App) validateKeyHandler(w http.ResponseWriter, r *http.Request) {
	// Extrai a chave do header "Authorization: Bearer <key>"
	authHeader := r.Header.Get("Authorization")
	keyString := strings.TrimPrefix(authHeader, "Bearer ")

	if keyString == "" {
		http.Error(w, "Authorization header não encontrado", http.StatusUnauthorized)
		return
	}

	// Calcula o hash da chave recebida
	keyHash := hashAPIKey(keyString)

	// Verifica se o hash existe no banco de dados.
	// QueryRowContext (e não QueryRow): carrega o contexto da requisição,
	// então o span da query nasce como filho do span HTTP no trace.
	var id int
	err := a.DB.QueryRowContext(r.Context(),
		"SELECT id FROM api_keys WHERE key_hash = $1 AND is_active = true", keyHash).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		logf(r.Context(), "Falha na validação da chave (hash: %s...): chave inexistente ou inativa", keyHash[:6])
		http.Error(w, "Chave de API inválida ou inativa", http.StatusUnauthorized)
		return
	}
	if err != nil {
		// Fase 4: antes TODO erro virava 401. Banco fora do ar não é
		// "chave inválida" - é falha do serviço, e precisa aparecer como
		// 5xx para o alerta de taxa de erro enxergar.
		logf(r.Context(), "ERRO: falha ao consultar api_keys: %v", err)
		http.Error(w, "Serviço de autenticação indisponível", http.StatusServiceUnavailable)
		return
	}

	// Chave válida
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "Chave válida"})
}

// createKeyHandler cria uma nova chave de API
func (a *App) createKeyHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Método não permitido", http.StatusMethodNotAllowed)
		return
	}

	var req CreateKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Corpo da requisição inválido", http.StatusBadRequest)
		return
	}

	if req.Name == "" {
		http.Error(w, "O campo 'name' é obrigatório", http.StatusBadRequest)
		return
	}

	// Gera uma nova chave e seu hash
	newKey, err := generateAPIKey()
	if err != nil {
		http.Error(w, "Erro ao gerar a chave", http.StatusInternalServerError)
		return
	}
	newKeyHash := hashAPIKey(newKey)

	// Salva o hash no banco de dados
	var newID int
	err = a.DB.QueryRowContext(r.Context(),
		"INSERT INTO api_keys (name, key_hash) VALUES ($1, $2) RETURNING id",
		req.Name, newKeyHash,
	).Scan(&newID)

	if err != nil {
		logf(r.Context(), "Erro ao salvar a chave no banco: %v", err)
		http.Error(w, "Erro ao salvar a chave", http.StatusInternalServerError)
		return
	}

	logf(r.Context(), "Nova chave criada com sucesso (ID: %d, Name: %s)", newID, req.Name)
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(CreateKeyResponse{
		Name:    req.Name,
		Key:     newKey, // Retorna a chave em texto plano pela última vez
		Message: "Guarde esta chave com segurança! Você não poderá vê-la novamente.",
	})
}

// --- Middleware ---

// masterKeyAuthMiddleware protege endpoints que só podem ser acessados com a MASTER_KEY
func (a *App) masterKeyAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		keyString := strings.TrimPrefix(authHeader, "Bearer ")

		if keyString != a.MasterKey {
			http.Error(w, "Acesso não autorizado", http.StatusForbidden)
			return
		}
		// Se a chave for válida, continua para o handler principal
		next.ServeHTTP(w, r)
	})
}
