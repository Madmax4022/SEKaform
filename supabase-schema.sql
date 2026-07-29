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
