-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — funciones de autenticación
--
--  El problema: login, registro y restablecimiento ocurren ANTES de que exista
--  una identidad, así que no hay app.user_id que alimente a RLS. Y las tablas
--  que necesitan tocar (users, authorized_emails, password_reset_tokens) están
--  cerradas a la app justamente para que una inyección SQL en cualquier
--  endpoint no pueda leer hashes de contraseña ni tokens.
--
--  La salida NO es abrir esas tablas, sino este puñado de funciones
--  SECURITY DEFINER: corren como skf_owner (y por tanto ignoran RLS), pero
--  cada una hace exactamente una cosa y devuelve exactamente lo necesario.
--  No existe ninguna función "dame el usuario completo": el hash de contraseña
--  solo sale del servidor dentro de skf_auth_login, que además es la única que
--  puede verificarlo.
--
--  Regla al mantener este archivo: si una función nueva puede devolver filas
--  arbitrarias según un parámetro, está mal diseñada.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- pgcrypto ya viene de 001_core.sql; crypt()/gen_salt() hacen el bcrypt DENTRO
-- de la base, así que el hash nunca viaja a la aplicación ni aparece en logs.

-- ── Login ───────────────────────────────────────────────────────────────────
-- Verifica la contraseña y devuelve el resultado ya interpretado. La app nunca
-- ve el hash, así que no puede filtrarlo por accidente.
--
-- Cuenta los intentos fallidos y bloquea temporalmente. El bloqueo se evalúa
-- antes que la contraseña para que un atacante no distinga "clave incorrecta"
-- de "cuenta bloqueada" por el tiempo de respuesta.
CREATE OR REPLACE FUNCTION skf_auth_login(
  p_email      CITEXT,
  p_password   TEXT,
  p_max_intentos INTEGER DEFAULT 5,
  p_bloqueo_min  INTEGER DEFAULT 15
)
RETURNS TABLE (
  resultado       TEXT,      -- ok | credenciales | inactivo | bloqueado
  user_id         UUID,
  es_super        BOOLEAN,
  debe_cambiar    BOOLEAN,
  bloqueado_hasta TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u RECORD;
BEGIN
  SELECT * INTO u FROM users WHERE email = p_email;

  -- Usuario inexistente: se gasta igualmente un crypt() contra un hash falso
  -- para que el tiempo de respuesta no revele si el correo está registrado.
  IF NOT FOUND THEN
    PERFORM crypt(p_password, gen_salt('bf', 10));
    RETURN QUERY SELECT 'credenciales'::TEXT, NULL::UUID, false, false, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  IF u.locked_until IS NOT NULL AND u.locked_until > NOW() THEN
    RETURN QUERY SELECT 'bloqueado'::TEXT, NULL::UUID, false, false, u.locked_until;
    RETURN;
  END IF;

  IF NOT u.is_active THEN
    RETURN QUERY SELECT 'inactivo'::TEXT, NULL::UUID, false, false, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  IF u.password_hash IS NULL OR u.password_hash = ''
     OR crypt(p_password, u.password_hash) <> u.password_hash THEN
    UPDATE users
       SET failed_login_count = failed_login_count + 1,
           locked_until = CASE
             WHEN failed_login_count + 1 >= p_max_intentos
             THEN NOW() + (p_bloqueo_min || ' minutes')::INTERVAL
             ELSE locked_until END
     WHERE id = u.id;
    RETURN QUERY SELECT 'credenciales'::TEXT, NULL::UUID, false, false, NULL::TIMESTAMPTZ;
    RETURN;
  END IF;

  UPDATE users
     SET failed_login_count = 0, locked_until = NULL, last_login_at = NOW()
   WHERE id = u.id;

  RETURN QUERY SELECT 'ok'::TEXT, u.id, u.is_super_admin, u.must_change_password, NULL::TIMESTAMPTZ;
END $$;

-- ── Registro (solo si el super admin autorizó el correo) ───────────────────
-- Devuelve si el correo puede registrarse, sin revelar nada más.
CREATE OR REPLACE FUNCTION skf_auth_puede_registrarse(p_email CITEXT)
RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM authorized_emails a
    WHERE a.email = p_email
      AND a.is_active
      AND a.usado_en IS NULL
      AND (a.expira_en IS NULL OR a.expira_en > NOW())
  ) AND NOT EXISTS (
    SELECT 1 FROM users u WHERE u.email = p_email
  );
