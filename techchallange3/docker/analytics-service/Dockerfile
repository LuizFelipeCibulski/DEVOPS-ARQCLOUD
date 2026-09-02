# ==========================================
# ESTÁGIO 1: Builder (Compilação com Cache)
# ==========================================
FROM python:3.11-alpine AS builder

WORKDIR /app

# 1. Copia apenas o arquivo de pacotes para o cache do Docker
COPY requirements.txt .

# 3. Baixa as dependências e joga no cache
RUN pip install -r requirements.txt

# 4. Copia o restante do código fonte
COPY app.py .

# ==========================================
# ESTÁGIO 2: Imagem Final de Produção
# ==========================================
FROM python:3.11-alpine AS prod

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copia as dependências instaladas no sistema do builder direto para o sistema do prod
COPY --from=builder /usr/local /usr/local
COPY --from=builder /app /app

# Altera a permissão e muda para o usuário
RUN chown -R appuser:appgroup /app
USER appuser

EXPOSE 8005

CMD ["gunicorn","--bind","0.0.0.0:8005","app:app"]