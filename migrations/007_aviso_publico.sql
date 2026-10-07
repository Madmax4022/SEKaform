-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — aviso por puntaje bajo en formularios públicos
--
--  Un formulario público lo llena alguien SIN sesión, así que el servidor no tiene
--  contexto de organización para leer el formulario y su correo de notificación. Estas
--  dos funciones (SECURITY DEFINER, acotadas por el token del enlace) le dan solo lo
--  necesario, y la tabla avisos_puntaje garantiza dos cosas:
--    · un envío avisa A LO SUMO una vez (un reintento de la cola no duplica el correo);
--    · un formulario no manda más de p_max correos por hora (un enlace público abierto
--      no puede usarse para inundar de correos al responsable).
--
--  La tabla queda cerrada a la app (RLS sin policies): solo las funciones la tocan.
--  Idempotente: se puede re-ejecutar completo. Si esta migración no se ha corrido,
--  el servidor lo registra y los formularios públicos simplemente no avisan.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS avisos_puntaje (
  envio_id     UUID PRIMARY KEY REFERENCES envios(id) ON DELETE CASCADE,
  plantilla_id UUID NOT NULL REFERENCES plantillas(id) ON DELETE CASCADE,
  org_id       UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  enviado      BOOLEAN NOT NULL,          -- false = se omitió por el límite por hora
  creado_en    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS avisos_puntaje_plantilla_idx ON avisos_puntaje (plantilla_id, creado_en);
ALTER TABLE avisos_puntaje ENABLE ROW LEVEL SECURITY;
ALTER TABLE avisos_puntaje NO FORCE ROW LEVEL SECURITY;

-- Lo necesario para calcular el puntaje de un envío público: campos del formulario, sus
-- respuestas y a quién avisar. Solo si el envío es público Y pertenece al formulario de ese token.
CREATE OR REPLACE FUNCTION skf_publico_aviso_datos(p_envio UUID, p_token TEXT)
RETURNS TABLE (formulario TEXT, campos JSONB, correo TEXT, datos JSONB,
               llenado_por TEXT, ya_avisado BOOLEAN)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT p.nombre, p.campos, p.correo_notificacion, e.datos, e.llenado_por,
         EXISTS (SELECT 1 FROM avisos_puntaje a WHERE a.envio_id = e.id)
    FROM envios e JOIN plantillas p ON p.id = e.plantilla_id
   WHERE e.id = p_envio AND e.origen = 'publico'
     AND p.share_token = p_token AND p.publica = true AND NOT p.archivada;
$$;

-- Reserva el aviso de un envío. Devuelve true solo si hay que enviar el correo AHORA:
-- false si ese envío ya se avisó (o se omitió) o si el formulario ya llegó al límite por hora.
CREATE OR REPLACE FUNCTION skf_publico_aviso_marcar(p_envio UUID, p_token TEXT, p_max INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r RECORD; n INTEGER; permitido BOOLEAN; filas INTEGER;
BEGIN
  SELECT e.id AS envio_id, e.plantilla_id, e.org_id INTO r
    FROM envios e JOIN plantillas p ON p.id = e.plantilla_id
   WHERE e.id = p_envio AND e.origen = 'publico'
     AND p.share_token = p_token AND p.publica = true AND NOT p.archivada;
  IF NOT FOUND THEN RETURN false; END IF;

  -- Serializa los avisos de un mismo formulario para que el conteo del límite sea exacto.
  PERFORM 1 FROM plantillas WHERE id = r.plantilla_id FOR UPDATE;

  SELECT count(*) INTO n FROM avisos_puntaje
   WHERE plantilla_id = r.plantilla_id AND enviado AND creado_en > NOW() - INTERVAL '1 hour';
  permitido := n < GREATEST(p_max, 0);

  INSERT INTO avisos_puntaje (envio_id, plantilla_id, org_id, enviado)
  VALUES (r.envio_id, r.plantilla_id, r.org_id, permitido)
  ON CONFLICT (envio_id) DO NOTHING;
  GET DIAGNOSTICS filas = ROW_COUNT;

  RETURN filas = 1 AND permitido;
END $$;

GRANT EXECUTE ON FUNCTION skf_publico_aviso_datos(UUID, TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_publico_aviso_marcar(UUID, TEXT, INTEGER) TO skf_app;
