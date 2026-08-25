# ═══════════════════════════════════════════════════════════════════════════
#  Kanan Sentinel · SEKaform — imagen de Cloud Run
#
#  Construcción en dos etapas: las dependencias se compilan en una imagen con
#  compilador y solo los paquetes ya construidos pasan a la imagen final. Así
#  gcc y las cabeceras de desarrollo no viajan a producción — menos superficie
#  de ataque y una imagen bastante más pequeña, que en Cloud Run se traduce en
#  arranques en frío más cortos.
#
#  Cloud Run solo ejecuta imágenes linux/amd64. En un Mac con Apple Silicon
#  hay que construir con:
#      docker build --platform linux/amd64 -t <imagen> .
#  Sin esa bandera el push funciona y el contenedor falla al arrancar, con un
#  error poco descriptivo en los logs de Cloud Run.
# ═══════════════════════════════════════════════════════════════════════════

FROM python:3.11-slim AS build

ENV PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /install
COPY requirements.txt .
RUN pip install --prefix=/install/deps -r requirements.txt


# ── Imagen final ───────────────────────────────────────────────────────────
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

# libpq5 es la biblioteca de ejecución de PostgreSQL: psycopg2 la necesita,
# pero no hace falta libpq-dev ni el compilador.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /usr/sbin/nologin skf

COPY --from=build /install/deps /usr/local

WORKDIR /app
COPY --chown=skf:skf . .

# Nada de root en ejecución: si alguien logra ejecución remota, no arranca
# con permisos de administrador dentro del contenedor.
USER skf

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; \
      sys.exit(0 if urllib.request.urlopen('http://localhost:8080/healthz', timeout=4).status==200 else 1)"

# Un worker con hilos encaja con el modelo de Cloud Run: escala por
# instancias, no por procesos, y cada instancia mantiene pocas conexiones a
# Cloud SQL (importante: en instancias pequeñas el límite es bajo).
# --timeout 120 deja margen para OCR de PDFs grandes; --graceful-timeout evita
# cortar una sincronización a medias cuando Cloud Run recicla la instancia.
CMD exec gunicorn \
      --bind :$PORT \
      --workers 1 \
      --threads 8 \
      --timeout 120 \
      --graceful-timeout 30 \
      --access-logfile - \
      --error-logfile - \
      'app:crear_app()'
