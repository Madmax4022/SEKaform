#!/usr/bin/env bash
# Corre las migraciones contra Cloud SQL a través del Auth Proxy.
#
#   ./scripts/migrar.sh <connection_name> <db_name>
#
# Las migraciones se ejecutan como skf_owner (dueño del esquema) y NUNCA como
# skf_app: la aplicación no debe poder alterar la forma de la base.
set -euo pipefail

CONN="${1:?Falta el connection_name (proyecto:region:instancia)}"
DB="${2:?Falta el nombre de la base}"
PUERTO="${PUERTO:-55432}"

command -v cloud-sql-proxy >/dev/null || {
  echo "Falta cloud-sql-proxy: https://github.com/GoogleCloudPlatform/cloud-sql-proxy" >&2
  exit 1
}

echo "→ Recuperando credenciales de Secret Manager…"
OWNER_PW="$(gcloud secrets versions access latest --secret=skf-db-owner-password)"
APP_PW="$(gcloud secrets versions access latest --secret=skf-database-url \
  | sed -n 's|.*://skf_app:\([^@]*\)@.*|\1|p' \
  | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')"

echo "→ Abriendo el proxy en 127.0.0.1:${PUERTO}…"
cloud-sql-proxy "${CONN}" --port "${PUERTO}" &
PROXY=$!
trap 'kill "${PROXY}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  pg_isready -h 127.0.0.1 -p "${PUERTO}" >/dev/null 2>&1 && break
  sleep 1
done

correr() {
  echo "→ $1"
  PGPASSWORD="${OWNER_PW}" psql \
    "host=127.0.0.1 port=${PUERTO} dbname=${DB} user=skf_owner sslmode=disable" \
    -v ON_ERROR_STOP=1 -q "${@:2}" -f "$1"
}

correr migrations/000_roles.sql -v owner_pw="${OWNER_PW}" -v app_pw="${APP_PW}"
correr migrations/001_core.sql
correr migrations/002_auth_functions.sql
correr migrations/003_super_admin_invitacion.sql
correr migrations/004_publico.sql
correr migrations/005_paneles.sql

echo "✓ Migraciones aplicadas."
