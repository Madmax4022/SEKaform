-- ═══════════════════════════════════════════════════════════════════════════
--  SEKaform — Esquema refundado (multi-organización)
--
--  Modelo: los datos pertenecen a una ORGANIZACIÓN, no a una persona. Las
--  personas son MIEMBROS de una organización con un ROL (dueño/admin/editor/
--  lector). Cada registro operativo (envío, hallazgo, asignación) puede
--  etiquetarse con una UNIDAD (sede/área/contratista) para comparar y reportar.
--
--  Fuente de verdad: la NUBE. El cliente guarda una caché local y una cola de
--  sincronización para resiliencia sin conexión, pero la verdad vive aquí.
--
--  ┌───────────────────────────────────────────────────────────────────────┐
--  │  ⚠️  RESET LIMPIO — este script BORRA las tablas del modelo anterior    │
--  │  (basado en user_id) y las recrea sobre organizaciones. Autorizado      │
--  │  como refundación de prototipo (sin datos reales que conservar).        │
--  │  Si algún día hay datos en producción, NO corras la sección de reset.   │
--  └───────────────────────────────────────────────────────────────────────┘
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0 · RESET (solo prototipo) ───────────────────────────────────────────────
DROP TABLE IF EXISTS acciones_correctivas CASCADE;
DROP TABLE IF EXISTS inspecciones_programadas CASCADE;
DROP TABLE IF EXISTS hallazgos CASCADE;
DROP TABLE IF EXISTS asignaciones CASCADE;
DROP TABLE IF EXISTS envios CASCADE;
DROP TABLE IF EXISTS plantillas CASCADE;
DROP TABLE IF EXISTS unidades CASCADE;
DROP TABLE IF EXISTS ubicaciones CASCADE;      -- reemplazada por "unidades"
DROP TABLE IF EXISTS miembros CASCADE;
DROP TABLE IF EXISTS organizaciones CASCADE;

