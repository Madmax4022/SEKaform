-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — paneles compartidos y cierre del ciclo
--
--  Trae al backend propio tres cosas que se construyeron sobre Supabase
--  mientras esta rama vivía aparte:
--
--    · paneles_publicos    → entregar el panel a un cliente o a un jefe SIN
--                            cuenta, por un enlace no listado.
--    · correcciones_campo  → que quien ejecuta la corrección la REPORTE desde
--                            ese mismo enlace, y el dueño la vea y confirme.
--    · cerrado_por         → rastro de quién cerró cada hallazgo.
--
--  El anónimo NUNCA toca las tablas reales. En Supabase eso lo resolvían las
--  policies del rol `anon`; aquí, igual que en 004_publico.sql, se hace con
--  funciones SECURITY DEFINER acotadas a una sola cosa cada una, y la
--  organización se deriva SIEMPRE del token, nunca del cuerpo de la petición.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- ── 1 · Paneles compartidos de solo lectura ─────────────────────────────────
-- Se publica una FOTO inmutable de los datos ya filtrados (snapshot), no acceso
-- en vivo. Es deliberado: el visitante ve exactamente lo que el dueño decidió
-- enseñarle, y un enlace filtrado no se convierte en una ventana permanente a
-- la operación. Para actualizar, se vuelve a compartir.
CREATE TABLE IF NOT EXISTS paneles_publicos (
  token          TEXT PRIMARY KEY,
  org_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  titulo         TEXT,
  snapshot       JSONB NOT NULL,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actualizado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS paneles_org_idx ON paneles_publicos (org_id, creado_en DESC);

-- ── 2 · Correcciones reportadas desde el enlace operativo ───────────────────
-- Es un REPORTE, no un cierre: el dueño lo ve en su panel y confirma. Por eso
-- vive en su propia tabla y no toca `hallazgos.estado` — quien ejecuta no
-- decide el estado del hallazgo, solo avisa de que ya lo atendió.
CREATE TABLE IF NOT EXISTS correcciones_campo (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token        TEXT NOT NULL REFERENCES paneles_publicos(token) ON DELETE CASCADE,
  org_id       UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  hallazgo_id  UUID NOT NULL REFERENCES hallazgos(id) ON DELETE CASCADE,
  marcado_por  TEXT,
  nota         TEXT,
  marcado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS correcciones_org_idx ON correcciones_campo (org_id, marcado_en DESC);
-- Reabrir el enlace y volver a marcar no debe duplicar: se actualiza la marca.
CREATE UNIQUE INDEX IF NOT EXISTS correcciones_uni ON correcciones_campo (token, hallazgo_id);

-- ── 3 · Rastro de cierre ────────────────────────────────────────────────────
-- `cerrado_en` ya existía en 001_core.sql; faltaba QUIÉN. Sin el nombre, la
-- bitácora no responde la pregunta que se le hace en una auditoría.
ALTER TABLE hallazgos ADD COLUMN IF NOT EXISTS cerrado_por TEXT;

-- ── 4 · RLS ─────────────────────────────────────────────────────────────────
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['paneles_publicos','correcciones_campo'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    -- NO FORCE, igual que el resto: deja que las funciones SECURITY DEFINER
    -- (propiedad de skf_owner) escriban por el anónimo sin saltarse nada más.
    EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Paneles: los ve su gente, los publica y los revoca quien puede escribir.
-- Revocar un enlace compartido es un acto editorial, no administrativo: quien
-- lo publicó tiene que poder cortarlo sin pedir permiso a un admin.
DROP POLICY IF EXISTS paneles_sel ON paneles_publicos;
DROP POLICY IF EXISTS paneles_ins ON paneles_publicos;
DROP POLICY IF EXISTS paneles_upd ON paneles_publicos;
DROP POLICY IF EXISTS paneles_del ON paneles_publicos;
CREATE POLICY paneles_sel ON paneles_publicos FOR SELECT USING (skf_puede_leer(org_id));
CREATE POLICY paneles_ins ON paneles_publicos FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY paneles_upd ON paneles_publicos FOR UPDATE USING (skf_puede_escribir(org_id));
CREATE POLICY paneles_del ON paneles_publicos FOR DELETE USING (skf_puede_escribir(org_id));

-- Correcciones: el dueño las LEE. Nadie las escribe por la vía normal — entran
-- solo por las funciones de abajo, que validan el token.
DROP POLICY IF EXISTS correcciones_sel ON correcciones_campo;
CREATE POLICY correcciones_sel ON correcciones_campo FOR SELECT USING (skf_puede_leer(org_id));

-- ── 5 · Acceso anónimo por token (SECURITY DEFINER) ─────────────────────────

-- Lectura del panel por su token exacto. Devuelve UNA fila y solo el snapshot:
-- no se puede enumerar la tabla ni averiguar de qué organización es.
CREATE OR REPLACE FUNCTION skf_panel_publico(p_token TEXT)
RETURNS JSONB
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT snapshot FROM paneles_publicos WHERE token = p_token LIMIT 1;
$$;

-- Marcas ya reportadas para un token, para que el enlace muestre lo hecho.
CREATE OR REPLACE FUNCTION skf_panel_marcas(p_token TEXT)
RETURNS JSONB
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'hallazgo_id', hallazgo_id, 'marcado_por', marcado_por,
           'nota', nota, 'marcado_en', marcado_en)), '[]'::jsonb)
    FROM correcciones_campo WHERE token = p_token;