$$;

-- Crea la cuenta y la deja dentro de su organización con el rol que definió el
-- super admin al autorizarla. Todo en una transacción: o queda el usuario con
-- su membresía y la invitación consumida, o no queda nada.
CREATE OR REPLACE FUNCTION skf_auth_registrar(
  p_email    CITEXT,
  p_password TEXT,
  p_nombre   TEXT
)
RETURNS TABLE (resultado TEXT, user_id UUID, org_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
-- Los parámetros de salida se llaman igual que columnas reales (org_id,
-- user_id), así que en INSERT ... ON CONFLICT (org_id, user_id) PL/pgSQL no
-- sabría si "org_id" es la columna o la variable, y aborta por ambigüedad.
-- Con use_column gana la columna, que es lo que quiere decir ahí.
#variable_conflict use_column
DECLARE a RECORD; nuevo UUID;
BEGIN
  SELECT * INTO a FROM authorized_emails
   WHERE email = p_email AND is_active AND usado_en IS NULL
     AND (expira_en IS NULL OR expira_en > NOW())
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'no_autorizado'::TEXT, NULL::UUID, NULL::UUID;
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
    RETURN QUERY SELECT 'ya_existe'::TEXT, NULL::UUID, NULL::UUID;
    RETURN;
  END IF;

  INSERT INTO users (email, password_hash, nombre, is_active)
    VALUES (p_email, crypt(p_password, gen_salt('bf', 12)), p_nombre, true)
    RETURNING id INTO nuevo;

  IF a.org_id IS NOT NULL THEN
    INSERT INTO memberships (org_id, user_id, rol)
      VALUES (a.org_id, nuevo, a.rol_inicial)
      ON CONFLICT (org_id, user_id) DO NOTHING;
  END IF;

  UPDATE authorized_emails SET usado_en = NOW() WHERE id = a.id;

  RETURN QUERY SELECT 'ok'::TEXT, nuevo, a.org_id;
END $$;

-- ── Restablecimiento de contraseña ─────────────────────────────────────────
-- Guarda solo el hash del token. Quien lea la tabla no puede reconstruir el
-- enlace que se envió por correo.
CREATE OR REPLACE FUNCTION skf_auth_crear_token(
  p_email      CITEXT,
  p_token_hash TEXT,
  p_minutos    INTEGER DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID;
BEGIN
  SELECT id INTO uid FROM users WHERE email = p_email AND is_active;
  IF NOT FOUND THEN
    -- Se devuelve false, pero la ruta HTTP responde igual que en el caso bueno:
    -- el formulario de "olvidé mi contraseña" no debe servir para averiguar
    -- qué correos tienen cuenta.
    RETURN false;
  END IF;

  -- Un solo token vivo por usuario: pedir otro invalida el anterior.
  UPDATE password_reset_tokens SET usado_en = NOW()
   WHERE user_id = uid AND usado_en IS NULL;

  INSERT INTO password_reset_tokens (token_hash, user_id, expira_en)
    VALUES (p_token_hash, uid, NOW() + (p_minutos || ' minutes')::INTERVAL);
  RETURN true;
END $$;

-- Consume el token y cambia la contraseña en un solo paso, para que no exista
-- una ventana donde el token ya se validó pero todavía sirve.
CREATE OR REPLACE FUNCTION skf_auth_consumir_token(
  p_token_hash TEXT,
  p_password   TEXT
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t RECORD;
BEGIN
  SELECT * INTO t FROM password_reset_tokens
   WHERE token_hash = p_token_hash FOR UPDATE;

  IF NOT FOUND THEN RETURN 'invalido'; END IF;
  IF t.usado_en IS NOT NULL THEN RETURN 'usado'; END IF;
  IF t.expira_en < NOW() THEN RETURN 'expirado'; END IF;

  UPDATE users
     SET password_hash = crypt(p_password, gen_salt('bf', 12)),
         must_change_password = false,
         failed_login_count = 0,
         locked_until = NULL
   WHERE id = t.user_id;

  UPDATE password_reset_tokens SET usado_en = NOW() WHERE token_hash = p_token_hash;
  RETURN 'ok';
END $$;

-- Cambio de contraseña con sesión iniciada: exige la contraseña actual, de modo
-- que una sesión robada no baste para apropiarse de la cuenta.
CREATE OR REPLACE FUNCTION skf_auth_cambiar_password(
  p_user_id  UUID,
  p_actual   TEXT,
  p_nueva    TEXT
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u RECORD;
BEGIN
  SELECT * INTO u FROM users WHERE id = p_user_id;
  IF NOT FOUND THEN RETURN 'invalido'; END IF;
  IF u.password_hash IS NULL OR crypt(p_actual, u.password_hash) <> u.password_hash THEN
    RETURN 'credenciales';
  END IF;

  UPDATE users
     SET password_hash = crypt(p_nueva, gen_salt('bf', 12)),
         must_change_password = false
   WHERE id = p_user_id;
  RETURN 'ok';
END $$;

-- ── Perfil para rehidratar la sesión en cada petición ──────────────────────
-- Flask-Login reconstruye el usuario en CADA petición a partir del id de la
-- cookie, y no puede leer `users` directamente: esa tabla está cerrada a la
-- app, y su policy exige un app.user_id que todavía no está fijado (es
-- precisamente lo que se está resolviendo). Sin esta función, el callback
-- devuelve NULL y nadie consigue iniciar sesión nunca.
--
-- Devuelve también la organización y el rol en la misma llamada: son datos que
-- se necesitan siempre juntos y así se evita un segundo viaje por petición.
--
-- Acotada a p_user_id, que la app toma de una cookie firmada: no permite
-- enumerar usuarios ni expone el hash de contraseña.
CREATE OR REPLACE FUNCTION skf_auth_perfil(p_user_id UUID)
RETURNS TABLE (
  id             UUID,
  email          CITEXT,
  nombre         TEXT,
  is_active      BOOLEAN,
  es_super       BOOLEAN,
  debe_cambiar   BOOLEAN,
  org_id         UUID,
  rol            TEXT,
  org_nombre     TEXT
)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT u.id, u.email, u.nombre, u.is_active, u.is_super_admin, u.must_change_password,
         m.org_id, m.rol, o.nombre
    FROM users u
    LEFT JOIN memberships m   ON m.user_id = u.id
    LEFT JOIN organizations o ON o.id = m.org_id AND o.activa
   WHERE u.id = p_user_id
   ORDER BY m.creado_en
   LIMIT 1;
$$;

-- ── Contexto de sesión tras autenticarse ───────────────────────────────────
-- Organización activa y rol. Acotada a p_user_id: no sirve para husmear las
-- membresías de otra persona.
CREATE OR REPLACE FUNCTION skf_auth_contexto(p_user_id UUID)
RETURNS TABLE (org_id UUID, rol TEXT, org_nombre TEXT, es_super BOOLEAN)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT m.org_id, m.rol, o.nombre, u.is_super_admin
    FROM users u
    LEFT JOIN memberships m  ON m.user_id = u.id
    LEFT JOIN organizations o ON o.id = m.org_id AND o.activa
   WHERE u.id = p_user_id
   ORDER BY m.creado_en
   LIMIT 1;
$$;

-- ── Permisos ────────────────────────────────────────────────────────────────
-- La app puede EJECUTAR estas funciones, pero sigue sin poder leer las tablas
-- que hay debajo. Esa es toda la idea.
GRANT EXECUTE ON FUNCTION skf_auth_login(CITEXT, TEXT, INTEGER, INTEGER)        TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_puede_registrarse(CITEXT)                    TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_registrar(CITEXT, TEXT, TEXT)                TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_crear_token(CITEXT, TEXT, INTEGER)           TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_consumir_token(TEXT, TEXT)                   TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_cambiar_password(UUID, TEXT, TEXT)           TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_contexto(UUID)                               TO skf_app;
GRANT EXECUTE ON FUNCTION skf_auth_perfil(UUID)                                 TO skf_app;
