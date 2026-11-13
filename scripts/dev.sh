#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Entorno local completo — la forma de verificar TODO antes de tocar GCP.
#
#    ./scripts/dev.sh up       levanta Postgres, migra, siembra y arranca la app
#    ./scripts/dev.sh test     solo las pruebas (lo mismo que corre el CI)
#    ./scripts/dev.sh psql     abre una consola SQL contra la base local
#    ./scripts/dev.sh down     borra el entorno local
#
#  Reproduce la separación de roles de producción (skf_owner migra, skf_app
#  sirve), porque es justo lo que hace que RLS aísle de verdad. Un entorno
#  local que se conecte como superusuario no probaría nada.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

# Git Bash en Windows reescribe todo argumento que parezca ruta Unix («/tmp/x»
# pasa a ser «C:/Users/…/Temp/x») antes de entregárselo a docker.exe, y las
# rutas de DENTRO del contenedor dejan de existir. Esto lo apaga; en Linux y
# macOS la variable no significa nada.
export MSYS_NO_PATHCONV=1
# En Windows Python lee y escribe en cp1252 salvo que se le pida UTF-8, y el
# catálogo tiene tildes y símbolos que cp1252 no sabe representar.
export PYTHONUTF8=1

CONTENEDOR=skf-dev-pg
PUERTO=${PUERTO:-55432}
DB=skf
OWNER_PW=devowner
APP_PW=devapp
APP_PUERTO=${APP_PUERTO:-8080}

DSN_OWNER="postgresql://skf_owner:${OWNER_PW}@127.0.0.1:${PUERTO}/${DB}"
DSN_APP="postgresql://skf_app:${APP_PW}@127.0.0.1:${PUERTO}/${DB}"

rojo(){ printf '\033[31m%s\033[0m\n' "$*"; }
verde(){ printf '\033[32m%s\033[0m\n' "$*"; }
info(){ printf '\033[36m→ %s\033[0m\n' "$*"; }

en_pg(){ docker exec -i "$CONTENEDOR" "$@"; }

psql_owner(){ en_pg psql "postgresql://skf_owner:${OWNER_PW}@127.0.0.1:5432/${DB}" "$@"; }
psql_app(){   en_pg psql "postgresql://skf_app:${APP_PW}@127.0.0.1:5432/${DB}" "$@"; }

levantar_pg(){
  if docker ps --format '{{.Names}}' | grep -qx "$CONTENEDOR"; then
    info "Postgres ya está arriba."
    return
  fi
  docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true
  info "Levantando PostgreSQL 15 en el puerto ${PUERTO}…"
  docker run -d --name "$CONTENEDOR" \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB="$DB" \
    -p "${PUERTO}:5432" postgres:15-alpine >/dev/null

  # Se pregunta por TCP (-h 127.0.0.1) y no por el socket: en el primer
  # arranque la imagen levanta un servidor provisional que solo escucha en el
  # socket, lo apaga y arranca el definitivo. Por el socket pg_isready dice
  # «listo» durante ese provisional y el psql de abajo cae justo en el hueco.
  local listo=0
  for _ in $(seq 1 60); do
    if en_pg pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then listo=1; break; fi
    sleep 1
  done
  [ "$listo" -eq 1 ] || { rojo "Postgres no respondió a tiempo. Revisa: docker logs $CONTENEDOR"; return 1; }

  info "Instalando extensiones y creando los roles skf_owner y skf_app…"
  en_pg psql -U postgres -d "$DB" -q -v ON_ERROR_STOP=1 <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='skf_owner') THEN
    CREATE ROLE skf_owner LOGIN NOBYPASSRLS PASSWORD '${OWNER_PW}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='skf_app') THEN
    CREATE ROLE skf_app LOGIN NOBYPASSRLS PASSWORD '${APP_PW}';
  END IF;
END \$\$;
GRANT CREATE, USAGE ON SCHEMA public TO skf_owner;
SQL
}