$$;

-- Marcar corregido. Dos comprobaciones, y las dos importan: que el token
-- exista, y que el hallazgo sea de la MISMA organización de ese panel. Sin la
-- segunda, quien tenga cualquier enlace válido podría marcar hallazgos de otro
-- cliente pasando ids a mano.
CREATE OR REPLACE FUNCTION skf_panel_marcar_corregido(
  p_token TEXT, p_hallazgo_id UUID, p_por TEXT, p_nota TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org UUID; v_hz_org UUID;
BEGIN
  SELECT org_id INTO v_org FROM paneles_publicos WHERE token = p_token;
  IF v_org IS NULL THEN RETURN false; END IF;

  SELECT org_id INTO v_hz_org FROM hallazgos WHERE id = p_hallazgo_id;
  IF v_hz_org IS NULL OR v_hz_org <> v_org THEN RETURN false; END IF;

  INSERT INTO correcciones_campo (token, org_id, hallazgo_id, marcado_por, nota)
  VALUES (p_token, v_org, p_hallazgo_id, NULLIF(p_por, ''), NULLIF(p_nota, ''))
  ON CONFLICT (token, hallazgo_id) DO UPDATE
    SET marcado_por = EXCLUDED.marcado_por,
        nota        = EXCLUDED.nota,
        marcado_en  = NOW();
  RETURN true;
END $$;

-- Deshacer la marca. Acotado al token: solo se borra lo reportado desde ese
-- mismo enlace, nunca lo que reportó otro.
CREATE OR REPLACE FUNCTION skf_panel_desmarcar_corregido(
  p_token TEXT, p_hallazgo_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_org UUID;
BEGIN
  SELECT org_id INTO v_org FROM paneles_publicos WHERE token = p_token;
  IF v_org IS NULL THEN RETURN false; END IF;
  DELETE FROM correcciones_campo WHERE token = p_token AND hallazgo_id = p_hallazgo_id;
  RETURN true;
END $$;

GRANT EXECUTE ON FUNCTION skf_panel_publico(TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_panel_marcas(TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_panel_marcar_corregido(TEXT, UUID, TEXT, TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_panel_desmarcar_corregido(TEXT, UUID) TO skf_app;

-- ── 6 · Vista aplanada para Power BI / Looker ───────────────────────────────
-- Una fila por respuesta (formato largo), lista para graficar sin despivotar:
-- la misma forma que exporta el botón «Datos para Power BI». security_invoker
-- hace que la vista respete la RLS de quien la consulta, así que cada quien ve
-- solo lo de su organización.
--
-- OJO: aquí no existe el rol `authenticated` de Supabase, y la app se conecta
-- con skf_app. Para conectar Power BI EN VIVO hace falta un rol de solo lectura
-- aparte (con su propio contexto app.user_id/app.org_id); mientras no exista,
-- esta vista la consume quien entre con psql, no la herramienta de BI.
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

GRANT SELECT ON vista_respuestas TO skf_app;
