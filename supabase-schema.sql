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
  creado_en     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE plantillas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuarios ven sus propias plantillas"
  ON plantillas FOR ALL
  USING (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS plantillas_user_idx ON plantillas (user_id, actualizado_en DESC);

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

CREATE INDEX IF NOT EXISTS envios_user_date_idx ON envios (user_id, enviado_en DESC);
CREATE INDEX IF NOT EXISTS envios_plantilla_idx ON envios (plantilla_id);
CREATE INDEX IF NOT EXISTS envios_codigo_idx ON envios (user_id, plantilla_codigo);

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
