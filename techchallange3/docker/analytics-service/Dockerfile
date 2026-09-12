# ==========================================
# ESTÁGIO 1: Builder
# ==========================================
FROM python:3.11-alpine AS builder

# Atualiza pacotes do SO no builder também (evita libs de sistema desatualizadas
# sendo usadas na compilação de wheels)
RUN apk upgrade --no-cache

WORKDIR /app

# Argumento para forçar rebuild sem cache quando necessário:
# docker build --build-arg CACHEBUST=$(date +%s) -t analytics-service:v7 .
ARG CACHEBUST=1

COPY requirements.txt .

# --force-reinstall garante que as versões pinadas realmente substituam
# as que já vêm na imagem base (evita CVEs "fantasmas" de versões antigas
# sobrevivendo no build final)
#RUN python -m pip install --no-cache-dir --no-compile --prefer-binary -r requirements.txt

RUN pip install -r requirements.txt

COPY app.py .


# ==========================================
# ESTÁGIO 2: Produção
# ==========================================
FROM python:3.11-alpine AS prod

# Atualiza pacotes do Alpine
RUN apk upgrade --no-cache

RUN addgroup -S appgroup && \
    adduser -S appuser -G appgroup

WORKDIR /app

# Copia somente o ambiente Python já atualizado
COPY --from=builder /usr/local /usr/local
COPY --from=builder /app /app

# Remove o toolchain de build da imagem final. O setuptools da imagem base
# carrega dependências "vendored" (jaraco.context, wheel) que o Trivy reporta
# como HIGH; em runtime Flask/gunicorn não precisam de pip/setuptools.
RUN rm -rf /usr/local/lib/python3.11/site-packages/pip \
           /usr/local/lib/python3.11/site-packages/pip-* \
           /usr/local/lib/python3.11/site-packages/setuptools \
           /usr/local/lib/python3.11/site-packages/setuptools-* \
           /usr/local/lib/python3.11/site-packages/pkg_resources \
           /usr/local/lib/python3.11/site-packages/wheel \
           /usr/local/lib/python3.11/site-packages/wheel-* \
           /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.11 \
           /usr/local/bin/wheel && \
    chown -R appuser:appgroup /app

USER appuser

EXPOSE 8005

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8005/health')" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8005", "app:app"]

