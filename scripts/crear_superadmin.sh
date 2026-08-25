#!/usr/bin/env bash
# Autoriza un correo Y lo marca como super administrador.
#
#   ./scripts/crear_superadmin.sh alguien@kanansentinel.com <connection_name> <db>
#
# Nunca fija una contraseña: solo autoriza el correo. La persona entra a
# /registro y elige su propia clave, que se hashea con bcrypt dentro de la
# base. Así ninguna contraseña inicial existe en un script, un log o el
# historial de la terminal.
#
# Es idempotente: córrelo una vez para autorizar y otra vez, tras el registro,
# para promover a super admin.
set -euo pipefail

EMAIL="${1:?Falta el correo}"
CONN="${2:?Falta el connection_name}"
DB="${3:?Falta el nombre de la base}"
PUERTO="${PUERTO:-55432}"

OWNER_PW="$(gcloud secrets versions access latest --secret=skf-db-owner-password)"
cloud-sql-proxy "${CONN}" --port "${PUERTO}" &
PROXY=$!
trap 'kill "${PROXY}" 2>/dev/null || true' EXIT
sleep 4

PGPASSWORD="${OWNER_PW}" psql \
  "host=127.0.0.1 port=${PUERTO} dbname=${DB} user=skf_owner sslmode=disable" \
  -v ON_ERROR_STOP=1 -v email="${EMAIL}" <<'SQL'
BEGIN;

-- Parte 1 — autoriza el correo (efectiva antes de que se registre).
INSERT INTO authorized_emails (email, rol_inicial, is_active, notas)
VALUES (:'email', 'dueno', true, 'Super administrador de plataforma')
ON CONFLICT (email) DO UPDATE
  SET is_active = true, usado_en = NULL, expira_en = NULL;

-- Parte 2 — promueve la cuenta (no hace nada hasta que exista).
UPDATE users SET is_super_admin = true, is_active = true WHERE email = :'email';

COMMIT;

SELECT email,
       CASE WHEN EXISTS (SELECT 1 FROM users u WHERE u.email = :'email')
            THEN 'registrado' ELSE 'pendiente de registro' END AS estado
  FROM authorized_emails WHERE email = :'email';
SQL

echo "✓ Listo. Si aparece «pendiente de registro», la persona debe entrar a /registro"
echo "  y luego debes volver a correr este script para promoverla."
