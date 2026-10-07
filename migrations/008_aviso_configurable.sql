-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — avisos de puntaje bajo configurables por formulario
--
--    aviso_umbral   porcentaje bajo el cual se avisa. NULL = 70 (predeterminado);
--                   0 = no avisar nunca por este formulario.
--    aviso_max_hora tope de correos por hora en formularios PÚBLICOS. NULL = 3.
--
--  Idempotente. Si esta migración no se ha corrido, el servidor usa los valores
--  predeterminados y descarta (con un aviso en el log) lo que el cliente intente guardar.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE plantillas
  ADD COLUMN IF NOT EXISTS aviso_umbral   SMALLINT CHECK (aviso_umbral   BETWEEN 0 AND 100),
  ADD COLUMN IF NOT EXISTS aviso_max_hora SMALLINT CHECK (aviso_max_hora BETWEEN 1 AND 20);

COMMENT ON COLUMN plantillas.aviso_umbral IS
  'Avisar por correo si el cumplimiento queda bajo este %. NULL=70, 0=no avisar (migración 008).';
COMMENT ON COLUMN plantillas.aviso_max_hora IS
  'Máximo de correos por hora en formularios públicos. NULL=3 (migración 008).';

-- Cambia el tipo de retorno (suma los dos ajustes), así que hay que recrearla.
DROP FUNCTION IF EXISTS skf_publico_aviso_datos(UUID, TEXT);
CREATE FUNCTION skf_publico_aviso_datos(p_envio UUID, p_token TEXT)
RETURNS TABLE (formulario TEXT, campos JSONB, correo TEXT, datos JSONB,
               llenado_por TEXT, ya_avisado BOOLEAN,
               aviso_umbral SMALLINT, aviso_max_hora SMALLINT)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT p.nombre, p.campos, p.correo_notificacion, e.datos, e.llenado_por,
         EXISTS (SELECT 1 FROM avisos_puntaje a WHERE a.envio_id = e.id),
         p.aviso_umbral, p.aviso_max_hora
    FROM envios e JOIN plantillas p ON p.id = e.plantilla_id
   WHERE e.id = p_envio AND e.origen = 'publico'
     AND p.share_token = p_token AND p.publica = true AND NOT p.archivada;
$$;
GRANT EXECUTE ON FUNCTION skf_publico_aviso_datos(UUID, TEXT) TO skf_app;
