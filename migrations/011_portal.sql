-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — portal del cliente (resumen en vivo)
--
--  Un enlace sin cuenta, por empresa, que muestra su estado de cumplimiento
--  SIEMPRE AL DÍA: principios, puntaje, hallazgos y últimas inspecciones. A
--  diferencia de los paneles (005), no es una foto ni lleva el detalle: nunca
--  salen respuestas, firmas, fotos ni nombres de personas. Se revoca cuando se
--  quiera, y queda registro de cuántas veces se abrió y cuándo.
--
--  El anónimo nunca toca las tablas: skf_portal_datos (SECURITY DEFINER) deriva
--  la empresa del token y devuelve solo lo que el portal muestra. Las respuestas
--  de cada inspección salen hacia el servidor SOLO para calcular su puntaje; el
--  servidor las descarta antes de responder (app/api: portal_publico).
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS portales (
  token          TEXT PRIMARY KEY CHECK (length(token) >= 32),
  org_id         UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  creado_por     UUID REFERENCES users(id) ON DELETE SET NULL,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revocado_en    TIMESTAMPTZ,
  accesos        INTEGER NOT NULL DEFAULT 0,
  ultimo_acceso  TIMESTAMPTZ
);
-- Un solo portal vigente por empresa: crear otro revoca el anterior.
CREATE UNIQUE INDEX IF NOT EXISTS portales_vigente_uni ON portales (org_id) WHERE revocado_en IS NULL;
ALTER TABLE portales ENABLE ROW LEVEL SECURITY;
ALTER TABLE portales NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS portales_sel ON portales;
CREATE POLICY portales_sel ON portales FOR SELECT USING (skf_puede_leer(org_id));
-- Escribir solo por las funciones de abajo (sin policies de escritura para la app).

-- Portal vigente de la empresa activa (para quien administra).
CREATE OR REPLACE FUNCTION skf_portal_actual()
RETURNS TABLE (token TEXT, creado_en TIMESTAMPTZ, accesos INTEGER, ultimo_acceso TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT p.token, p.creado_en, p.accesos, p.ultimo_acceso FROM portales p
   WHERE p.org_id = skf_org_id() AND p.revocado_en IS NULL AND skf_es_miembro(skf_org_id());
$$;

-- Crear (o regenerar) el portal: solo dueño o administrador. El token lo genera la
-- base (32 bytes aleatorios), nunca el cliente. Regenerar revoca el anterior.
CREATE OR REPLACE FUNCTION skf_portal_crear()
RETURNS TABLE (resultado TEXT, token TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); t TEXT;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN RETURN QUERY SELECT 'sin_permiso'::TEXT, NULL::TEXT; RETURN; END IF;
  UPDATE portales SET revocado_en = NOW() WHERE org_id = o AND revocado_en IS NULL;
  t := translate(encode(gen_random_bytes(32), 'base64'), '+/=', '-_');
  INSERT INTO portales (token, org_id, creado_por) VALUES (t, o, skf_user_id());
  RETURN QUERY SELECT 'ok'::TEXT, t;
END $$;

CREATE OR REPLACE FUNCTION skf_portal_revocar()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); n INTEGER;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN RETURN 'sin_permiso'; END IF;
  UPDATE portales SET revocado_en = NOW() WHERE org_id = o AND revocado_en IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN CASE WHEN n > 0 THEN 'ok' ELSE 'no_encontrado' END;
END $$;

-- Lo que el portal necesita, por token. NULL si el token no existe o fue revocado
-- (sin distinguir cuál). Cuenta la visita.
CREATE OR REPLACE FUNCTION skf_portal_datos(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID; r JSONB;
BEGIN
  SELECT org_id INTO o FROM portales WHERE token = p_token AND revocado_en IS NULL;
  IF o IS NULL THEN RETURN NULL; END IF;
  UPDATE portales SET accesos = accesos + 1, ultimo_acceso = NOW() WHERE token = p_token;

  SELECT jsonb_build_object(
    'org', (SELECT jsonb_build_object('nombre', g.nombre, 'pais', g.pais, 'logo_url', g.logo_url)
              FROM organizations g WHERE g.id = o AND g.activa),
    -- última evidencia por formulario (para los 9 principios), 365 días
    'evidencia', COALESCE((SELECT jsonb_agg(jsonb_build_object('plantilla_nombre', x.n, 'enviado_en', x.f))
                   FROM (SELECT e.plantilla_nombre AS n, max(e.recibido_en) AS f FROM envios e
                          WHERE e.org_id = o AND e.estado = 'enviado' AND e.recibido_en > NOW() - INTERVAL '365 days'
                          GROUP BY e.plantilla_nombre) x), '[]'::jsonb),
    -- últimas 30 inspecciones: formulario, fecha, lugar; datos+campos SOLO para el puntaje
    'inspecciones', COALESCE((SELECT jsonb_agg(z ORDER BY (z->>'fecha') DESC) FROM (
                     SELECT jsonb_build_object('formulario', e.plantilla_nombre, 'fecha', e.recibido_en,
                              'lugar', u.nombre, 'datos', e.datos, 'campos', p.campos) AS z
                       FROM envios e LEFT JOIN plantillas p ON p.id = e.plantilla_id
                                     LEFT JOIN unidades u ON u.id = e.unidad_id
                      WHERE e.org_id = o AND e.estado = 'enviado'
                      ORDER BY e.recibido_en DESC LIMIT 30) w), '[]'::jsonb),
    -- hallazgos abiertos y los cerrados en 90 días; sin nombres de personas ni fotos
    'hallazgos', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                     'descripcion', left(COALESCE(NULLIF(h.descripcion, ''), h.campo_etiqueta, 'Hallazgo'), 240),
                     'severidad', h.severidad, 'estado', h.estado, 'creado_en', h.creado_en, 'cerrado_en', h.cerrado_en,
                     'formulario', h.plantilla_nombre, 'lugar', u.nombre,
                     'fecha_limite', (SELECT min(a.fecha_limite) FROM acciones_correctivas a
                                       WHERE a.hallazgo_id = h.id AND a.estado <> 'completada'))
                     ORDER BY (h.estado = 'cerrado'), h.creado_en DESC)
                   FROM hallazgos h LEFT JOIN unidades u ON u.id = h.unidad_id
                  WHERE h.org_id = o AND (h.estado <> 'cerrado' OR h.cerrado_en > NOW() - INTERVAL '90 days')), '[]'::jsonb),
    'envios_30d', (SELECT count(*) FROM envios e WHERE e.org_id = o AND e.estado = 'enviado' AND e.recibido_en > NOW() - INTERVAL '30 days')
  ) INTO r;
  RETURN r;
END $$;

GRANT EXECUTE ON FUNCTION skf_portal_actual()        TO skf_app;
GRANT EXECUTE ON FUNCTION skf_portal_crear()         TO skf_app;
GRANT EXECUTE ON FUNCTION skf_portal_revocar()       TO skf_app;
GRANT EXECUTE ON FUNCTION skf_portal_datos(TEXT)     TO skf_app;
