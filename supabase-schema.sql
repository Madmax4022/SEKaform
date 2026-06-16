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
  plantilla_id     TEXT REFERENCES plantillas(id) ON DELETE SET NULL,
  plantilla_nombre TEXT NOT NULL DEFAULT '',
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
