-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — formularios públicos (enlace / QR)
--
--  Un formulario puede compartirse por enlace o QR para que lo llene alguien
--  sin cuenta: un contratista, un visitante, un proveedor. En Supabase eso lo
--  resolvían las policies del rol `anon`; aquí no existe ese rol, así que se
--  hace con tres funciones SECURITY DEFINER, cada una acotada a una cosa.
--
--  Regla que las gobierna: el cliente anónimo NUNCA decide a qué organización
--  van los datos. El org_id se deriva SIEMPRE de la plantilla, igual que hacía
--  el trigger envios_asignar_org. Así nadie puede inyectar registros en el
--  dataset de otro cliente mandando un org_id a mano.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- Plantilla pública por su token. Devuelve solo columnas públicas: ni org_id,
-- ni autor_id, ni correo_notificacion salen de aquí.
CREATE OR REPLACE FUNCTION skf_publico_plantilla(p_token TEXT)
RETURNS TABLE (
  id UUID, nombre TEXT, campos JSONB, codigo TEXT,
  descripcion TEXT, logo_url TEXT, norma TEXT
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT p.id, p.nombre, p.campos, p.codigo, p.descripcion, p.logo_url, p.norma
    FROM plantillas p
   WHERE p.share_token = p_token AND p.publica = true AND NOT p.archivada
   LIMIT 1;
$$;

-- Envío anónimo. El servidor fija organización, número correlativo y sellos de
-- tiempo; el visitante no puede leer envíos previos, así que no podría
-- calcular el número aunque quisiera.
CREATE OR REPLACE FUNCTION skf_publico_envio(
  p_id             UUID,
  p_token          TEXT,
  p_datos          JSONB,
  p_llenado_por    TEXT DEFAULT NULL,
  p_llenado_correo TEXT DEFAULT NULL,
  p_capturado_en   TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (resultado TEXT, envio_id UUID, numero INTEGER)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pl RECORD; n INTEGER;
BEGIN
  SELECT p.id, p.org_id, p.nombre, p.codigo INTO pl
    FROM plantillas p
   WHERE p.share_token = p_token AND p.publica = true AND NOT p.archivada;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'plantilla_no_publica'::TEXT, NULL::UUID, NULL::INTEGER;
    RETURN;
  END IF;

  -- Reenviar el mismo id (la cola sin conexión reintentando) no duplica.
  IF EXISTS (SELECT 1 FROM envios e WHERE e.id = p_id) THEN
    SELECT e.numero INTO n FROM envios e WHERE e.id = p_id;
    RETURN QUERY SELECT 'ok'::TEXT, p_id, n;
    RETURN;
  END IF;

  SELECT COALESCE(MAX(e.numero), 0) + 1 INTO n FROM envios e WHERE e.plantilla_id = pl.id;

  INSERT INTO envios (id, org_id, plantilla_id, plantilla_nombre, plantilla_codigo,
                      datos, estado, numero, llenado_por, llenado_correo,
                      capturado_en, recibido_en, origen)
  VALUES (p_id, pl.org_id, pl.id, COALESCE(pl.nombre,''), COALESCE(pl.codigo,''),
          COALESCE(p_datos,'{}'::jsonb), 'enviado', n, p_llenado_por, p_llenado_correo,
          COALESCE(p_capturado_en, NOW()), NOW(), 'publico');

  RETURN QUERY SELECT 'ok'::TEXT, p_id, n;
END $$;

-- Hallazgo reportado desde un formulario público.
CREATE OR REPLACE FUNCTION skf_publico_hallazgo(
  p_id            UUID,
  p_token         TEXT,
  p_envio_id      UUID,
  p_campo_id      TEXT,
  p_campo_etiqueta TEXT,
  p_origen        TEXT,
  p_severidad     TEXT,
  p_descripcion   TEXT,
  p_foto_url      TEXT,
  p_reportado_por TEXT
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pl RECORD;
BEGIN
  SELECT p.id, p.org_id INTO pl
    FROM plantillas p
   WHERE p.share_token = p_token AND p.publica = true AND NOT p.archivada;

  IF NOT FOUND THEN RETURN 'plantilla_no_publica'; END IF;
  IF EXISTS (SELECT 1 FROM hallazgos h WHERE h.id = p_id) THEN RETURN 'ok'; END IF;

  INSERT INTO hallazgos (id, org_id, envio_id, plantilla_id, plantilla_nombre,
                         campo_id, campo_etiqueta, origen, severidad, descripcion,
                         foto_url, estado, reportado_por)
  SELECT p_id, pl.org_id, p_envio_id, pl.id, COALESCE(p.nombre,''),
         p_campo_id, p_campo_etiqueta,
         COALESCE(NULLIF(p_origen,''),'manual'),
         COALESCE(NULLIF(p_severidad,''),'menor'),
         p_descripcion, p_foto_url, 'abierto', p_reportado_por
    FROM plantillas p WHERE p.id = pl.id;

  RETURN 'ok';
END $$;

GRANT EXECUTE ON FUNCTION skf_publico_plantilla(TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_publico_envio(UUID, TEXT, JSONB, TEXT, TEXT, TIMESTAMPTZ) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_publico_hallazgo(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO skf_app;
