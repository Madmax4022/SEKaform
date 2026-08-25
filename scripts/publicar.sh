#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Construye y publica la imagen de SEKaform en Artifact Registry.
#
#    ./scripts/publicar.sh [etiqueta]        # por defecto: v<timestamp>
#
#  Existe por una razón concreta: Cloud Run solo ejecuta linux/amd64, y en un
#  Mac con Apple Silicon `docker build` produce arm64 sin avisar. El push
#  funciona, el despliegue "termina bien" y el contenedor muere con
#  «failed to load /bin/sh: exec format error», que no dice nada obvio.
#
#  Aquí la plataforma se fuerza SIEMPRE y, además, se verifica la arquitectura
#  de la imagen construida ANTES de subirla. Si algo la deja en arm64, el
#  script se detiene en local en vez de fallar 5 minutos después en GCP.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

PROYECTO="${SKF_PROYECTO:-tz-dev-sekaform}"
REGION="${SKF_REGION:-us-central1}"
REPO="${SKF_REPO:-${PROYECTO}-repo}"
PLATAFORMA="linux/amd64"

# Etiqueta nueva en cada publicación. Reutilizar la misma (":v1") es la receta
# para desplegar sin querer una imagen vieja: Terraform no ve cambios en la
# variable «imagen» y da "No changes" aunque el contenido sea distinto.
ETIQUETA="${1:-v$(date +%Y%m%d-%H%M%S)}"
IMAGEN="${REGION}-docker.pkg.dev/${PROYECTO}/${REPO}/sekaform:${ETIQUETA}"

rojo(){ printf '\033[31m%s\033[0m\n' "$*"; }
verde(){ printf '\033[32m%s\033[0m\n' "$*"; }
info(){ printf '\033[36m→ %s\033[0m\n' "$*"; }

info "Construyendo para ${PLATAFORMA} (obligatorio para Cloud Run)…"
docker build --platform "$PLATAFORMA" -t "$IMAGEN" .

# ── Verificación antes de publicar ────────────────────────────────────────
info "Comprobando la arquitectura de la imagen…"
ARQ=$(docker image inspect "$IMAGEN" --format '{{.Os}}/{{.Architecture}}')
if [ "$ARQ" != "$PLATAFORMA" ]; then
  rojo "✗ La imagen quedó en ${ARQ}, no en ${PLATAFORMA}."
  rojo "  Cloud Run la rechazaría con «exec format error». No se publica."
  exit 1
fi
verde "  ✓ ${ARQ}"

info "Publicando…"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null 2>&1
docker push "$IMAGEN"

# Se despliega por digest, no por etiqueta: la etiqueta puede reapuntarse y
# entonces "lo que corre" deja de ser "lo que se probó".
DIGEST=$(docker image inspect "$IMAGEN" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "$IMAGEN")

verde "
✓ Publicada."
cat <<TXT

  Pon esto en infra/cliente.tfvars:

    desplegar_app = true
    imagen        = "${DIGEST}"

  y aplica:

    cd infra && terraform apply -var-file=cliente.tfvars

TXT
