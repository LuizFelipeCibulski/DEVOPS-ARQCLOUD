# ==========================================
# ESTÁGIO 1: Builder (Compilação com Cache)
# ==========================================
FROM golang:1.21-alpine AS builder

WORKDIR /app

# 1. Copia apenas o arquivo de pacotes para o cache do Docker
COPY go.mod ./

# 2. Mantém a dependência correta com /stdlib no go.mod para o driver se registrar
RUN sed -i 's|github.com/jackc/pgx/v4/stdlib|github.com/jackc/pgx/v4/stdlib|g' go.mod

# 3. Baixa as dependências e joga no cache
RUN go mod download

# 4. Copia o restante do código fonte
COPY . .

# 5. CORREÇÃO DE IMPORTS: Comentamos os não usados e colocamos o "_" no pgx/v4/stdlib
RUN sed -i 's|"crypto/sha256"|// "crypto/sha256"|g' handlers.go || true && \
    sed -i 's|"encoding/hex"|// "encoding/hex"|g' handlers.go || true && \
    sed -i 's|"fmt"|// "fmt"|g' main.go || true && \
    sed -i 's|"fmt"|// "fmt"|g' key.go || true && \
    text_replace='s|"github.com/jackc/pgx/v4/stdlib"|_ "github.com/jackc/pgx/v4/stdlib"|g' && \
    sed -i "$text_replace" main.go || true && \
    go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build -o meu-app .

# ==========================================
# ESTÁGIO 2: Imagem Final de Produção
# ==========================================
FROM alpine:3.19 AS prod

WORKDIR /app

# Copia apenas o executável perfeito e limpo
COPY --from=builder /app/meu-app ./meu-app

EXPOSE 8001

CMD ["./meu-app"]