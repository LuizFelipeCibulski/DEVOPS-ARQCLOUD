# ==========================================
# ESTÁGIO 1: Builder
# ==========================================
FROM python:3.11-alpine AS builder

# Atualiza pacotes do SO no builder (evita libs de sistema desatualizadas
# sendo usadas na compilação de wheels)
RUN apk upgrade --no-cache

WORKDIR /app

# Argumento para forçar rebuild sem cache quando necessário:
# docker build --build-arg CACHEBUST=$(date +%s) -t flag-service:v2 .
ARG CACHEBUST=1

COPY requirements.txt .

RUN python -m pip install --no-cache-dir --no-compile --prefer-binary -r requirements.txt

COPY app.py .

# ==========================================
# ESTÁGIO 2: Produção
# ==========================================
FROM python:3.11-alpine AS prod

# Fecha CVEs de pacotes Alpine que já vêm na base (ex.: libuuid/util-linux)
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

EXPOSE 8003

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8003/health')" || exit 1

CMD ["gunicorn","--bind","0.0.0.0:8003","app:app"]
