-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — notificaciones push al celular
--
--  Cada celular que activa los avisos guarda aquí su suscripción Web Push
--  (endpoint del navegador + llaves para cifrar). El celular es de quien inició
--  sesión en él por última vez: suscribirse de nuevo lo reasigna.
--
--  La app nunca lee la tabla de otros: solo ve y borra las suyas (RLS). Para
--  enviar, el servidor usa funciones acotadas a un EVENTO RECIENTE (un hallazgo
--  crítico o un encargo de hace menos de 10 minutos) que devuelven a quién
--  avisar: así no sirven para listar los celulares de una empresa.
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS push_suscripciones (
  endpoint      TEXT PRIMARY KEY CHECK (endpoint ~ '^https://' AND length(endpoint) <= 1000),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  p256dh        TEXT NOT NULL CHECK (length(p256dh) BETWEEN 40 AND 200),
  auth          TEXT NOT NULL CHECK (length(auth) BETWEEN 10 AND 60),
  agente        TEXT,
  creado_en     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ultimo_envio  TIMESTAMPTZ,
  fallos        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS push_user_idx ON push_suscripciones (user_id);
ALTER TABLE push_suscripciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_suscripciones NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS push_sel ON push_suscripciones;
DROP POLICY IF EXISTS push_del ON push_suscripciones;
CREATE POLICY push_sel ON push_suscripciones FOR SELECT USING (user_id = skf_user_id());
CREATE POLICY push_del ON push_suscripciones FOR DELETE USING (user_id = skf_user_id());
GRANT SELECT, DELETE ON push_suscripciones TO skf_app;

-- Activar los avisos en este celular (o reasignarlo a quien inició sesión ahora).
CREATE OR REPLACE FUNCTION skf_push_suscribir(p_endpoint TEXT, p_p256dh TEXT, p_auth TEXT, p_agente TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u UUID := skf_user_id();
BEGIN
  IF u IS NULL THEN RETURN 'sin_sesion'; END IF;
  INSERT INTO push_suscripciones (endpoint, user_id, p256dh, auth, agente)
  VALUES (p_endpoint, u, p_p256dh, p_auth, left(p_agente, 200))
  ON CONFLICT (endpoint) DO UPDATE SET user_id = u, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
    agente = EXCLUDED.agente, fallos = 0;
  RETURN 'ok';
END $$;

-- Quién recibe el aviso de un hallazgo CRÍTICO recién creado: dueños y administradores
-- de su empresa (menos quien lo reportó).
CREATE OR REPLACE FUNCTION skf_push_hallazgo_critico(p_hallazgo UUID, p_excluir UUID)
RETURNS TABLE (endpoint TEXT, p256dh TEXT, auth TEXT, org TEXT, descripcion TEXT, formulario TEXT, lugar TEXT)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT s.endpoint, s.p256dh, s.auth, g.nombre, h.descripcion, h.plantilla_nombre, u.nombre
    FROM hallazgos h
    JOIN organizations g ON g.id = h.org_id AND g.activa
    JOIN memberships m ON m.org_id = h.org_id AND m.rol IN ('dueno', 'admin')
    JOIN push_suscripciones s ON s.user_id = m.user_id
    LEFT JOIN unidades u ON u.id = h.unidad_id
   WHERE h.id = p_hallazgo AND h.severidad = 'critico' AND h.creado_en > NOW() - INTERVAL '10 minutes'
     AND (p_excluir IS NULL OR m.user_id <> p_excluir);
$$;

-- Quién recibe el aviso de un encargo recién creado: la persona encargada, si tiene cuenta
-- en esa empresa.
CREATE OR REPLACE FUNCTION skf_push_encargo(p_asignacion UUID)
RETURNS TABLE (endpoint TEXT, p256dh TEXT, auth TEXT, org TEXT, formulario TEXT, plantilla_id UUID, fecha_limite DATE)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT s.endpoint, s.p256dh, s.auth, g.nombre, a.plantilla_nombre, a.plantilla_id, a.fecha_limite
    FROM asignaciones a
    JOIN organizations g ON g.id = a.org_id AND g.activa
    JOIN users us ON lower(us.email) = lower(a.correo)
    JOIN memberships m ON m.org_id = a.org_id AND m.user_id = us.id
    JOIN push_suscripciones s ON s.user_id = us.id
   WHERE a.id = p_asignacion AND a.correo IS NOT NULL AND a.creado_en > NOW() - INTERVAL '10 minutes';
$$;

-- Resultado de un envío: el servicio de push dijo que la suscripción ya no existe (404/410)
-- → se borra; otro error → se cuenta, y tras 5 seguidos se borra.
CREATE OR REPLACE FUNCTION skf_push_resultado(p_endpoint TEXT, p_ok BOOLEAN, p_baja BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_baja THEN DELETE FROM push_suscripciones WHERE endpoint = p_endpoint; RETURN; END IF;
  IF p_ok THEN
    UPDATE push_suscripciones SET ultimo_envio = NOW(), fallos = 0 WHERE endpoint = p_endpoint;
  ELSE
    UPDATE push_suscripciones SET fallos = fallos + 1 WHERE endpoint = p_endpoint;
    DELETE FROM push_suscripciones WHERE endpoint = p_endpoint AND fallos >= 5;
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION skf_push_suscribir(TEXT, TEXT, TEXT, TEXT)      TO skf_app;
GRANT EXECUTE ON FUNCTION skf_push_hallazgo_critico(UUID, UUID)           TO skf_app;
GRANT EXECUTE ON FUNCTION skf_push_encargo(UUID)                          TO skf_app;
GRANT EXECUTE ON FUNCTION skf_push_resultado(TEXT, BOOLEAN, BOOLEAN)      TO skf_app;
