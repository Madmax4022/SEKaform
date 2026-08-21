-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — esquema base (Cloud SQL / PostgreSQL 15)
--
--  Reemplaza el esquema de Supabase. Diferencias de fondo:
--
--   1. Identidad propia. No hay auth.users de Supabase: los usuarios viven en
--      "users" y las contraseñas son hashes bcrypt gestionados por la app.
--   2. El acceso lo abre un SUPER ADMIN. Nadie se registra por su cuenta si su
--      correo no está en "authorized_emails", y ningún formulario del catálogo
--      es utilizable por una organización sin un "form_access_grants" vigente.
--   3. RLS sigue siendo la última línea de defensa, pero ahora se alimenta de
--      variables de sesión que la app fija en CADA transacción
--      (app.user_id / app.org_id / app.is_super_admin / app.support_mode).
--      Si la app olvida un WHERE org_id = ..., la base de datos igual no
--      devuelve filas de otro cliente.
--   4. Todo id operativo es UUID generado por el CLIENTE. Es lo que hace segura
--      la cola sin conexión: reintentar un envío encolado es un UPSERT sobre el
--      mismo id, nunca un duplicado.
--
--  Idempotente: se puede re-ejecutar completo sin destruir datos.
-- ═══════════════════════════════════════════════════════════════════════════

-- Extensiones: pgcrypto (gen_random_uuid, crypt/bcrypt) y citext (correos sin
-- distinguir mayúsculas).
--
-- Se crean solo si faltan, en vez de con CREATE EXTENSION IF NOT EXISTS a
-- secas: crear una extensión exige privilegios sobre la base que skf_owner no
-- tiene por diseño, y la comprobación previa evita el error cuando ya están
-- instaladas. Las instala el administrador una sola vez (000_roles.sql).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
    CREATE EXTENSION pgcrypto;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'citext') THEN
    CREATE EXTENSION citext;
  END IF;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE EXCEPTION
    'Faltan las extensiones pgcrypto y/o citext, y este rol no puede crearlas. '
    'Créalas una vez como administrador de la instancia: '
    'CREATE EXTENSION pgcrypto; CREATE EXTENSION citext;';
END $$;

-- ── 1 · Contexto de sesión ──────────────────────────────────────────────────
-- La app abre una transacción por request y hace:
--   SET LOCAL app.user_id = '...'; SET LOCAL app.org_id = '...';
--   SET LOCAL app.is_super_admin = 'on'|'off'; SET LOCAL app.support_mode = 'off';
-- current_setting(..., true) devuelve NULL en vez de fallar si no está fijada,
-- así una conexión sin contexto (una migración, un psql manual) no revienta:
-- simplemente no ve nada a través de RLS.

CREATE OR REPLACE FUNCTION skf_ctx_uuid(clave TEXT)
RETURNS UUID LANGUAGE plpgsql STABLE AS $$
DECLARE v TEXT;
BEGIN
  v := current_setting(clave, true);
  IF v IS NULL OR v = '' THEN RETURN NULL; END IF;
  RETURN v::uuid;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION skf_user_id() RETURNS UUID
  LANGUAGE sql STABLE AS $$ SELECT skf_ctx_uuid('app.user_id') $$;

CREATE OR REPLACE FUNCTION skf_org_id() RETURNS UUID
  LANGUAGE sql STABLE AS $$ SELECT skf_ctx_uuid('app.org_id') $$;

CREATE OR REPLACE FUNCTION skf_is_super() RETURNS BOOLEAN
  LANGUAGE sql STABLE AS $$ SELECT COALESCE(current_setting('app.is_super_admin', true), 'off') = 'on' $$;

-- Modo soporte: un super admin NO ve por defecto los datos operativos de los
-- clientes (inspecciones, hallazgos, fotos). Solo los ve si la app activa
-- explícitamente app.support_mode en una ruta que además deja rastro en
-- audit_log. Administrar el acceso ≠ leer la información del cliente.
CREATE OR REPLACE FUNCTION skf_support_mode() RETURNS BOOLEAN
  LANGUAGE sql STABLE AS $$
    SELECT skf_is_super() AND COALESCE(current_setting('app.support_mode', true), 'off') = 'on'
  $$;

