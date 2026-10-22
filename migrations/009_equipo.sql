-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — el equipo lo administra la propia empresa
--
--  Hasta ahora solo un super administrador podía invitar a alguien. Con estas
--  funciones, el dueño o un administrador de la organización invitan, revocan,
--  cambian permisos y quitan personas — SOLO dentro de su organización y con
--  estas reglas, que se aplican aquí en la base y no solo en la API:
--
--    · nadie puede nombrar a otro «dueño» (eso sigue siendo del super admin);
--    · un administrador no puede tocar al dueño; el dueño sí puede tocar a un admin;
--    · nadie se cambia ni se quita a sí mismo (evita quedarse sin administrador);
--    · la invitación vence (por defecto en 14 días) y no da superpoderes.
--
--  Un correo que ya tiene cuenta, o que otra organización ya invitó, se
--  responde «no_disponible» sin distinguir cuál: no se filtra quién usa la
--  plataforma. Todas son SECURITY DEFINER acotadas a skf_org_id() de la sesión.
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

-- Rol de quien llama en su organización activa (NULL si no es miembro).
CREATE OR REPLACE FUNCTION skf_mi_rol()
RETURNS TEXT LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT rol FROM memberships WHERE org_id = skf_org_id() AND user_id = skf_user_id();
$$;

-- Equipo de la organización activa: miembros con cuenta + invitaciones vigentes.
CREATE OR REPLACE FUNCTION skf_equipo_listar()
RETURNS TABLE (tipo TEXT, id UUID, email TEXT, nombre TEXT, rol TEXT, desde TIMESTAMPTZ, ultimo_ingreso TIMESTAMPTZ, expira_en TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT 'miembro', u.id, u.email::TEXT, u.nombre, m.rol, m.creado_en, u.last_login_at, NULL::TIMESTAMPTZ
    FROM memberships m JOIN users u ON u.id = m.user_id
   WHERE m.org_id = skf_org_id() AND skf_es_miembro(skf_org_id()) AND u.is_active
  UNION ALL
  SELECT 'invitacion', a.id, a.email::TEXT, NULL, a.rol_inicial, a.autorizado_en, NULL, a.expira_en
    FROM authorized_emails a
   WHERE a.org_id = skf_org_id() AND skf_es_admin_org(skf_org_id())
     AND a.is_active AND a.usado_en IS NULL AND NOT a.es_super_admin
     AND (a.expira_en IS NULL OR a.expira_en > NOW());
$$;

CREATE OR REPLACE FUNCTION skf_equipo_invitar(p_email CITEXT, p_rol TEXT, p_dias INTEGER DEFAULT 14)
RETURNS TABLE (resultado TEXT, invitacion_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); a RECORD;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN
    RETURN QUERY SELECT 'sin_permiso'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_rol NOT IN ('admin', 'editor', 'lector') THEN
    RETURN QUERY SELECT 'rol_invalido'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_email IS NULL OR p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RETURN QUERY SELECT 'correo_invalido'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
    RETURN QUERY SELECT 'no_disponible'::TEXT, NULL::UUID; RETURN;
  END IF;

  SELECT * INTO a FROM authorized_emails WHERE email = p_email FOR UPDATE;
  IF FOUND THEN
    -- De otra organización (o de super admin): no se toca.
    IF a.es_super_admin OR a.org_id IS DISTINCT FROM o THEN
      RETURN QUERY SELECT 'no_disponible'::TEXT, NULL::UUID; RETURN;
    END IF;
    -- Ya invitado por esta misma organización: se renueva (otro rol, nueva vigencia).
    UPDATE authorized_emails
       SET rol_inicial = p_rol, is_active = true, usado_en = NULL,
           expira_en = NOW() + make_interval(days => GREATEST(1, LEAST(COALESCE(p_dias, 14), 60))),
           autorizado_por = skf_user_id(), autorizado_en = NOW()
     WHERE id = a.id;
    RETURN QUERY SELECT 'renovada'::TEXT, a.id; RETURN;
  END IF;

  INSERT INTO authorized_emails (email, org_id, rol_inicial, autorizado_por, expira_en, notas)
  VALUES (p_email, o, p_rol, skf_user_id(),
          NOW() + make_interval(days => GREATEST(1, LEAST(COALESCE(p_dias, 14), 60))), 'Invitado por la organización')
  RETURNING id INTO a;
  RETURN QUERY SELECT 'ok'::TEXT, a.id;
END $$;

CREATE OR REPLACE FUNCTION skf_equipo_revocar(p_id UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); n INTEGER;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN RETURN 'sin_permiso'; END IF;
  DELETE FROM authorized_emails
   WHERE id = p_id AND org_id = o AND usado_en IS NULL AND NOT es_super_admin;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN CASE WHEN n = 1 THEN 'ok' ELSE 'no_encontrada' END;
END $$;

-- Reglas comunes para cambiar o quitar a un miembro.
CREATE OR REPLACE FUNCTION _skf_equipo_puede_tocar(p_user UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); yo TEXT := skf_mi_rol(); el TEXT;
BEGIN
  IF o IS NULL OR yo NOT IN ('dueno', 'admin') THEN RETURN 'sin_permiso'; END IF;
  IF p_user = skf_user_id() THEN RETURN 'a_ti_mismo'; END IF;
  SELECT rol INTO el FROM memberships WHERE org_id = o AND user_id = p_user;
  IF NOT FOUND THEN RETURN 'no_encontrado'; END IF;
  IF el = 'dueno' THEN RETURN 'es_dueno'; END IF;
  IF el = 'admin' AND yo <> 'dueno' THEN RETURN 'solo_dueno'; END IF;
  RETURN 'ok';
END $$;

CREATE OR REPLACE FUNCTION skf_equipo_cambiar_rol(p_user UUID, p_rol TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r TEXT := _skf_equipo_puede_tocar(p_user);
BEGIN
  IF r <> 'ok' THEN RETURN r; END IF;
  IF p_rol NOT IN ('admin', 'editor', 'lector') THEN RETURN 'rol_invalido'; END IF;
  IF p_rol = 'admin' AND skf_mi_rol() <> 'dueno' THEN RETURN 'solo_dueno'; END IF;
  UPDATE memberships SET rol = p_rol WHERE org_id = skf_org_id() AND user_id = p_user;
  RETURN 'ok';
END $$;

CREATE OR REPLACE FUNCTION skf_equipo_quitar(p_user UUID)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r TEXT := _skf_equipo_puede_tocar(p_user);
BEGIN
  IF r <> 'ok' THEN RETURN r; END IF;
  DELETE FROM memberships WHERE org_id = skf_org_id() AND user_id = p_user;
  RETURN 'ok';
END $$;

REVOKE ALL ON FUNCTION _skf_equipo_puede_tocar(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION skf_mi_rol()                                TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_listar()                         TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_invitar(CITEXT, TEXT, INTEGER)   TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_revocar(UUID)                    TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_cambiar_rol(UUID, TEXT)          TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_quitar(UUID)                     TO skf_app;
