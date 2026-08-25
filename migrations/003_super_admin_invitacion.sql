-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — super admin desde la invitación
--
--  Antes, dar de alta a un super administrador eran dos pasos separados en el
--  tiempo: autorizar el correo, esperar a que la persona se registrara, y
--  volver a correr el script para promoverla. Si el segundo paso se olvidaba
--  —y se olvida— la cuenta quedaba como usuario normal y el panel de
--  administración simplemente respondía 404, sin pista de por qué.
--
--  Ahora la intención viaja con la invitación: se marca es_super_admin al
--  autorizar, y el registro la aplica sola. Un paso, sin ventana de olvido.
--
--  Idempotente: seguro re-ejecutar.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

ALTER TABLE authorized_emails
  ADD COLUMN IF NOT EXISTS es_super_admin BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN authorized_emails.es_super_admin IS
  'Si es true, al registrarse la cuenta queda como super administrador de la plataforma.';

-- Reemplaza la versión de 002_auth_functions.sql. Único cambio: propaga
-- es_super_admin de la invitación al usuario recién creado.
CREATE OR REPLACE FUNCTION skf_auth_registrar(
  p_email    CITEXT,
  p_password TEXT,
  p_nombre   TEXT
)
RETURNS TABLE (resultado TEXT, user_id UUID, org_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
-- Los parámetros de salida se llaman igual que columnas reales (org_id,
-- user_id); con use_column gana la columna en INSERT ... ON CONFLICT.
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

  INSERT INTO users (email, password_hash, nombre, is_active, is_super_admin)
    VALUES (p_email, crypt(p_password, gen_salt('bf', 12)), p_nombre, true,
            COALESCE(a.es_super_admin, false))
    RETURNING id INTO nuevo;

  IF a.org_id IS NOT NULL THEN
    INSERT INTO memberships (org_id, user_id, rol)
      VALUES (a.org_id, nuevo, a.rol_inicial)
      ON CONFLICT (org_id, user_id) DO NOTHING;
  END IF;

  UPDATE authorized_emails SET usado_en = NOW() WHERE id = a.id;

  RETURN QUERY SELECT 'ok'::TEXT, nuevo, a.org_id;
END $$;

GRANT EXECUTE ON FUNCTION skf_auth_registrar(CITEXT, TEXT, TEXT) TO skf_app;

-- Alta de un super administrador en una sola operación. Deliberadamente NO
-- fija contraseña: solo abre la puerta. La persona elige su clave al
-- registrarse y se hashea con bcrypt dentro de la base, así que no existe
-- ninguna contraseña inicial en un script, un log o el historial del shell.
CREATE OR REPLACE FUNCTION skf_autorizar_super_admin(
  p_email  CITEXT,
  p_org_id UUID DEFAULT NULL,
  p_notas  TEXT DEFAULT 'Super administrador de plataforma'
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ya_existe BOOLEAN;
BEGIN
  SELECT EXISTS (SELECT 1 FROM users WHERE email = p_email) INTO ya_existe;

  IF ya_existe THEN
    -- La cuenta ya existe: se promueve directamente.
    UPDATE users
       SET is_super_admin = true, is_active = true
     WHERE email = p_email;
    RETURN 'promovido';
  END IF;

  INSERT INTO authorized_emails (email, org_id, rol_inicial, es_super_admin, is_active, notas)
  VALUES (p_email, p_org_id, 'dueno', true, true, p_notas)
  ON CONFLICT (email) DO UPDATE
     SET es_super_admin = true, is_active = true, usado_en = NULL,
         expira_en = NULL, org_id = COALESCE(EXCLUDED.org_id, authorized_emails.org_id),
         rol_inicial = 'dueno';
  RETURN 'autorizado';
END $$;