migrar(){
  info "Aplicando migraciones como skf_owner…"
  # Todas las numeradas, en orden, sin lista escrita a mano: la lista se quedó
  # en la 005 mientras el esquema llegaba a la 016, y la app arrancaba contra
  # una base a medias. 000_roles.sql se salta: sus roles y extensiones ya los
  # creó levantar_pg como superusuario, que es quien puede hacerlo.
  local f
  for f in migrations/[0-9][0-9][0-9]_*.sql; do
    [ "$(basename "$f")" = "000_roles.sql" ] && continue
    docker cp "$f" "$CONTENEDOR:/tmp/$(basename "$f")" >/dev/null
    psql_owner -q -v ON_ERROR_STOP=1 -f "/tmp/$(basename "$f")"
  done

  info "Otorgando permisos de ejecución a skf_app…"
  # GRANT ... ON ALL FUNCTIONS toca también las funciones que traen pgcrypto y
  # citext, cuyo dueño no es skf_owner: Postgres avisa «no privileges were
  # granted» por cada una. Es inocuo y muy ruidoso, así que se filtra.
  psql_owner -q -v ON_ERROR_STOP=1 <<'SQL' 2>&1 | grep -v "no privileges were granted" || true
GRANT USAGE ON SCHEMA public TO skf_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO skf_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO skf_app;
GRANT EXECUTE                        ON ALL FUNCTIONS IN SCHEMA public TO skf_app;
SQL
}

pruebas(){
  local fallos=0

  info "Pruebas del frontend (node)…"
  node tests/analyzeText.test.cjs   >/dev/null && verde "  ✓ analyzeText" || { rojo "  ✗ analyzeText"; fallos=1; }
  node tests/fieldTypes.test.cjs    >/dev/null && verde "  ✓ fieldTypes"  || { rojo "  ✗ fieldTypes";  fallos=1; }
  node tests/codigoPlantilla.test.cjs >/dev/null && verde "  ✓ codigoPlantilla" || { rojo "  ✗ codigoPlantilla"; fallos=1; }

  info "Aislamiento entre clientes (RLS), como skf_app…"
  docker cp tests/rls_test.sql "$CONTENEDOR:/tmp/rls.sql" >/dev/null
  local salida
  salida=$(psql_app -q -v ON_ERROR_STOP=1 -f /tmp/rls.sql 2>&1 || true)
  if grep -q "RLS OK" <<<"$salida"; then
    verde "  ✓ $(grep -o 'RLS OK.*' <<<"$salida")"
  else
    rojo "  ✗ FALLO DE AISLAMIENTO — no despliegues"; fallos=1
  fi

  info "Autenticación…"
  docker cp tests/auth_test.sql "$CONTENEDOR:/tmp/auth.sql" >/dev/null
  salida=$(psql_app -q -v ON_ERROR_STOP=1 -f /tmp/auth.sql 2>&1 || true)
  if grep -q "AUTH OK" <<<"$salida"; then
    verde "  ✓ $(grep -o 'AUTH OK.*' <<<"$salida")"
  else
    rojo "  ✗ FALLO DE AUTENTICACIÓN"; fallos=1
  fi

  info "Alta de super administrador…"
  docker cp tests/superadmin_test.sql "$CONTENEDOR:/tmp/super.sql" >/dev/null
  salida=$(psql_app -q -v ON_ERROR_STOP=1 -f /tmp/super.sql 2>&1 || true)
  if grep -q "SUPERADMIN OK" <<<"$salida"; then
    verde "  ✓ $(grep -o 'SUPERADMIN OK.*' <<<"$salida")"
  else
    rojo "  ✗ FALLO EN EL ALTA DE SUPER ADMIN"; fallos=1
  fi

  info "Idempotencia de migraciones (segunda pasada)…"
  if psql_owner -q -v ON_ERROR_STOP=1 -f /tmp/001_core.sql >/dev/null 2>&1; then
    verde "  ✓ re-ejecutable sin errores"
  else
    rojo "  ✗ las migraciones no son idempotentes"; fallos=1
  fi

  [ "$fallos" -eq 0 ] && verde "
Todo en verde." || { rojo "
Hay fallos: revísalos antes de desplegar."; return 1; }
}