-- ── 2 · Organizaciones (el inquilino) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS organizations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre      TEXT NOT NULL,
  slug        CITEXT UNIQUE,
  logo_url    TEXT,                               -- objeto en GCS, no base64
  pais        TEXT,
  plan        TEXT NOT NULL DEFAULT 'emprende'
              CHECK (plan IN ('emprende','pyme','negocio','vertical')),
  activa      BOOLEAN NOT NULL DEFAULT true,
  creado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 3 · Usuarios (identidad propia, sin proveedor externo) ──────────────────
CREATE TABLE IF NOT EXISTS users (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email                 CITEXT NOT NULL UNIQUE,
  password_hash         TEXT,                     -- bcrypt; NULL hasta registrarse
  nombre                TEXT,
  is_super_admin        BOOLEAN NOT NULL DEFAULT false,
  is_active             BOOLEAN NOT NULL DEFAULT true,
  must_change_password  BOOLEAN NOT NULL DEFAULT false,
  failed_login_count    INTEGER NOT NULL DEFAULT 0,
  locked_until          TIMESTAMPTZ,              -- bloqueo temporal por fuerza bruta
  last_login_at         TIMESTAMPTZ,
  creado_en             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS users_email_idx ON users (email);

-- ── 4 · Lista de autorización (la puerta de entrada) ────────────────────────
-- Un correo que no esté aquí, activo y sin usar, no puede crear cuenta. Es el
-- mecanismo con el que el super admin "da acceso" a la plataforma.
CREATE TABLE IF NOT EXISTS authorized_emails (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email          CITEXT NOT NULL UNIQUE,
  org_id         UUID REFERENCES organizations(id) ON DELETE CASCADE,
  rol_inicial    TEXT NOT NULL DEFAULT 'editor'
                 CHECK (rol_inicial IN ('dueno','admin','editor','lector')),
  is_active      BOOLEAN NOT NULL DEFAULT true,
  autorizado_por UUID REFERENCES users(id) ON DELETE SET NULL,
  autorizado_en  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  usado_en       TIMESTAMPTZ,                     -- se sella al registrarse
  expira_en      TIMESTAMPTZ,                     -- invitación con vencimiento
  notas          TEXT
);
CREATE INDEX IF NOT EXISTS authorized_emails_org_idx ON authorized_emails (org_id);

-- ── 5 · Membresías (persona ↔ organización, con rol) ────────────────────────
CREATE TABLE IF NOT EXISTS memberships (
  org_id    UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rol       TEXT NOT NULL DEFAULT 'editor'
            CHECK (rol IN ('dueno','admin','editor','lector')),
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (org_id, user_id)
);
CREATE INDEX IF NOT EXISTS memberships_user_idx ON memberships (user_id);

-- Helpers de autorización. SECURITY DEFINER para que las policies puedan
-- consultar memberships sin volver a disparar RLS sobre memberships.
CREATE OR REPLACE FUNCTION skf_es_miembro(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM memberships WHERE org_id = o AND user_id = skf_user_id());
$$;

CREATE OR REPLACE FUNCTION skf_puede_escribir(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM memberships
                 WHERE org_id = o AND user_id = skf_user_id()
                   AND rol IN ('dueno','admin','editor'));
$$;

CREATE OR REPLACE FUNCTION skf_es_admin_org(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM memberships
                 WHERE org_id = o AND user_id = skf_user_id()
                   AND rol IN ('dueno','admin'));
$$;

-- Lectura de datos operativos: miembro de la organización, o super admin con
-- el modo soporte explícitamente activado.
CREATE OR REPLACE FUNCTION skf_puede_leer(o UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT skf_es_miembro(o) OR skf_support_mode();
$$;

-- ── 6 · Restablecimiento de contraseña ──────────────────────────────────────
-- Se guarda solo el hash del token: quien lea la tabla no puede usarlo.
CREATE TABLE IF NOT EXISTS password_reset_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expira_en  TIMESTAMPTZ NOT NULL,
  usado_en   TIMESTAMPTZ,
  creado_en  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS prt_user_idx ON password_reset_tokens (user_id);

-- ── 7 · Bitácora de auditoría ───────────────────────────────────────────────
-- Append-only. Todo lo que hace un super admin y todo cambio de acceso queda
-- aquí; es lo que convierte "un sitio" en "un sitio auditable".
CREATE TABLE IF NOT EXISTS audit_log (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ocurrido_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actor_id    UUID REFERENCES users(id) ON DELETE SET NULL,
  actor_email CITEXT,
  org_id      UUID REFERENCES organizations(id) ON DELETE SET NULL,
  accion      TEXT NOT NULL,
  entidad     TEXT,
  entidad_id  TEXT,
  detalle     JSONB NOT NULL DEFAULT '{}',
  ip          INET,
  user_agent  TEXT
);

-- ── 8 · Unidades (sede / área / contratista) ────────────────────────────────
CREATE TABLE IF NOT EXISTS unidades (
  id        UUID PRIMARY KEY,
  org_id    UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  nombre    TEXT NOT NULL,
  tipo      TEXT NOT NULL DEFAULT 'sede'
            CHECK (tipo IN ('sede','area','contratista','otro')),
  padre_id  UUID REFERENCES unidades(id) ON DELETE SET NULL,
  activa    BOOLEAN NOT NULL DEFAULT true,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS unidades_org_idx   ON unidades (org_id, tipo);
CREATE INDEX IF NOT EXISTS unidades_padre_idx ON unidades (padre_id);

-- ── 9 · Plantillas ──────────────────────────────────────────────────────────
-- Dos clases conviven en la misma tabla:
--   · catálogo   → es_catalogo = true, org_id IS NULL. Las 69 plantillas del
--                  producto. Se usan según form_access_grants.
--   · de cliente → es_catalogo = false, org_id = la organización dueña.
CREATE TABLE IF NOT EXISTS plantillas (
  id                  UUID PRIMARY KEY,
  org_id              UUID REFERENCES organizations(id) ON DELETE CASCADE,
  es_catalogo         BOOLEAN NOT NULL DEFAULT false,
  vertical            TEXT,
  autor_id            UUID REFERENCES users(id) ON DELETE SET NULL,
  nombre              TEXT NOT NULL,
  codigo              TEXT,
  descripcion         TEXT,
  norma               TEXT,
  campos              JSONB NOT NULL DEFAULT '[]',
  logo_url            TEXT,
  favorito            BOOLEAN NOT NULL DEFAULT false,
  publica             BOOLEAN NOT NULL DEFAULT false,
  share_token         TEXT,
  correo_notificacion TEXT,
  archivada           BOOLEAN NOT NULL DEFAULT false,
  creado_en           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT plantillas_catalogo_sin_org
    CHECK ((es_catalogo AND org_id IS NULL) OR (NOT es_catalogo AND org_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS plantillas_org_idx ON plantillas (org_id, actualizado_en DESC);
CREATE INDEX IF NOT EXISTS plantillas_catalogo_idx ON plantillas (es_catalogo, vertical);
CREATE UNIQUE INDEX IF NOT EXISTS plantillas_share_token_idx
  ON plantillas (share_token) WHERE share_token IS NOT NULL;

-- ── 10 · Concesión de acceso a formularios (control del super admin) ────────
-- Sin una fila vigente aquí, una organización no ve ni puede usar una plantilla
-- del catálogo. Revocar = poner revocado_en; nunca se borra, para conservar el
-- histórico de quién tuvo acceso a qué y desde cuándo.
CREATE TABLE IF NOT EXISTS form_access_grants (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plantilla_id  UUID NOT NULL REFERENCES plantillas(id) ON DELETE CASCADE,
  org_id        UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  otorgado_por  UUID REFERENCES users(id) ON DELETE SET NULL,
  otorgado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revocado_por  UUID REFERENCES users(id) ON DELETE SET NULL,
  revocado_en   TIMESTAMPTZ,
  notas         TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS fag_vigente_idx
  ON form_access_grants (plantilla_id, org_id) WHERE revocado_en IS NULL;
CREATE INDEX IF NOT EXISTS fag_org_idx ON form_access_grants (org_id) WHERE revocado_en IS NULL;

CREATE OR REPLACE FUNCTION skf_tiene_acceso_plantilla(p UUID, o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM form_access_grants
    WHERE plantilla_id = p AND org_id = o AND revocado_en IS NULL
  );
$$;

-- ── 11 · Envíos ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS envios (
  id               UUID PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  plantilla_id     UUID REFERENCES plantillas(id) ON DELETE SET NULL,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  plantilla_codigo TEXT NOT NULL DEFAULT '',
  unidad_id        UUID REFERENCES unidades(id) ON DELETE SET NULL,
  autor_id         UUID REFERENCES users(id) ON DELETE SET NULL,
  datos            JSONB NOT NULL DEFAULT '{}',
  estado           TEXT NOT NULL DEFAULT 'enviado' CHECK (estado IN ('borrador','enviado')),
  numero           INTEGER,
  llenado_por      TEXT,
  llenado_correo   TEXT,
  -- Trazabilidad de campo: cuándo se capturó realmente vs cuándo llegó.
  capturado_en     TIMESTAMPTZ,
  recibido_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  origen           TEXT NOT NULL DEFAULT 'app' CHECK (origen IN ('app','publico','import')),
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  enviado_en       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS envios_org_date_idx  ON envios (org_id, enviado_en DESC);
CREATE INDEX IF NOT EXISTS envios_plantilla_idx ON envios (plantilla_id);
CREATE INDEX IF NOT EXISTS envios_codigo_idx    ON envios (org_id, plantilla_codigo);
CREATE INDEX IF NOT EXISTS envios_unidad_idx    ON envios (unidad_id);

-- Numeración correlativa por plantilla, asignada por el SERVIDOR. El cliente
-- sin conexión no puede saber cuántos envíos existen; si manda un número, se
-- ignora. Un índice único impide que dos envíos simultáneos compartan número.
CREATE OR REPLACE FUNCTION envios_asignar_numero()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.numero IS NULL AND NEW.plantilla_id IS NOT NULL THEN
    SELECT COALESCE(MAX(numero), 0) + 1 INTO NEW.numero
      FROM envios WHERE plantilla_id = NEW.plantilla_id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_envios_numero ON envios;
CREATE TRIGGER trg_envios_numero
  BEFORE INSERT ON envios FOR EACH ROW EXECUTE FUNCTION envios_asignar_numero();

CREATE UNIQUE INDEX IF NOT EXISTS envios_numero_idx
  ON envios (plantilla_id, numero) WHERE plantilla_id IS NOT NULL AND numero IS NOT NULL;

-- ── 12 · Hallazgos (no conformidades) ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS hallazgos (
  id               UUID PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  envio_id         UUID REFERENCES envios(id) ON DELETE SET NULL,
  plantilla_id     UUID REFERENCES plantillas(id) ON DELETE SET NULL,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  campo_id         TEXT,
  campo_etiqueta   TEXT,
  origen           TEXT NOT NULL DEFAULT 'manual'  CHECK (origen IN ('automatico','manual')),
  severidad        TEXT NOT NULL DEFAULT 'menor'   CHECK (severidad IN ('critico','mayor','menor')),
  descripcion      TEXT,
  foto_url         TEXT,
  unidad_id        UUID REFERENCES unidades(id) ON DELETE SET NULL,
  estado           TEXT NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','en_proceso','cerrado')),
  reportado_por    TEXT,
  cerrado_en       TIMESTAMPTZ,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS hallazgos_org_idx       ON hallazgos (org_id, creado_en DESC);
CREATE INDEX IF NOT EXISTS hallazgos_envio_idx     ON hallazgos (envio_id);
CREATE INDEX IF NOT EXISTS hallazgos_estado_idx    ON hallazgos (org_id, estado);
CREATE INDEX IF NOT EXISTS hallazgos_severidad_idx ON hallazgos (org_id, severidad);
CREATE INDEX IF NOT EXISTS hallazgos_unidad_idx    ON hallazgos (unidad_id);

-- ── 13 · Acciones correctivas (CAPA) ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS acciones_correctivas (
  id                   UUID PRIMARY KEY,
  org_id               UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  hallazgo_id          UUID NOT NULL REFERENCES hallazgos(id) ON DELETE CASCADE,
  responsable          TEXT,
  responsable_user_id  UUID REFERENCES users(id) ON DELETE SET NULL,
  correo               TEXT,
  fecha_limite         DATE,
  estado               TEXT NOT NULL DEFAULT 'pendiente'
                       CHECK (estado IN ('pendiente','completada','vencida')),
  evidencia_url        TEXT,
  cerrado_en           TIMESTAMPTZ,
  creado_en            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS capa_hallazgo_idx   ON acciones_correctivas (hallazgo_id);
CREATE INDEX IF NOT EXISTS capa_org_estado_idx ON acciones_correctivas (org_id, estado, fecha_limite);

-- ── 14 · Asignaciones ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS asignaciones (
  id               UUID PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  plantilla_id     UUID NOT NULL REFERENCES plantillas(id) ON DELETE CASCADE,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  unidad_id        UUID REFERENCES unidades(id) ON DELETE SET NULL,
  nombre           TEXT NOT NULL,
  correo           TEXT,
  asignado_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  fecha_limite     DATE,
  completado_en    TIMESTAMPTZ,
  envio_id         UUID REFERENCES envios(id) ON DELETE SET NULL,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS asignaciones_org_idx       ON asignaciones (org_id, creado_en DESC);
CREATE INDEX IF NOT EXISTS asignaciones_plantilla_idx ON asignaciones (plantilla_id);
CREATE INDEX IF NOT EXISTS asignaciones_unidad_idx    ON asignaciones (unidad_id);

-- ── 15 · Inspecciones programadas ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inspecciones_programadas (
  id                UUID PRIMARY KEY,
  org_id            UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  plantilla_id      UUID REFERENCES plantillas(id) ON DELETE SET NULL,
  unidad_id         UUID REFERENCES unidades(id) ON DELETE SET NULL,
  nombre            TEXT NOT NULL,
  frecuencia        TEXT NOT NULL DEFAULT 'mensual'
                    CHECK (frecuencia IN ('diaria','semanal','quincenal','mensual','trimestral','semestral','anual')),
  proximo_en        DATE NOT NULL,
  responsable       TEXT,
  correo            TEXT,
  activa            BOOLEAN NOT NULL DEFAULT true,
  ultimo_completado TIMESTAMPTZ,
  creado_en         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS programadas_org_idx ON inspecciones_programadas (org_id, activa, proximo_en);

-- ── 16 · Medios (fotos, firmas) en Cloud Storage ────────────────────────────
-- Las firmas y fotos ya NO viajan como base64 dentro de datos/JSONB: eso
-- inflaba la fila, el backup y cada consulta del dashboard. Aquí solo queda el
-- puntero al objeto en GCS; el JSONB del envío guarda el media_id.
CREATE TABLE IF NOT EXISTS media_objects (
  id            UUID PRIMARY KEY,
  org_id        UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  envio_id      UUID REFERENCES envios(id) ON DELETE CASCADE,
  hallazgo_id   UUID REFERENCES hallazgos(id) ON DELETE CASCADE,
  campo_id      TEXT,
  clase         TEXT NOT NULL DEFAULT 'foto' CHECK (clase IN ('foto','firma','evidencia','logo')),
  gcs_path      TEXT NOT NULL,
  content_type  TEXT NOT NULL DEFAULT 'image/jpeg',
  bytes         BIGINT,
  sha256        TEXT,
  creado_en     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS media_envio_idx    ON media_objects (envio_id);
CREATE INDEX IF NOT EXISTS media_hallazgo_idx ON media_objects (hallazgo_id);
CREATE INDEX IF NOT EXISTS media_org_idx      ON media_objects (org_id, creado_en DESC);

-- ── 17 · Row Level Security ─────────────────────────────────────────────────
-- ENABLE, deliberadamente SIN "FORCE".
--
-- ENABLE aplica las policies a todo rol MENOS al dueño de la tabla. Como la
-- app se conecta con skf_app —que no es dueño de nada y es NOBYPASSRLS— RLS
-- le aplica por completo. Ese es el aislamiento real (ver 000_roles.sql).
--
-- Añadir FORCE parece "más seguro", pero rompe el modelo: los helpers
-- skf_es_miembro()/skf_puede_escribir() son SECURITY DEFINER y corren como
-- skf_owner justamente para poder consultar "memberships" sin disparar RLS
-- sobre esa misma tabla. Con FORCE, el helper vuelve a pasar por la policy de
-- memberships, que a su vez llama al helper: recursión infinita, y Postgres
-- corta con "stack depth limit exceeded". Está cubierto por tests/rls_test.sql.
--
-- El riesgo que FORCE cubriría —que alguien apunte la app al rol dueño— se
-- ataja en el arranque: app/db.py verifica la identidad de conexión y se niega
-- a levantar si detecta que es dueño de tablas o tiene BYPASSRLS.

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'organizations','users','authorized_emails','memberships','password_reset_tokens',
    'audit_log','unidades','plantillas','form_access_grants','envios','hallazgos',
    'acciones_correctivas','asignaciones','inspecciones_programadas','media_objects'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Policies de datos operativos: se generan en bucle porque son idénticas —
-- leer si eres miembro (o soporte), escribir si además tienes rol de escritura.
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'unidades','envios','hallazgos','acciones_correctivas',
    'asignaciones','inspecciones_programadas','media_objects'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_sel ON %I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I_ins ON %I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I_upd ON %I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS %I_del ON %I', t, t);
    EXECUTE format('CREATE POLICY %I_sel ON %I FOR SELECT USING (skf_puede_leer(org_id))', t, t);
    EXECUTE format('CREATE POLICY %I_ins ON %I FOR INSERT WITH CHECK (skf_puede_escribir(org_id))', t, t);
    EXECUTE format('CREATE POLICY %I_upd ON %I FOR UPDATE USING (skf_puede_escribir(org_id))', t, t);
    EXECUTE format('CREATE POLICY %I_del ON %I FOR DELETE USING (skf_es_admin_org(org_id))', t, t);
  END LOOP;
END $$;

-- Organizaciones: la ve su gente; el super admin administra todas.
DROP POLICY IF EXISTS org_sel ON organizations;
CREATE POLICY org_sel ON organizations FOR SELECT
  USING (skf_es_miembro(id) OR skf_is_super());
DROP POLICY IF EXISTS org_ins ON organizations;
CREATE POLICY org_ins ON organizations FOR INSERT WITH CHECK (skf_is_super());
DROP POLICY IF EXISTS org_upd ON organizations;
CREATE POLICY org_upd ON organizations FOR UPDATE
  USING (skf_es_admin_org(id) OR skf_is_super());
DROP POLICY IF EXISTS org_del ON organizations;
CREATE POLICY org_del ON organizations FOR DELETE USING (skf_is_super());

-- Usuarios: cada quien se ve a sí mismo, los compañeros de organización se ven
-- entre sí, y el super admin ve y administra a todos.
DROP POLICY IF EXISTS users_sel ON users;
CREATE POLICY users_sel ON users FOR SELECT USING (
  id = skf_user_id() OR skf_is_super()
  OR EXISTS (SELECT 1 FROM memberships m1
             JOIN memberships m2 ON m1.org_id = m2.org_id
             WHERE m1.user_id = skf_user_id() AND m2.user_id = users.id)
);
DROP POLICY IF EXISTS users_ins ON users;
CREATE POLICY users_ins ON users FOR INSERT WITH CHECK (skf_is_super());
DROP POLICY IF EXISTS users_upd ON users;
CREATE POLICY users_upd ON users FOR UPDATE USING (id = skf_user_id() OR skf_is_super());
DROP POLICY IF EXISTS users_del ON users;
CREATE POLICY users_del ON users FOR DELETE USING (skf_is_super());

-- Lista de autorización y concesiones de formulario: territorio del super
-- admin. Un admin de organización puede LEER lo suyo para saber a quién invitó.
DROP POLICY IF EXISTS ae_sel ON authorized_emails;
CREATE POLICY ae_sel ON authorized_emails FOR SELECT
  USING (skf_is_super() OR (org_id IS NOT NULL AND skf_es_admin_org(org_id)));
DROP POLICY IF EXISTS ae_all ON authorized_emails;
CREATE POLICY ae_all ON authorized_emails FOR ALL
  USING (skf_is_super()) WITH CHECK (skf_is_super());

DROP POLICY IF EXISTS fag_sel ON form_access_grants;
CREATE POLICY fag_sel ON form_access_grants FOR SELECT
  USING (skf_is_super() OR skf_es_miembro(org_id));
DROP POLICY IF EXISTS fag_all ON form_access_grants;
CREATE POLICY fag_all ON form_access_grants FOR ALL
  USING (skf_is_super()) WITH CHECK (skf_is_super());

-- Membresías: visibles dentro de la organización, modificables por su admin.
DROP POLICY IF EXISTS mem_sel ON memberships;
CREATE POLICY mem_sel ON memberships FOR SELECT
  USING (skf_es_miembro(org_id) OR skf_is_super());
DROP POLICY IF EXISTS mem_all ON memberships;
CREATE POLICY mem_all ON memberships FOR ALL
  USING (skf_es_admin_org(org_id) OR skf_is_super())
  WITH CHECK (skf_es_admin_org(org_id) OR skf_is_super());

-- Plantillas: las del catálogo se ven si hay concesión vigente; las propias,
-- si eres miembro. Escribir solo sobre las propias — el catálogo lo cura el
-- super admin, un cliente no puede editarlo ni borrarlo.
DROP POLICY IF EXISTS plant_sel ON plantillas;
CREATE POLICY plant_sel ON plantillas FOR SELECT USING (
  skf_is_super()
  OR (es_catalogo AND skf_org_id() IS NOT NULL AND skf_tiene_acceso_plantilla(id, skf_org_id()))
  OR (NOT es_catalogo AND skf_puede_leer(org_id))
);
DROP POLICY IF EXISTS plant_ins ON plantillas;
CREATE POLICY plant_ins ON plantillas FOR INSERT WITH CHECK (
  skf_is_super() OR (NOT es_catalogo AND skf_puede_escribir(org_id))
);
DROP POLICY IF EXISTS plant_upd ON plantillas;
CREATE POLICY plant_upd ON plantillas FOR UPDATE USING (
  skf_is_super() OR (NOT es_catalogo AND skf_puede_escribir(org_id))
);
DROP POLICY IF EXISTS plant_del ON plantillas;
CREATE POLICY plant_del ON plantillas FOR DELETE USING (
  skf_is_super() OR (NOT es_catalogo AND skf_es_admin_org(org_id))
);

-- Auditoría: se lee, no se altera. Ni siquiera el super admin puede editar o
-- borrar una entrada — sin esa garantía la bitácora no vale como evidencia.
DROP POLICY IF EXISTS audit_sel ON audit_log;
CREATE POLICY audit_sel ON audit_log FOR SELECT
  USING (skf_is_super() OR (org_id IS NOT NULL AND skf_es_admin_org(org_id)));
DROP POLICY IF EXISTS audit_ins ON audit_log;
CREATE POLICY audit_ins ON audit_log FOR INSERT WITH CHECK (true);

-- Tokens de restablecimiento: nadie los lee vía la app. Solo el flujo de
-- recuperación, que corre con contexto elevado y los consulta por hash.
DROP POLICY IF EXISTS prt_none ON password_reset_tokens;
CREATE POLICY prt_none ON password_reset_tokens FOR ALL USING (false) WITH CHECK (false);

-- ── 18 · Mantenimiento de actualizado_en ────────────────────────────────────
CREATE OR REPLACE FUNCTION skf_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.actualizado_en := NOW(); RETURN NEW; END $$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['organizations','users','plantillas','hallazgos'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_touch_%I ON %I', t, t);
    EXECUTE format('CREATE TRIGGER trg_touch_%I BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION skf_touch()', t, t);
  END LOOP;
END $$;
