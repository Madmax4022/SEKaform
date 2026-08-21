-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — roles de base de datos
--
--  Se ejecuta ANTES de 001_core.sql, una sola vez por instancia.
--
--  Dos roles, a propósito:
--
--    skf_owner  → dueño del esquema. Corre las migraciones. NO lo usa la app.
--    skf_app    → con el que se conecta Cloud Run. Sin BYPASSRLS y sin ser
--                 dueño de las tablas, así que RLS SÍ le aplica.
--
--  Esta separación es la que hace que el aislamiento entre clientes sea real.
--  Si la app se conectara con el dueño del esquema (o con un superusuario),
--  Postgres saltaría todas las policies y el multi-inquilino dependería solo
--  de que ningún WHERE se nos olvide. Con esto, un error de la app es una
--  consulta vacía, no una fuga de datos entre clientes.
--
--  Uso (las contraseñas vienen de Secret Manager, nunca escritas aquí):
--    psql ... -v owner_pw="$OWNER_PW" -v app_pw="$APP_PW" -f 000_roles.sql
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- Extensiones. Van aquí y no en 001_core.sql porque instalarlas requiere
-- privilegios sobre la base que skf_owner deliberadamente no tiene: las pone
-- el administrador de la instancia una sola vez.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skf_owner') THEN
    CREATE ROLE skf_owner LOGIN NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skf_app') THEN
    CREATE ROLE skf_app LOGIN NOBYPASSRLS;
  END IF;
END $$;

ALTER ROLE skf_owner WITH PASSWORD :'owner_pw';
ALTER ROLE skf_app   WITH PASSWORD :'app_pw';

-- Cinturón y tirantes: aunque alguien altere estos roles más adelante, dejamos
-- explícito que jamás deben poder saltarse RLS.
ALTER ROLE skf_owner NOBYPASSRLS;
ALTER ROLE skf_app   NOBYPASSRLS;

GRANT USAGE ON SCHEMA public TO skf_app;

-- La app puede leer y escribir datos, pero no cambiar la forma de la base:
-- nada de CREATE/ALTER/DROP. Los cambios de esquema pasan por una migración
-- corrida como skf_owner, revisada y versionada.
ALTER DEFAULT PRIVILEGES FOR ROLE skf_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO skf_app;
ALTER DEFAULT PRIVILEGES FOR ROLE skf_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO skf_app;
ALTER DEFAULT PRIVILEGES FOR ROLE skf_owner IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO skf_app;

-- Para las tablas que ya existan al momento de correr esto.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO skf_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO skf_app;
GRANT EXECUTE                        ON ALL FUNCTIONS IN SCHEMA public TO skf_app;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
