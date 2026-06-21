-- SEKaform — Supabase Schema
-- Run this in your Supabase project's SQL editor:
-- https://supabase.com/dashboard/project/_/sql/new

-- ── Plantillas (form templates) ──────────────────────────────
CREATE TABLE IF NOT EXISTS plantillas (
  id            TEXT PRIMARY KEY,
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nombre        TEXT NOT NULL,
  campos        JSONB NOT NULL DEFAULT '[]',
  codigo        TEXT,
  descripcion   TEXT,
  logo          TEXT,
  favorito      BOOLEAN NOT NULL DEFAULT false,
  publica       BOOLEAN NOT NULL DEFAULT false,
  share_token   TEXT UNIQUE,
  correo_notificacion TEXT,
  creado_en     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE plantillas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuarios ven sus propias plantillas"
  ON plantillas FOR ALL
  USING (auth.uid() = user_id);

-- Permite que cualquier visitante anónimo (sin cuenta) cargue una plantilla
-- marcada como pública por su share_token, para poder llenarla y enviarla
-- vía link/QR/correo/WhatsApp sin necesitar login.
CREATE POLICY "Anónimos ven plantillas públicas"
  ON plantillas FOR SELECT
  TO anon
  USING (publica = true);

CREATE INDEX IF NOT EXISTS plantillas_user_idx ON plantillas (user_id, actualizado_en DESC);
CREATE UNIQUE INDEX IF NOT EXISTS plantillas_share_token_idx ON plantillas (share_token) WHERE share_token IS NOT NULL;

-- ── Envíos (form submissions) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS envios (
  id               TEXT PRIMARY KEY,
  numero           INTEGER,
  plantilla_id     TEXT REFERENCES plantillas(id) ON DELETE SET NULL,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
  plantilla_codigo TEXT NOT NULL DEFAULT '',
  user_id          UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  datos            JSONB NOT NULL DEFAULT '{}',
  estado           TEXT NOT NULL DEFAULT 'enviado' CHECK (estado IN ('borrador','enviado')),
  creado_en        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  enviado_en       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE envios ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuarios ven sus propios envíos"
  ON envios FOR ALL
  USING (auth.uid() = user_id);

-- Permite que un visitante anónimo envíe un formulario, pero solo si
-- apunta a una plantilla marcada como pública. El user_id que llega del
-- cliente NO se usa: el trigger envios_asignar_dueno (más abajo) lo
-- sobrescribe siempre con el dueño real de la plantilla, así que un
-- anónimo no puede inyectar datos en la cuenta de otra persona.
CREATE POLICY "Anónimos envían a plantillas públicas"
  ON envios FOR INSERT
  TO anon
  WITH CHECK (
    plantilla_id IN (SELECT id FROM plantillas WHERE publica = true)
  );

CREATE INDEX IF NOT EXISTS envios_user_date_idx ON envios (user_id, enviado_en DESC);
CREATE INDEX IF NOT EXISTS envios_plantilla_idx ON envios (plantilla_id);
CREATE INDEX IF NOT EXISTS envios_codigo_idx ON envios (user_id, plantilla_codigo);

-- Fuerza que todo envío (incluidos los anónimos vía link/QR público) quede
-- atribuido al dueño real de la plantilla, nunca al valor que mande el
-- cliente. Así los envíos de "otra persona" caen en el mismo dataset del
-- dueño para Power BI, sin que un anónimo pueda falsificar el user_id.
CREATE OR REPLACE FUNCTION envios_asignar_dueno()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
  dueno UUID;
BEGIN
  SELECT user_id INTO dueno FROM plantillas WHERE id = NEW.plantilla_id;
  IF dueno IS NULL THEN
    RAISE EXCEPTION 'plantilla_id inválido o sin dueño';
  END IF;
  NEW.user_id := dueno;
  -- Un visitante anónimo no tiene forma de leer los envíos previos (RLS se
  -- lo impide) para calcular el siguiente número, así que lo asignamos acá.
  IF NEW.numero IS NULL THEN
    SELECT COALESCE(MAX(numero),0)+1 INTO NEW.numero FROM envios WHERE plantilla_id = NEW.plantilla_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_envios_asignar_dueno ON envios;
CREATE TRIGGER trg_envios_asignar_dueno
  BEFORE INSERT ON envios
  FOR EACH ROW
  EXECUTE FUNCTION envios_asignar_dueno();

-- ── Migración para proyectos existentes ────────────────────────
-- Si ya tenías estas tablas creadas antes de logo/favorito/numero,
-- ejecuta también lo siguiente (no afecta instalaciones nuevas):
ALTER TABLE plantillas ADD COLUMN IF NOT EXISTS logo TEXT;
ALTER TABLE plantillas ADD COLUMN IF NOT EXISTS favorito BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE envios ADD COLUMN IF NOT EXISTS numero INTEGER;

-- plantilla_codigo: copia del código de la plantilla al momento del envío
-- (igual que plantilla_nombre, así el dato sobrevive aunque se borre la
-- plantilla). Es la llave que usa el dashboard para agrupar envíos del
-- mismo tipo de formulario en vez del id interno de una plantilla
-- concreta — ver "CÓDIGO DE FORMULARIO" en digitalizador.html.
ALTER TABLE envios ADD COLUMN IF NOT EXISTS plantilla_codigo TEXT NOT NULL DEFAULT '';

-- publica / share_token / correo_notificacion: soporte para enviar un
-- formulario a alguien sin cuenta (vía link, QR, correo o WhatsApp) y que
-- su envío caiga en el mismo dataset del dueño — ver "ENVÍO PÚBLICO" más
-- abajo. No afecta instalaciones nuevas (ya están en el CREATE TABLE).
ALTER TABLE plantillas ADD COLUMN IF NOT EXISTS publica BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE plantillas ADD COLUMN IF NOT EXISTS share_token TEXT;
ALTER TABLE plantillas ADD COLUMN IF NOT EXISTS correo_notificacion TEXT;

-- ── Notificación automática por correo al completar un formulario ──────
-- Cada vez que se inserta un envío, si su plantilla tiene un
-- correo_notificacion configurado, se manda un correo con un resumen de
-- los datos enviados (vía la API HTTP de Resend, usando la extensión
-- pg_net — sin necesitar una Edge Function).
--
-- Paso manual requerido (NO incluido aquí por seguridad — no se debe
-- subir una API key real al repositorio): crea una cuenta en
-- https://resend.com, genera una API key, y en el SQL editor de Supabase
-- ejecuta una sola vez (reemplazando el valor):
--
--   ALTER DATABASE postgres SET app.resend_api_key = 'tu_api_key_aquí';
--
-- Mientras no verifiques un dominio propio en Resend, los correos se
-- envían desde el remitente de pruebas "onboarding@resend.dev" (no
-- requiere verificación, pero Resend puede limitar a quién le puede
-- llegar — revisa su documentación si los correos no llegan).
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION envios_notificar_completado()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
  correo TEXT;
  nombre_plantilla TEXT;
  campos JSONB;
  api_key TEXT;
  resumen TEXT := '';
  campo RECORD;
  etiqueta TEXT;
  valor TEXT;
BEGIN
  SELECT correo_notificacion, nombre, p.campos
    INTO correo, nombre_plantilla, campos
    FROM plantillas p
    WHERE p.id = NEW.plantilla_id;

  IF correo IS NULL OR correo = '' THEN
    RETURN NEW;
  END IF;

  api_key := current_setting('app.resend_api_key', true);
  IF api_key IS NULL OR api_key = '' THEN
    RETURN NEW;
  END IF;

  FOR campo IN SELECT * FROM jsonb_array_elements(COALESCE(campos, '[]'::jsonb))
  LOOP
    etiqueta := COALESCE(campo.value->>'etiqueta', campo.value->>'id', '');
    valor := NEW.datos->>(campo.value->>'id');
    IF valor IS NOT NULL AND valor != '' THEN
      IF length(valor) > 200 OR valor LIKE 'data:%' THEN
        valor := '[contenido adjunto]';
      END IF;
      resumen := resumen || '<p><strong>' || etiqueta || ':</strong> ' || valor || '</p>';
    END IF;
  END LOOP;

  PERFORM net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || api_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'SEKaform <onboarding@resend.dev>',
      'to', ARRAY[correo],
      'subject', 'Formulario completado: ' || COALESCE(nombre_plantilla, ''),
      'html', '<h2>Formulario completado</h2><p><strong>' || COALESCE(nombre_plantilla, '') ||
              '</strong> fue enviado el ' || to_char(NEW.enviado_en, 'DD/MM/YYYY HH24:MI') ||
              '.</p>' || resumen
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_envios_notificar_completado ON envios;
CREATE TRIGGER trg_envios_notificar_completado
  AFTER INSERT ON envios
  FOR EACH ROW
  EXECUTE FUNCTION envios_notificar_completado();
