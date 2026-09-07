# ==========================================
# ESTÁGIO 1: Builder (Compilação com Cache)
# ==========================================
# Go 1.26: versões antigas (1.21) carregam dezenas de CVEs HIGH na stdlib
# que o Trivy detecta direto no binário compilado (target "gobinary").
FROM golang:1.26-alpine AS builder

WORKDIR /app

# 1. Copia apenas os arquivos de dependência para aproveitar o cache do Docker
COPY go.mod go.sum ./

# 2. Baixa as dependências (go.sum commitado garante build reproduzível)
RUN go mod download

# 3. Copia o restante do código fonte
COPY . .

# 4. Build estático (sem libc) - permite rodar em uma base mínima
#    -trimpath e -ldflags "-s -w" reduzem o binário e removem paths locais
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o meu-app .

# ==========================================
# ESTÁGIO 2: Imagem Final de Produção
# ==========================================
FROM alpine:3.24 AS prod

# apk upgrade fecha CVEs de pacotes do SO (ex.: musl) que já vêm na base
RUN apk upgrade --no-cache && \
    apk add --no-cache ca-certificates && \
    addgroup -S appgroup && \
    adduser -S appuser -G appgroup

WORKDIR /app

# Copia apenas o executável perfeito e limpo
COPY --from=builder /app/meu-app ./meu-app

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8001/health || exit 1

CMD ["./meu-app"]