-- ── 1 · Organizaciones (dueñas de todos los datos) ───────────────────────────
CREATE TABLE organizaciones (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre     TEXT NOT NULL DEFAULT 'Mi empresa',
  logo       TEXT,                                   -- para reportes con marca
  pais       TEXT,                                   -- país/región (opcional, base multi-país)
  plan       TEXT NOT NULL DEFAULT 'emprende'
             CHECK (plan IN ('emprende','pyme','negocio','vertical')),
  creado_por UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  creado_en  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 2 · Miembros (personas ↔ organización, con rol) ──────────────────────────
CREATE TABLE miembros (
  org_id    UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  user_id   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rol       TEXT NOT NULL DEFAULT 'editor'
            CHECK (rol IN ('dueno','admin','editor','lector')),
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (org_id, user_id)
);
CREATE INDEX miembros_user_idx ON miembros (user_id);

-- ── 3 · Helpers de autorización (SECURITY DEFINER evita recursión de RLS) ─────
-- Se leen desde las policies de todas las tablas. Al ser SECURITY DEFINER
-- consultan "miembros" sin volver a disparar RLS sobre esa misma tabla.
CREATE OR REPLACE FUNCTION skf_es_miembro(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM miembros WHERE org_id = o AND user_id = (select auth.uid()));
$$;

CREATE OR REPLACE FUNCTION skf_puede_escribir(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM miembros
                 WHERE org_id = o AND user_id = (select auth.uid())
                   AND rol IN ('dueno','admin','editor'));
$$;

CREATE OR REPLACE FUNCTION skf_es_admin(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM miembros
                 WHERE org_id = o AND user_id = (select auth.uid())
                   AND rol IN ('dueno','admin'));
$$;

ALTER TABLE organizaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE miembros ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Miembros ven su organización"
  ON organizaciones FOR SELECT USING (skf_es_miembro(id));
CREATE POLICY "Cualquiera crea su organización"
  ON organizaciones FOR INSERT TO authenticated
  WITH CHECK (creado_por = (select auth.uid()));
CREATE POLICY "Admins editan su organización"
  ON organizaciones FOR UPDATE USING (skf_es_admin(id));

CREATE POLICY "Miembros se ven entre sí"
  ON miembros FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Admins agregan miembros"
  ON miembros FOR INSERT WITH CHECK (skf_es_admin(org_id));
CREATE POLICY "Admins editan miembros"
  ON miembros FOR UPDATE USING (skf_es_admin(org_id));
CREATE POLICY "Admins quitan miembros"
  ON miembros FOR DELETE USING (skf_es_admin(org_id));

-- ── 4 · Aprovisionamiento automático al registrarse ──────────────────────────
-- Onboarding sin fricción: al crearse un usuario nuevo se le crea su propia
-- organización y queda como "dueño". SECURITY DEFINER para poder escribir en
-- organizaciones/miembros saltándose RLS durante el registro.
CREATE OR REPLACE FUNCTION skf_provisionar_org()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE nueva UUID;
BEGIN
  INSERT INTO organizaciones (nombre, creado_por)
    VALUES (COALESCE(NULLIF(split_part(NEW.email, '@', 1), ''), 'Mi empresa'), NEW.id)
    RETURNING id INTO nueva;
  INSERT INTO miembros (org_id, user_id, rol) VALUES (nueva, NEW.id, 'dueno');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_skf_provisionar_org ON auth.users;
CREATE TRIGGER trg_skf_provisionar_org
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION skf_provisionar_org();

-- Red de seguridad idempotente: el cliente la llama al iniciar sesión. Si el
-- usuario ya tiene organización, la devuelve; si no (p. ej. cuenta creada antes
-- de existir el trigger), la crea. SECURITY DEFINER para sortear el problema
-- del huevo y la gallina: la policy de "miembros" solo deja insertar a un
-- admin, pero el primer miembro aún no existe.
CREATE OR REPLACE FUNCTION skf_asegurar_org()
RETURNS UUID SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE oid UUID; uid UUID := (select auth.uid()); mail TEXT;
BEGIN
  IF uid IS NULL THEN RETURN NULL; END IF;
  SELECT org_id INTO oid FROM miembros WHERE user_id = uid ORDER BY creado_en LIMIT 1;
  IF oid IS NOT NULL THEN RETURN oid; END IF;
  SELECT email INTO mail FROM auth.users WHERE id = uid;
  INSERT INTO organizaciones (nombre, creado_por)
    VALUES (COALESCE(NULLIF(split_part(mail, '@', 1), ''), 'Mi empresa'), uid) RETURNING id INTO oid;
  INSERT INTO miembros (org_id, user_id, rol) VALUES (oid, uid, 'dueno');
  RETURN oid;
END;
$$;
GRANT EXECUTE ON FUNCTION skf_asegurar_org() TO authenticated;

-- ── 5 · Unidades (sede / área / contratista) — la dimensión de reporte ───────
-- Reemplaza la antigua "ubicaciones". padre_id permite jerarquía (Centro
-- Comercial > Torre A > Piso 3). tipo distingue el eje por el que se agrupa.
CREATE TABLE unidades (
  id        TEXT PRIMARY KEY,
  org_id    UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  nombre    TEXT NOT NULL,
  tipo      TEXT NOT NULL DEFAULT 'sede'
            CHECK (tipo IN ('sede','area','contratista','otro')),
  padre_id  TEXT REFERENCES unidades(id) ON DELETE SET NULL,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE unidades ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Miembros ven unidades"   ON unidades FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean unidades" ON unidades FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan unidades"ON unidades FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran unidades"ON unidades FOR DELETE USING (skf_puede_escribir(org_id));
CREATE INDEX unidades_org_idx   ON unidades (org_id, tipo);
CREATE INDEX unidades_padre_idx ON unidades (padre_id);

-- ── 6 · Plantillas (formularios) ─────────────────────────────────────────────
CREATE TABLE plantillas (
  id                  TEXT PRIMARY KEY,
  org_id              UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  autor_id            UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- auditoría
  nombre              TEXT NOT NULL,
  campos              JSONB NOT NULL DEFAULT '[]',
  codigo              TEXT,
  descripcion         TEXT,
  logo                TEXT,
  favorito            BOOLEAN NOT NULL DEFAULT false,
  publica             BOOLEAN NOT NULL DEFAULT false,
  share_token         TEXT,
  correo_notificacion TEXT,
  norma               TEXT,
  creado_en           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE plantillas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Miembros ven plantillas"    ON plantillas FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean plantillas"  ON plantillas FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan plantillas" ON plantillas FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran plantillas" ON plantillas FOR DELETE USING (skf_puede_escribir(org_id));

-- Visitante anónimo (link/QR público): ve solo plantillas marcadas públicas.
CREATE POLICY "Anónimos ven plantillas públicas"
  ON plantillas FOR SELECT TO anon USING (publica = true);

-- Seguridad a nivel de columna: aunque el cliente pida select=*, un anónimo
-- nunca recibe org_id, autor_id ni correo_notificacion (datos privados del
-- dueño). PostgREST respeta los privilegios de columna automáticamente.
REVOKE SELECT ON plantillas FROM anon;
GRANT  SELECT (id, nombre, campos, codigo, descripcion, logo, publica, share_token, norma) ON plantillas TO anon;

CREATE INDEX plantillas_org_idx ON plantillas (org_id, actualizado_en DESC);
CREATE UNIQUE INDEX plantillas_share_token_idx ON plantillas (share_token) WHERE share_token IS NOT NULL;

-- ── 7 · Envíos (formularios diligenciados) ───────────────────────────────────
CREATE TABLE envios (
  id               TEXT PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  plantilla_id     TEXT REFERENCES plantillas(id) ON DELETE SET NULL,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  plantilla_codigo TEXT NOT NULL DEFAULT '',
  unidad_id        TEXT REFERENCES unidades(id) ON DELETE SET NULL,   -- dimensión
  autor_id         UUID REFERENCES auth.users(id) ON DELETE SET NULL, -- quién lo llenó (si tiene sesión)
  datos            JSONB NOT NULL DEFAULT '{}',
  estado           TEXT NOT NULL DEFAULT 'enviado' CHECK (estado IN ('borrador','enviado')),
  numero           INTEGER,
  llenado_por      TEXT,   -- nombre libre del visitante anónimo (link público)
  llenado_correo   TEXT,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  enviado_en       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE envios ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Miembros ven envíos"    ON envios FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean envíos"  ON envios FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan envíos" ON envios FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran envíos" ON envios FOR DELETE USING (skf_puede_escribir(org_id));

-- Visitante anónimo puede enviar, pero solo a una plantilla pública. El org_id
-- lo fuerza el trigger de abajo desde la plantilla — no se confía en el cliente.
CREATE POLICY "Anónimos envían a plantillas públicas"
  ON envios FOR INSERT TO anon
  WITH CHECK (plantilla_id IN (SELECT id FROM plantillas WHERE publica = true));

CREATE INDEX envios_org_date_idx ON envios (org_id, enviado_en DESC);
CREATE INDEX envios_plantilla_idx ON envios (plantilla_id);
CREATE INDEX envios_codigo_idx    ON envios (org_id, plantilla_codigo);
CREATE INDEX envios_unidad_idx    ON envios (unidad_id);

-- Atribuye cada envío a la organización dueña de la plantilla (nunca al valor
-- que mande el cliente). Hereda la unidad por defecto de la plantilla si el
-- envío no trae una. Un anónimo no puede leer envíos previos → el número y las
-- fechas se fijan en el servidor.
CREATE OR REPLACE FUNCTION envios_asignar_org()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE dueno UUID;
BEGIN
  SELECT org_id INTO dueno FROM plantillas WHERE id = NEW.plantilla_id;
  IF dueno IS NULL THEN RAISE EXCEPTION 'plantilla_id inválido o sin organización'; END IF;
  NEW.org_id := dueno;
  IF (select auth.role()) = 'anon' THEN
    NEW.creado_en := NOW();
    NEW.enviado_en := NOW();
    NEW.autor_id := NULL;
  END IF;
  IF NEW.numero IS NULL THEN
    SELECT COALESCE(MAX(numero),0)+1 INTO NEW.numero FROM envios WHERE plantilla_id = NEW.plantilla_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_envios_asignar_org ON envios;
CREATE TRIGGER trg_envios_asignar_org
  BEFORE INSERT ON envios FOR EACH ROW EXECUTE FUNCTION envios_asignar_org();

-- ── 8 · Asignaciones (a quién se le pidió llenar qué) ────────────────────────
CREATE TABLE asignaciones (
  id               TEXT PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  plantilla_id     TEXT NOT NULL REFERENCES plantillas(id) ON DELETE CASCADE,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  unidad_id        TEXT REFERENCES unidades(id) ON DELETE SET NULL,
  nombre           TEXT NOT NULL,
  correo           TEXT,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE asignaciones ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Miembros ven asignaciones"    ON asignaciones FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean asignaciones"  ON asignaciones FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan asignaciones" ON asignaciones FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran asignaciones" ON asignaciones FOR DELETE USING (skf_puede_escribir(org_id));
CREATE INDEX asignaciones_org_idx       ON asignaciones (org_id, creado_en DESC);
CREATE INDEX asignaciones_plantilla_idx ON asignaciones (plantilla_id);
CREATE INDEX asignaciones_unidad_idx    ON asignaciones (unidad_id);

-- ── 9 · Hallazgos (no conformidades) ─────────────────────────────────────────
CREATE TABLE hallazgos (
  id               TEXT PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  envio_id         TEXT REFERENCES envios(id) ON DELETE SET NULL,
  plantilla_id     TEXT REFERENCES plantillas(id) ON DELETE SET NULL,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  campo_id         TEXT,
  campo_etiqueta   TEXT,
  origen           TEXT NOT NULL DEFAULT 'manual'  CHECK (origen IN ('automatico','manual')),
  severidad        TEXT NOT NULL DEFAULT 'menor'   CHECK (severidad IN ('critico','mayor','menor')),
  descripcion      TEXT,
  foto             TEXT,
  unidad_id        TEXT REFERENCES unidades(id) ON DELETE SET NULL,
  estado           TEXT NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','en_proceso','cerrado')),
  reportado_por    TEXT,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE hallazgos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Miembros ven hallazgos"    ON hallazgos FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean hallazgos"  ON hallazgos FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan hallazgos" ON hallazgos FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran hallazgos" ON hallazgos FOR DELETE USING (skf_puede_escribir(org_id));

CREATE POLICY "Anónimos reportan hallazgos en plantillas públicas"
  ON hallazgos FOR INSERT TO anon
  WITH CHECK (plantilla_id IN (SELECT id FROM plantillas WHERE publica = true));

CREATE INDEX hallazgos_org_idx       ON hallazgos (org_id, creado_en DESC);
CREATE INDEX hallazgos_envio_idx     ON hallazgos (envio_id);
CREATE INDEX hallazgos_estado_idx    ON hallazgos (org_id, estado);
CREATE INDEX hallazgos_severidad_idx ON hallazgos (org_id, severidad);
CREATE INDEX hallazgos_unidad_idx    ON hallazgos (unidad_id);

CREATE OR REPLACE FUNCTION hallazgos_asignar_org()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE dueno UUID;
BEGIN
  SELECT org_id INTO dueno FROM plantillas WHERE id = NEW.plantilla_id;
  IF dueno IS NULL THEN RAISE EXCEPTION 'plantilla_id inválido o sin organización'; END IF;
  NEW.org_id := dueno;
  IF (select auth.role()) = 'anon' THEN
    NEW.creado_en := NOW();
    NEW.actualizado_en := NOW();
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_hallazgos_asignar_org ON hallazgos;
CREATE TRIGGER trg_hallazgos_asignar_org
  BEFORE INSERT ON hallazgos FOR EACH ROW EXECUTE FUNCTION hallazgos_asignar_org();

-- ── 10 · Acciones correctivas (CAPA) ─────────────────────────────────────────
CREATE TABLE acciones_correctivas (
  id               TEXT PRIMARY KEY,
  org_id           UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  hallazgo_id      TEXT NOT NULL REFERENCES hallazgos(id) ON DELETE CASCADE,
  responsable      TEXT,
  correo           TEXT,
  fecha_limite     DATE,
  estado           TEXT NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','completada','vencida')),
  evidencia_cierre TEXT,
  cerrado_en       TIMESTAMPTZ,
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE acciones_correctivas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Miembros ven CAPA"    ON acciones_correctivas FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean CAPA"  ON acciones_correctivas FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan CAPA" ON acciones_correctivas FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran CAPA" ON acciones_correctivas FOR DELETE USING (skf_puede_escribir(org_id));
CREATE INDEX capa_hallazgo_idx ON acciones_correctivas (hallazgo_id);
CREATE INDEX capa_org_estado_idx ON acciones_correctivas (org_id, estado, fecha_limite);

-- ── 11 · Inspecciones programadas (recurrencia) — base para fase 3 ───────────
-- Diseñada ahora para que la recurrencia NO sea un parche después. La UI de
-- calendario/recordatorios se cablea en una fase posterior; la estructura ya
-- queda lista y consistente con el resto del modelo.
CREATE TABLE inspecciones_programadas (
  id                TEXT PRIMARY KEY,
  org_id            UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  plantilla_id      TEXT REFERENCES plantillas(id) ON DELETE SET NULL,
  unidad_id         TEXT REFERENCES unidades(id) ON DELETE SET NULL,
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
ALTER TABLE inspecciones_programadas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Miembros ven programadas"    ON inspecciones_programadas FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean programadas"  ON inspecciones_programadas FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores editan programadas" ON inspecciones_programadas FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran programadas" ON inspecciones_programadas FOR DELETE USING (skf_puede_escribir(org_id));
CREATE INDEX programadas_org_idx ON inspecciones_programadas (org_id, activa, proximo_en);

-- ── 12 · Notificaciones por correo (Resend vía pg_net + Vault) ───────────────
-- Igual que antes: al completar un formulario o reportar un hallazgo crítico se
-- envía correo si la plantilla tiene correo_notificacion. La API key se guarda
-- una sola vez en Vault (no en el repo):
--   SELECT vault.create_secret('tu_api_key', 'resend_api_key');
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS supabase_vault;

CREATE OR REPLACE FUNCTION skf_html_escape(txt TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(replace(replace(
    COALESCE(txt, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

CREATE OR REPLACE FUNCTION envios_notificar_completado()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  correo TEXT; nombre_plantilla TEXT; campos JSONB; api_key TEXT;
  resumen TEXT := ''; campo RECORD; etiqueta TEXT; valor TEXT;
BEGIN
  SELECT correo_notificacion, nombre, p.campos INTO correo, nombre_plantilla, campos
    FROM plantillas p WHERE p.id = NEW.plantilla_id;
  IF correo IS NULL OR correo = '' THEN RETURN NEW; END IF;
  SELECT decrypted_secret INTO api_key FROM vault.decrypted_secrets WHERE name = 'resend_api_key' LIMIT 1;
  IF api_key IS NULL OR api_key = '' THEN RETURN NEW; END IF;
  FOR campo IN SELECT * FROM jsonb_array_elements(COALESCE(campos, '[]'::jsonb)) LOOP
    etiqueta := COALESCE(campo.value->>'etiqueta', campo.value->>'id', '');
    valor := NEW.datos->>(campo.value->>'id');
    IF valor IS NOT NULL AND valor != '' THEN
      IF length(valor) > 200 OR valor LIKE 'data:%' THEN valor := '[contenido adjunto]'; END IF;
      resumen := resumen || '<p><strong>' || skf_html_escape(etiqueta) || ':</strong> ' || skf_html_escape(valor) || '</p>';
    END IF;
  END LOOP;
  PERFORM net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'SEKaform <onboarding@resend.dev>', 'to', ARRAY[correo],
      'subject', 'Formulario completado: ' || COALESCE(nombre_plantilla, ''),
      'html', '<h2>Formulario completado</h2><p><strong>' || skf_html_escape(nombre_plantilla) ||
              '</strong> fue enviado el ' || to_char(NEW.enviado_en, 'DD/MM/YYYY HH24:MI') || '.</p>' || resumen)
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_envios_notificar_completado ON envios;
CREATE TRIGGER trg_envios_notificar_completado
  AFTER INSERT ON envios FOR EACH ROW EXECUTE FUNCTION envios_notificar_completado();

CREATE OR REPLACE FUNCTION hallazgos_notificar_critico()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE correo TEXT; nombre_plantilla TEXT; api_key TEXT;
BEGIN
  IF NEW.severidad != 'critico' THEN RETURN NEW; END IF;
  SELECT correo_notificacion, nombre INTO correo, nombre_plantilla FROM plantillas WHERE id = NEW.plantilla_id;
  IF correo IS NULL OR correo = '' THEN RETURN NEW; END IF;
  SELECT decrypted_secret INTO api_key FROM vault.decrypted_secrets WHERE name = 'resend_api_key' LIMIT 1;
  IF api_key IS NULL OR api_key = '' THEN RETURN NEW; END IF;
  PERFORM net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || api_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'SEKaform <onboarding@resend.dev>', 'to', ARRAY[correo],
      'subject', '🔴 Hallazgo crítico: ' || COALESCE(nombre_plantilla, ''),
      'html', '<h2>Hallazgo crítico reportado</h2>' ||
              '<p><strong>Formulario:</strong> ' || skf_html_escape(COALESCE(nombre_plantilla, '')) || '</p>' ||
              '<p><strong>Campo:</strong> ' || skf_html_escape(COALESCE(NEW.campo_etiqueta, '')) || '</p>' ||
              '<p><strong>Descripción:</strong> ' || skf_html_escape(COALESCE(NEW.descripcion, '')) || '</p>' ||
              '<p><strong>Reportado por:</strong> ' || skf_html_escape(COALESCE(NEW.reportado_por, '')) || '</p>')
  );
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_hallazgos_notificar_critico ON hallazgos;
CREATE TRIGGER trg_hallazgos_notificar_critico
  AFTER INSERT ON hallazgos FOR EACH ROW EXECUTE FUNCTION hallazgos_notificar_critico();

-- ── 13 · Realtime (aviso instantáneo de hallazgo crítico en la app) ──────────
-- El cliente se suscribe filtrando por org_id (ver skfSubscribeCriticalAlerts).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'hallazgos') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE hallazgos;
  END IF;
END $$;

-- ── 14 · Migración incremental (norma opcional + país) ───────────────────────
-- Seguro re-ejecutar. Si ya corriste el esquema antes, ESTO es lo único nuevo
-- que necesitas correr para habilitar la norma por plantilla y el país por
-- organización:
ALTER TABLE plantillas     ADD COLUMN IF NOT EXISTS norma TEXT;
ALTER TABLE organizaciones ADD COLUMN IF NOT EXISTS pais  TEXT;
GRANT SELECT (id, nombre, campos, codigo, descripcion, logo, publica, share_token, norma) ON plantillas TO anon;

-- ── 15 · Paneles compartidos de solo lectura (dashboard sin cuenta) ──────────
-- Permite entregar el dashboard a un cliente/jefe SIN cuenta, con un link no
-- listado (dashboard.html?panel=<token>). Se publica una FOTO inmutable de los
-- datos ya filtrados (snapshot), no acceso en vivo: el visitante anónimo nunca
-- toca las tablas reales (envios/hallazgos/…), solo lee el snapshot que el dueño
-- decidió publicar. La lectura anónima va por una función SECURITY DEFINER que
-- devuelve UNA sola fila por su token exacto — no se puede enumerar la tabla.
-- Seguro re-ejecutar.
CREATE TABLE IF NOT EXISTS paneles_publicos (
  token      TEXT PRIMARY KEY,
  org_id     UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  titulo     TEXT,
  snapshot   JSONB NOT NULL,
  creado_en  TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS paneles_publicos_org_idx ON paneles_publicos (org_id, creado_en DESC);
ALTER TABLE paneles_publicos ENABLE ROW LEVEL SECURITY;

-- Solo los miembros de la org ven/crean/borran sus propios paneles. El anónimo
-- NO tiene acceso directo a la tabla (sin GRANT a anon): entra por la función.
DROP POLICY IF EXISTS "Miembros ven paneles"   ON paneles_publicos;
DROP POLICY IF EXISTS "Editores crean paneles" ON paneles_publicos;
DROP POLICY IF EXISTS "Editores borran paneles" ON paneles_publicos;
CREATE POLICY "Miembros ven paneles"    ON paneles_publicos FOR SELECT USING (skf_es_miembro(org_id));
CREATE POLICY "Editores crean paneles"  ON paneles_publicos FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY "Editores borran paneles" ON paneles_publicos FOR DELETE USING (skf_puede_escribir(org_id));
GRANT SELECT, INSERT, DELETE ON paneles_publicos TO authenticated;

-- Lectura pública por token exacto (no enumera): devuelve solo el snapshot.
CREATE OR REPLACE FUNCTION skf_panel_publico(p_token TEXT)
RETURNS JSONB SECURITY DEFINER SET search_path = public LANGUAGE sql AS $$
  SELECT snapshot FROM paneles_publicos WHERE token = p_token LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION skf_panel_publico(TEXT) TO anon, authenticated;

-- ── 16 · Cierre del ciclo: el campo REPORTA corregido desde el link ──────────
-- Desde el link operativo (?panel=<token>&modo=operativo) el ejecutante marca un
-- señalamiento como corregido. Es un REPORTE, no un cierre: el dueño lo ve en su
-- panel y confirma. El anónimo nunca escribe directo en hallazgos; va por una
-- función que valida que el token existe y que el hallazgo pertenece a la MISMA
-- organización de ese panel (no puede tocar hallazgos de otra org ni inventar).
-- Seguro re-ejecutar.
CREATE TABLE IF NOT EXISTS correcciones_campo (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token        TEXT NOT NULL REFERENCES paneles_publicos(token) ON DELETE CASCADE,
  org_id       UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
  hallazgo_id  TEXT NOT NULL REFERENCES hallazgos(id) ON DELETE CASCADE,
  marcado_por  TEXT,
  nota         TEXT,
  marcado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS correcciones_campo_org_idx ON correcciones_campo (org_id, marcado_en DESC);
CREATE UNIQUE INDEX IF NOT EXISTS correcciones_campo_uni ON correcciones_campo (token, hallazgo_id);
ALTER TABLE correcciones_campo ENABLE ROW LEVEL SECURITY;
-- El dueño (miembro) ve las marcas de su org. Nadie escribe directo: va por RPC.
DROP POLICY IF EXISTS "Miembros ven correcciones campo" ON correcciones_campo;
CREATE POLICY "Miembros ven correcciones campo" ON correcciones_campo FOR SELECT USING (skf_es_miembro(org_id));
GRANT SELECT ON correcciones_campo TO authenticated;

-- Marcar corregido (anónimo, validado por token + org del hallazgo).
CREATE OR REPLACE FUNCTION skf_panel_marcar_corregido(p_token TEXT, p_hallazgo_id TEXT, p_por TEXT, p_nota TEXT)
RETURNS BOOLEAN SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_org UUID; v_hz_org UUID;
BEGIN
  SELECT org_id INTO v_org FROM paneles_publicos WHERE token = p_token;
  IF v_org IS NULL THEN RETURN false; END IF;
  SELECT org_id INTO v_hz_org FROM hallazgos WHERE id = p_hallazgo_id;
  IF v_hz_org IS NULL OR v_hz_org <> v_org THEN RETURN false; END IF;
  INSERT INTO correcciones_campo (token, org_id, hallazgo_id, marcado_por, nota)
    VALUES (p_token, v_org, p_hallazgo_id, NULLIF(p_por,''), NULLIF(p_nota,''))
    ON CONFLICT (token, hallazgo_id)
    DO UPDATE SET marcado_por = EXCLUDED.marcado_por, nota = EXCLUDED.nota, marcado_en = now();
  RETURN true;
END; $$;
GRANT EXECUTE ON FUNCTION skf_panel_marcar_corregido(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

-- Deshacer la marca (anónimo, mismo token).
CREATE OR REPLACE FUNCTION skf_panel_desmarcar_corregido(p_token TEXT, p_hallazgo_id TEXT)
RETURNS BOOLEAN SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_org UUID;
BEGIN
  SELECT org_id INTO v_org FROM paneles_publicos WHERE token = p_token;
  IF v_org IS NULL THEN RETURN false; END IF;
  DELETE FROM correcciones_campo WHERE token = p_token AND hallazgo_id = p_hallazgo_id;
  RETURN true;
END; $$;
GRANT EXECUTE ON FUNCTION skf_panel_desmarcar_corregido(TEXT, TEXT) TO anon, authenticated;

-- Marcas ya hechas para un token (para que el link muestre lo ya reportado).
CREATE OR REPLACE FUNCTION skf_panel_marcas(p_token TEXT)
RETURNS JSONB SECURITY DEFINER SET search_path = public LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'hallazgo_id', hallazgo_id, 'marcado_por', marcado_por,
           'nota', nota, 'marcado_en', marcado_en)), '[]'::jsonb)
  FROM correcciones_campo WHERE token = p_token;
$$;
GRANT EXECUTE ON FUNCTION skf_panel_marcas(TEXT) TO anon, authenticated;

-- ── 17 · Auditoría de cierre (quién y cuándo cerró un hallazgo) ──────────────
-- Guarda quién cerró cada hallazgo desde el panel y cuándo. Seguro re-ejecutar.
ALTER TABLE hallazgos ADD COLUMN IF NOT EXISTS cerrado_en  TIMESTAMPTZ;
ALTER TABLE hallazgos ADD COLUMN IF NOT EXISTS cerrado_por TEXT;

-- ── 18 · Recordatorio automático de correcciones vencidas ───────────────────
-- Una vez al día, a quien tenga una acción correctiva VENCIDA (pasó su fecha
-- límite y el hallazgo sigue abierto) le llega un correo con su lista. Reusa el
-- mismo Resend + vault del resto de avisos: si no hay 'resend_api_key' cargada,
-- no hace nada. Requiere la extensión pg_cron habilitada para agendarse solo.
CREATE OR REPLACE FUNCTION skf_recordar_vencidos()
RETURNS void SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE api_key TEXT; rec RECORD;
BEGIN
  SELECT decrypted_secret INTO api_key FROM vault.decrypted_secrets WHERE name = 'resend_api_key' LIMIT 1;
  IF api_key IS NULL OR api_key = '' THEN RETURN; END IF;
  FOR rec IN
    SELECT ac.correo AS correo, count(*) AS n,
           string_agg('<li><strong>' || skf_html_escape(COALESCE(h.plantilla_nombre,'')) || '</strong> — ' ||
             skf_html_escape(COALESCE(h.campo_etiqueta, h.descripcion, 'hallazgo')) ||
             ' (venció el ' || to_char(ac.fecha_limite,'DD/MM/YYYY') || ')</li>', '') AS items
    FROM acciones_correctivas ac
    JOIN hallazgos h ON h.id = ac.hallazgo_id
    WHERE ac.estado <> 'completada'
      AND ac.fecha_limite IS NOT NULL AND ac.fecha_limite < current_date
      AND h.estado <> 'cerrado'
      AND ac.correo IS NOT NULL AND ac.correo <> ''
    GROUP BY ac.correo
  LOOP
    PERFORM net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object('Authorization','Bearer '||api_key,'Content-Type','application/json'),
      body := jsonb_build_object(
        'from','SEKaform <onboarding@resend.dev>','to',ARRAY[rec.correo],
        'subject','⏰ Tienes '||rec.n||' corrección(es) vencida(s)',
        'html','<h2>Correcciones vencidas</h2><p>Estas acciones ya pasaron su fecha límite y siguen abiertas:</p><ul>'||rec.items||'</ul><p>Ingresa a SEKaform para atenderlas y cerrarlas.</p>'));
  END LOOP;
  -- deja el estado 'vencida' para que la app lo muestre igual
  UPDATE acciones_correctivas ac SET estado = 'vencida'
   FROM hallazgos h
   WHERE ac.hallazgo_id = h.id AND ac.estado = 'pendiente'
     AND ac.fecha_limite IS NOT NULL AND ac.fecha_limite < current_date AND h.estado <> 'cerrado';
END; $$;

-- Se agenda solo si pg_cron está habilitado (Dashboard → Database → Extensions).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'skf-recordar-vencidos') THEN
      PERFORM cron.unschedule('skf-recordar-vencidos');
    END IF;
    PERFORM cron.schedule('skf-recordar-vencidos', '0 13 * * *', 'SELECT skf_recordar_vencidos();');
  ELSE
    RAISE NOTICE 'pg_cron no está habilitado: actívalo en Dashboard → Database → Extensions y re-ejecuta este bloque para el recordatorio diario.';
  END IF;
END $$;

-- ── 19 · Vista aplanada para Power BI / Looker (conexión en vivo) ────────────
-- Una fila por respuesta (formato largo), lista para graficar sin despivotar —
-- la misma forma que exporta el botón «Datos para Power BI». security_invoker
-- ON hace que la vista respete la RLS de quien la consulta: cada usuario ve solo
-- los datos de su organización. Excluye campos de estructura/binarios. Seguro
-- re-ejecutar.
CREATE OR REPLACE VIEW vista_respuestas
WITH (security_invoker = on) AS
SELECT
  e.org_id,
  e.id                                  AS envio_id,
  e.numero,
  e.plantilla_nombre                    AS formulario,
  e.plantilla_codigo                    AS codigo,
  COALESCE(e.enviado_en, e.creado_en)   AS fecha,
  u.nombre                              AS unidad,
  e.llenado_por,
  campo->>'etiqueta'                    AS campo,
  campo->>'tipo'                        AS tipo,
  e.datos->>(campo->>'id')              AS valor,
  CASE WHEN replace(e.datos->>(campo->>'id'), ',', '.') ~ '^-?\d+(\.\d+)?$'
       THEN replace(e.datos->>(campo->>'id'), ',', '.')::numeric END AS valor_numerico
FROM envios e
JOIN plantillas p ON p.id = e.plantilla_id
LEFT JOIN unidades u ON u.id = e.unidad_id
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(p.campos, '[]'::jsonb)) AS campo
WHERE (campo->>'tipo') NOT IN ('separador','firma','foto')
  AND COALESCE(e.datos->>(campo->>'id'), '') <> '';
GRANT SELECT ON vista_respuestas TO authenticated;
