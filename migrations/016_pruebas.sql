-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — pruebas gratis por QR (campañas)
--
--  El registro normal exige que un super administrador autorice cada correo.
--  Una CAMPAÑA es un código (el que va en el QR) que deja registrarse solo a
--  quien lo tiene, hasta un máximo de cuentas y una fecha. Quien entra así:
--    · queda como asesor (puede crear empresas cliente, y su demostración);
--    · tiene la prueba hasta users.prueba_hasta; después, solo lectura (la app
--      lo aplica al cargar el usuario: skf_prueba_estado);
--    · deja sus datos de contacto en pruebas_registros, con su consentimiento.
--  Solo el super administrador crea campañas y ve los registros (RLS).
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS campanas_prueba (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo      TEXT NOT NULL UNIQUE CHECK (codigo ~ '^[A-Za-z0-9_-]{8,40}$'),
  nombre      TEXT NOT NULL CHECK (length(nombre) BETWEEN 2 AND 80),
  dias        INTEGER NOT NULL DEFAULT 30 CHECK (dias BETWEEN 1 AND 365),
  max_usos    INTEGER NOT NULL DEFAULT 50 CHECK (max_usos BETWEEN 1 AND 10000),
  usos        INTEGER NOT NULL DEFAULT 0,
  activa      BOOLEAN NOT NULL DEFAULT true,
  expira_en   TIMESTAMPTZ,
  creado_por  UUID REFERENCES users(id) ON DELETE SET NULL,
  creado_en   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pruebas_registros (
  user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  campana_id      UUID REFERENCES campanas_prueba(id) ON DELETE SET NULL,
  celular         TEXT CHECK (celular IS NULL OR length(celular) <= 30),
  profesion       TEXT CHECK (profesion IS NULL OR length(profesion) <= 60),
  acepto_datos_en TIMESTAMPTZ NOT NULL,
  creado_en       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS prueba_hasta TIMESTAMPTZ;

ALTER TABLE campanas_prueba ENABLE ROW LEVEL SECURITY;
ALTER TABLE campanas_prueba NO FORCE ROW LEVEL SECURITY;
ALTER TABLE pruebas_registros ENABLE ROW LEVEL SECURITY;
ALTER TABLE pruebas_registros NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS campanas_super ON campanas_prueba;
DROP POLICY IF EXISTS pruebas_super ON pruebas_registros;
CREATE POLICY campanas_super ON campanas_prueba FOR ALL
  USING (current_setting('app.is_super_admin', true) = 'on') WITH CHECK (current_setting('app.is_super_admin', true) = 'on');
CREATE POLICY pruebas_super ON pruebas_registros FOR SELECT
  USING (current_setting('app.is_super_admin', true) = 'on');
GRANT SELECT, INSERT, UPDATE ON campanas_prueba TO skf_app;
GRANT SELECT ON pruebas_registros TO skf_app;

-- Lo que la página pública muestra de una campaña (sin decir cuántos usos quedan).
CREATE OR REPLACE FUNCTION skf_prueba_info(p_codigo TEXT)
RETURNS TABLE (nombre TEXT, dias INTEGER, disponible BOOLEAN)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT c.nombre, c.dias, (c.activa AND c.usos < c.max_usos AND (c.expira_en IS NULL OR c.expira_en > NOW()))
    FROM campanas_prueba c WHERE c.codigo = p_codigo;
$$;

-- Crear la cuenta de prueba. Todo o nada: el uso de la campaña, el usuario y su registro.
CREATE OR REPLACE FUNCTION skf_prueba_registrar(p_codigo TEXT, p_email CITEXT, p_password TEXT, p_nombre TEXT,
                                                p_celular TEXT, p_profesion TEXT)
RETURNS TABLE (resultado TEXT, user_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
#variable_conflict use_column
DECLARE c RECORD; nuevo UUID;
BEGIN
  SELECT * INTO c FROM campanas_prueba WHERE codigo = p_codigo FOR UPDATE;
  IF NOT FOUND OR NOT c.activa OR c.usos >= c.max_usos OR (c.expira_en IS NOT NULL AND c.expira_en <= NOW()) THEN
    RETURN QUERY SELECT 'campana_no_disponible'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
    RETURN QUERY SELECT 'ya_existe'::TEXT, NULL::UUID; RETURN;
  END IF;
  INSERT INTO users (email, password_hash, nombre, is_active, es_asesor, prueba_hasta, last_login_at)
    VALUES (p_email, crypt(p_password, gen_salt('bf', 12)), left(p_nombre, 120), true, true, NOW() + make_interval(days => c.dias), NOW())
    RETURNING id INTO nuevo;
  INSERT INTO pruebas_registros (user_id, campana_id, celular, profesion, acepto_datos_en)
    VALUES (nuevo, c.id, NULLIF(left(p_celular, 30), ''), NULLIF(left(p_profesion, 60), ''), NOW());
  UPDATE campanas_prueba SET usos = usos + 1 WHERE id = c.id;
  RETURN QUERY SELECT 'ok'::TEXT, nuevo;
END $$;

-- Hasta cuándo tiene prueba (NULL = no es una cuenta de prueba).
CREATE OR REPLACE FUNCTION skf_prueba_estado(p_user UUID)
RETURNS TIMESTAMPTZ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT prueba_hasta FROM users WHERE id = p_user;
$$;

-- Para el super administrador: quién se registró, por qué campaña y si la está usando.
CREATE OR REPLACE FUNCTION skf_pruebas_registros()
RETURNS TABLE (user_id UUID, nombre TEXT, email TEXT, celular TEXT, profesion TEXT, campana TEXT,
               registrado TIMESTAMPTZ, prueba_hasta TIMESTAMPTZ, ultimo_acceso TIMESTAMPTZ, empresas BIGINT)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT u.id, u.nombre, u.email::TEXT, r.celular, r.profesion, c.nombre, r.creado_en, u.prueba_hasta, u.last_login_at,
         (SELECT count(*) FROM memberships m WHERE m.user_id = u.id)
    FROM pruebas_registros r JOIN users u ON u.id = r.user_id LEFT JOIN campanas_prueba c ON c.id = r.campana_id
   WHERE current_setting('app.is_super_admin', true) = 'on'
   ORDER BY r.creado_en DESC;
$$;

GRANT EXECUTE ON FUNCTION skf_prueba_info(TEXT)                                         TO skf_app;
GRANT EXECUTE ON FUNCTION skf_prueba_registrar(TEXT, CITEXT, TEXT, TEXT, TEXT, TEXT)    TO skf_app;
GRANT EXECUTE ON FUNCTION skf_prueba_estado(UUID)                                       TO skf_app;
GRANT EXECUTE ON FUNCTION skf_pruebas_registros()                                       TO skf_app;