# El intérprete de Python que de verdad funciona. En Windows «python3» suele ser
# un acceso directo a la tienda que existe en el PATH pero no ejecuta nada, así
# que no basta con que el nombre exista: hay que probarlo.
python_local(){
  local candidato
  for candidato in python3 python py; do
    if "$candidato" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
      echo "$candidato"
      return
    fi
  done
  rojo "No encontré Python 3. Instálalo y vuelve a intentar." >&2
  return 1
}

sembrar(){
  info "Sembrando el catálogo de plantillas…"
  local py sql
  py=$(python_local)
  # Se genera primero y se envía después por la entrada estándar: sin archivo
  # temporal en el equipo (su ruta no es la misma para bash que para docker en
  # Windows) y, si el generador falla, a la base no llega nada a medias.
  sql=$("$py" scripts/seed_catalogo.py)
  psql_owner -q -v ON_ERROR_STOP=1 <<<"$sql"
}

arrancar_app(){
  info "Construyendo la imagen…"
  docker build -q -t sekaform:dev . >/dev/null

  docker rm -f skf-dev-app >/dev/null 2>&1 || true
  local pghost
  pghost=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTENEDOR")

  info "Arrancando la aplicación…"
  docker run -d --name skf-dev-app -p "${APP_PUERTO}:8080" \
    -e SKF_ENV=local \
    -e SECRET_KEY=clave-solo-para-desarrollo-no-usar-en-produccion \
    -e DATABASE_URL="postgresql://skf_app:${APP_PW}@${pghost}:5432/${DB}" \
    sekaform:dev >/dev/null

  sleep 6
  if docker logs skf-dev-app 2>&1 | grep -q "Aislamiento verificado"; then
    verde "
✓ SEKaform corriendo en http://localhost:${APP_PUERTO}"
    echo "
  Todavía no hay ninguna cuenta. Para crear la primera:
    ./scripts/dev.sh superadmin tu.correo@kanansentinel.com
  y luego regístrate en http://localhost:${APP_PUERTO}/registro
"
  else
    rojo "La aplicación no arrancó. Registro:"
    docker logs skf-dev-app 2>&1 | tail -20
    return 1
  fi
}

superadmin(){
  local email="${1:?Falta el correo}"
  # Usa la misma función que producción (migrations/003) en vez de SQL a mano:
  # así el entorno local ejercita el camino real y no una variante que se
  # queda atrás cuando el esquema cambia. Crea además una organización de
  # desarrollo, porque sin ella las rutas de datos responden 403.
  psql_owner -q -v ON_ERROR_STOP=1 -v email="$email" <<'SQL'
INSERT INTO organizations (id, nombre, pais, plan)
VALUES ('00000000-0000-4000-a000-000000000001', 'Organización de desarrollo', 'Colombia', 'vertical')
ON CONFLICT (id) DO NOTHING;

SELECT skf_autorizar_super_admin(:'email', '00000000-0000-4000-a000-000000000001');

-- Si la cuenta ya existía, asegúrale también la membresía.
INSERT INTO memberships (org_id, user_id, rol)
SELECT '00000000-0000-4000-a000-000000000001', id, 'dueno' FROM users WHERE email = :'email'
ON CONFLICT (org_id, user_id) DO UPDATE SET rol = 'dueno';
SQL
  verde "✓ ${email} autorizado como super admin."
  echo "  Regístrate en http://localhost:${APP_PUERTO}/registro (si aún no lo hiciste)"
  echo "  y entra a http://localhost:${APP_PUERTO}/admin"
}

case "${1:-up}" in
  up)         levantar_pg; migrar; pruebas; sembrar; arrancar_app ;;
  test)       levantar_pg; migrar; pruebas ;;
  seed)       sembrar ;;
  superadmin) superadmin "${2:-}" ;;
  psql)       psql_owner ;;
  logs)       docker logs -f skf-dev-app ;;
  down)       docker rm -f "$CONTENEDOR" skf-dev-app >/dev/null 2>&1 || true; verde "Entorno local eliminado." ;;
  *)          sed -n '2,14p' "$0" ;;
esac
