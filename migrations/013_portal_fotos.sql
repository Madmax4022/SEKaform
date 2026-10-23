-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — antes y después en el portal del cliente
--
--  El portal puede mostrar la foto de antes y la de después de los hallazgos
--  CERRADOS: la prueba más clara de que algo se corrigió. Protecciones:
--    · nunca fotos de formularios ni de hallazgos abiertos;
--    · el portal decide (mostrar_fotos). Los portales que ya existían quedan SIN
--      fotos: se compartieron con la promesa de no mostrarlas;
--    · cada hallazgo puede ocultarse del portal (foto_oculta_portal), p. ej. si
--      se ve la cara de alguien.
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE portales ADD COLUMN IF NOT EXISTS mostrar_fotos BOOLEAN;
UPDATE portales SET mostrar_fotos = false WHERE mostrar_fotos IS NULL;
ALTER TABLE portales ALTER COLUMN mostrar_fotos SET DEFAULT true;
ALTER TABLE portales ALTER COLUMN mostrar_fotos SET NOT NULL;

ALTER TABLE hallazgos ADD COLUMN IF NOT EXISTS foto_oculta_portal BOOLEAN NOT NULL DEFAULT false;

-- Portal vigente, ahora con su opción de fotos (cambia el tipo de retorno: se recrea).
DROP FUNCTION IF EXISTS skf_portal_actual();
CREATE FUNCTION skf_portal_actual()
RETURNS TABLE (token TEXT, creado_en TIMESTAMPTZ, accesos INTEGER, ultimo_acceso TIMESTAMPTZ, mostrar_fotos BOOLEAN)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT p.token, p.creado_en, p.accesos, p.ultimo_acceso, p.mostrar_fotos FROM portales p
   WHERE p.org_id = skf_org_id() AND p.revocado_en IS NULL AND skf_es_miembro(skf_org_id());
$$;

-- Crear (o regenerar) eligiendo si muestra fotos. La versión sin argumento (011) sigue sirviendo.
CREATE OR REPLACE FUNCTION skf_portal_crear(p_fotos BOOLEAN)
RETURNS TABLE (resultado TEXT, token TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); t TEXT;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN RETURN QUERY SELECT 'sin_permiso'::TEXT, NULL::TEXT; RETURN; END IF;
  UPDATE portales SET revocado_en = NOW() WHERE org_id = o AND revocado_en IS NULL;
  t := translate(encode(gen_random_bytes(32), 'base64'), '+/=', '-_');
  INSERT INTO portales (token, org_id, creado_por, mostrar_fotos) VALUES (t, o, skf_user_id(), COALESCE(p_fotos, true));
  RETURN QUERY SELECT 'ok'::TEXT, t;
END $$;

-- Encender o apagar las fotos del portal vigente sin cambiar el enlace.
CREATE OR REPLACE FUNCTION skf_portal_fotos(p_fotos BOOLEAN)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); n INTEGER;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN RETURN 'sin_permiso'; END IF;
  UPDATE portales SET mostrar_fotos = COALESCE(p_fotos, false) WHERE org_id = o AND revocado_en IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN CASE WHEN n > 0 THEN 'ok' ELSE 'no_encontrado' END;
END $$;

CREATE OR REPLACE FUNCTION skf_portal_datos(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID; r JSONB; fotos BOOLEAN; ids UUID[];
BEGIN
  SELECT org_id, mostrar_fotos INTO o, fotos FROM portales WHERE token = p_token AND revocado_en IS NULL;
  IF o IS NULL THEN RETURN NULL; END IF;
  UPDATE portales SET accesos = accesos + 1, ultimo_acceso = NOW() WHERE token = p_token;
  -- Antes y después: solo hallazgos CERRADOS (90 días), no ocultados, los 20 más recientes con foto.
  IF fotos THEN
    SELECT array_agg(x.id) INTO ids FROM (
      SELECT h.id FROM hallazgos h
       WHERE h.org_id = o AND h.estado = 'cerrado' AND h.cerrado_en > NOW() - INTERVAL '90 days'
         AND NOT h.foto_oculta_portal
         AND (h.foto_url IS NOT NULL OR EXISTS (SELECT 1 FROM acciones_correctivas a WHERE a.hallazgo_id = h.id AND a.evidencia_url IS NOT NULL))
       ORDER BY h.cerrado_en DESC LIMIT 20) x;
  END IF;

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
                     || CASE WHEN h.id = ANY(ids) THEN jsonb_build_object('antes', h.foto_url,
                          'despues', (SELECT a.evidencia_url FROM acciones_correctivas a WHERE a.hallazgo_id = h.id
                                       AND a.evidencia_url IS NOT NULL ORDER BY a.cerrado_en DESC NULLS LAST LIMIT 1))
                        ELSE '{}'::jsonb END
                     ORDER BY (h.estado = 'cerrado'), h.creado_en DESC)
                   FROM hallazgos h LEFT JOIN unidades u ON u.id = h.unidad_id
                  WHERE h.org_id = o AND (h.estado <> 'cerrado' OR h.cerrado_en > NOW() - INTERVAL '90 days')), '[]'::jsonb),
    'envios_30d', (SELECT count(*) FROM envios e WHERE e.org_id = o AND e.estado = 'enviado' AND e.recibido_en > NOW() - INTERVAL '30 days')
  ) INTO r;
  RETURN r;
END $$;


GRANT EXECUTE ON FUNCTION skf_portal_actual()          TO skf_app;
GRANT EXECUTE ON FUNCTION skf_portal_crear(BOOLEAN)    TO skf_app;
GRANT EXECUTE ON FUNCTION skf_portal_fotos(BOOLEAN)    TO skf_app;
GRANT EXECUTE ON FUNCTION skf_portal_datos(TEXT)       TO skf_app;
