-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — asesores de SST con varias empresas clientes
--
--  En Colombia buena parte de la SST la llevan asesores externos que atienden a
--  varias empresas. Un usuario marcado como asesor (lo marca el super admin):
--    · crea las cuentas de sus empresas clientes y entra a ellas como «admin»;
--    · invita al cliente como «dueño» de SU cuenta (una sola vez por empresa):
--      la empresa y sus datos son del cliente, que puede quitar al asesor;
--    · ve un resumen de todas sus empresas y cambia entre ellas.
--
--  La empresa ACTIVA ya no es «la primera membresía»: la elige la sesión, y la
--  base solo la acepta si el usuario es miembro de ella (skf_auth_perfil_en).
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE users ADD COLUMN IF NOT EXISTS es_asesor BOOLEAN NOT NULL DEFAULT false;

-- ── Datos SOLO de la empresa activa ──────────────────────────────────────────
-- Hasta ahora las policies exigían «ser miembro» de la empresa del registro. Con una
-- sola empresa por usuario bastaba; con varias (un asesor), un SELECT sin filtro traía
-- datos de TODAS sus empresas mezclados. Ahora leer, escribir y administrar exigen
-- además que sea la empresa ACTIVA de la sesión (app.org_id). El modo soporte del super
-- admin no cambia. Esta migración debe correr DESPUÉS de la 001 (migrar.sh las corre en
-- orden), porque la 001 define estas mismas funciones en su versión anterior.
CREATE OR REPLACE FUNCTION skf_puede_leer(o UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT (o = skf_org_id() AND skf_es_miembro(o)) OR skf_support_mode();
$$;

CREATE OR REPLACE FUNCTION skf_puede_escribir(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT o = skf_org_id() AND EXISTS (SELECT 1 FROM memberships
                 WHERE org_id = o AND user_id = skf_user_id()
                   AND rol IN ('dueno','admin','editor'));
$$;

CREATE OR REPLACE FUNCTION skf_es_admin_org(o UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT o = skf_org_id() AND EXISTS (SELECT 1 FROM memberships
                 WHERE org_id = o AND user_id = skf_user_id()
                   AND rol IN ('dueno','admin'));
$$;
COMMENT ON COLUMN users.es_asesor IS 'Asesor de SST: puede crear empresas clientes (migración 010).';

-- Perfil del usuario EN una organización concreta. Sin membresía (o empresa
-- inactiva) devuelve las columnas de la organización vacías: quien llama vuelve
-- a la empresa por defecto. Nunca da acceso a una empresa ajena.
CREATE OR REPLACE FUNCTION skf_auth_perfil_en(p_user_id UUID, p_org_id UUID)
RETURNS TABLE (id UUID, email CITEXT, nombre TEXT, is_active BOOLEAN, es_super BOOLEAN,
               debe_cambiar BOOLEAN, org_id UUID, rol TEXT, org_nombre TEXT, es_asesor BOOLEAN, n_empresas INTEGER)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT u.id, u.email, u.nombre, u.is_active, u.is_super_admin, u.must_change_password,
         o.id, m.rol, o.nombre, u.es_asesor,
         (SELECT count(*)::INTEGER FROM memberships mm JOIN organizations oo ON oo.id = mm.org_id AND oo.activa
           WHERE mm.user_id = u.id)
    FROM users u
    LEFT JOIN memberships m ON m.user_id = u.id
         AND m.org_id = COALESCE(p_org_id,
               (SELECT m2.org_id FROM memberships m2 JOIN organizations o2 ON o2.id = m2.org_id AND o2.activa
                 WHERE m2.user_id = u.id ORDER BY m2.creado_en LIMIT 1))
    LEFT JOIN organizations o ON o.id = m.org_id AND o.activa
   WHERE u.id = p_user_id;
$$;

-- Empresas de quien llama (para elegir una o ver el resumen).
CREATE OR REPLACE FUNCTION skf_mis_empresas()
RETURNS TABLE (org_id UUID, nombre TEXT, pais TEXT, rol TEXT, desde TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT o.id, o.nombre, o.pais, m.rol, m.creado_en
    FROM memberships m JOIN organizations o ON o.id = m.org_id AND o.activa
   WHERE m.user_id = skf_user_id()
   ORDER BY o.nombre;
$$;

-- Resumen por empresa para el tablero del asesor. Solo empresas de las que quien
-- llama es miembro. «evidencia» = último envío por formulario (365 días), con lo
-- que la página calcula los 9 principios igual que en «Hoy».
CREATE OR REPLACE FUNCTION skf_asesor_resumen()
RETURNS TABLE (org_id UUID, nombre TEXT, pais TEXT, rol TEXT, envios_30d INTEGER, ultimo_envio TIMESTAMPTZ,
               hallazgos_abiertos INTEGER, criticos_abiertos INTEGER, acciones_vencidas INTEGER,
               formularios INTEGER, tiene_dueno BOOLEAN, evidencia JSONB)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT o.id, o.nombre, o.pais, m.rol,
         (SELECT count(*)::INTEGER FROM envios e WHERE e.org_id = o.id AND e.estado = 'enviado' AND e.recibido_en > NOW() - INTERVAL '30 days'),
         (SELECT max(e.recibido_en) FROM envios e WHERE e.org_id = o.id AND e.estado = 'enviado'),
         (SELECT count(*)::INTEGER FROM hallazgos h WHERE h.org_id = o.id AND h.estado <> 'cerrado'),
         (SELECT count(*)::INTEGER FROM hallazgos h WHERE h.org_id = o.id AND h.estado <> 'cerrado' AND h.severidad = 'critico'),
         (SELECT count(*)::INTEGER FROM acciones_correctivas a JOIN hallazgos h ON h.id = a.hallazgo_id
           WHERE h.org_id = o.id AND h.estado <> 'cerrado' AND a.estado <> 'completada' AND a.fecha_limite < CURRENT_DATE),
         (SELECT count(*)::INTEGER FROM plantillas p WHERE p.org_id = o.id AND NOT p.archivada),
         EXISTS (SELECT 1 FROM memberships d WHERE d.org_id = o.id AND d.rol = 'dueno'),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('plantilla_nombre', x.n, 'enviado_en', x.f))
                     FROM (SELECT e.plantilla_nombre AS n, max(e.recibido_en) AS f FROM envios e
                            WHERE e.org_id = o.id AND e.estado = 'enviado' AND e.recibido_en > NOW() - INTERVAL '365 days'
                            GROUP BY e.plantilla_nombre) x), '[]'::jsonb)
    FROM memberships m JOIN organizations o ON o.id = m.org_id AND o.activa
   WHERE m.user_id = skf_user_id()
   ORDER BY o.nombre;
$$;

-- Un asesor crea la cuenta de una empresa cliente y queda dentro como «admin».
CREATE OR REPLACE FUNCTION skf_asesor_crear_empresa(p_nombre TEXT, p_pais TEXT)
RETURNS TABLE (resultado TEXT, org_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE nueva UUID; n INTEGER;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = skf_user_id() AND es_asesor AND is_active) THEN
    RETURN QUERY SELECT 'sin_permiso'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_nombre IS NULL OR length(btrim(p_nombre)) < 2 OR length(p_nombre) > 120 THEN
    RETURN QUERY SELECT 'nombre_invalido'::TEXT, NULL::UUID; RETURN;
  END IF;
  -- Freno contra abusos: un asesor no abre más de 30 empresas por día.
  SELECT count(*) INTO n FROM memberships WHERE user_id = skf_user_id() AND creado_en > NOW() - INTERVAL '1 day';
  IF n >= 30 THEN RETURN QUERY SELECT 'limite'::TEXT, NULL::UUID; RETURN; END IF;

  INSERT INTO organizations (nombre, pais) VALUES (btrim(p_nombre), NULLIF(btrim(COALESCE(p_pais, '')), ''))
  RETURNING id INTO nueva;
  INSERT INTO memberships (org_id, user_id, rol) VALUES (nueva, skf_user_id(), 'admin');
  RETURN QUERY SELECT 'ok'::TEXT, nueva;
END $$;

-- Invitar: igual que en la 009, y además el asesor (admin de la empresa) puede invitar
-- al CLIENTE como «dueño», solo si la empresa aún no tiene dueño ni otra invitación de dueño.
CREATE OR REPLACE FUNCTION skf_equipo_invitar(p_email CITEXT, p_rol TEXT, p_dias INTEGER DEFAULT 14)
RETURNS TABLE (resultado TEXT, invitacion_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); a RECORD;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN
    RETURN QUERY SELECT 'sin_permiso'::TEXT, NULL::UUID; RETURN;
  END IF;
  IF p_rol = 'dueno' THEN
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = skf_user_id() AND es_asesor)
       OR EXISTS (SELECT 1 FROM memberships WHERE org_id = o AND rol = 'dueno')
       OR EXISTS (SELECT 1 FROM authorized_emails WHERE org_id = o AND rol_inicial = 'dueno' AND usado_en IS NULL
                   AND is_active AND email <> p_email AND (expira_en IS NULL OR expira_en > NOW())) THEN
      RETURN QUERY SELECT 'rol_invalido'::TEXT, NULL::UUID; RETURN;
    END IF;
  ELSIF p_rol NOT IN ('admin', 'editor', 'lector') THEN
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
    IF a.es_super_admin OR a.org_id IS DISTINCT FROM o THEN
      RETURN QUERY SELECT 'no_disponible'::TEXT, NULL::UUID; RETURN;
    END IF;
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

-- Un usuario que YA tiene cuenta (p. ej. un asesor que entra a un cliente nuevo, o un
-- cliente que ya usa SEKaform) no se registra de nuevo: el admin lo agrega por correo.
-- Por privacidad, la respuesta para un correo sin cuenta es la misma «no_disponible».
CREATE OR REPLACE FUNCTION skf_equipo_agregar_existente(p_email CITEXT, p_rol TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); uid UUID;
BEGIN
  IF o IS NULL OR NOT skf_es_admin_org(o) THEN RETURN 'sin_permiso'; END IF;
  IF p_rol NOT IN ('admin', 'editor', 'lector') THEN RETURN 'rol_invalido'; END IF;
  IF p_rol = 'admin' AND skf_mi_rol() <> 'dueno' AND NOT EXISTS (SELECT 1 FROM users WHERE id = skf_user_id() AND es_asesor) THEN
    RETURN 'solo_dueno';
  END IF;
  SELECT id INTO uid FROM users WHERE email = p_email AND is_active;
  IF NOT FOUND THEN RETURN 'no_disponible'; END IF;
  IF EXISTS (SELECT 1 FROM memberships WHERE org_id = o AND user_id = uid) THEN RETURN 'ya_miembro'; END IF;
  INSERT INTO memberships (org_id, user_id, rol) VALUES (o, uid, p_rol);
  RETURN 'ok';
END $$;

GRANT EXECUTE ON FUNCTION skf_auth_perfil_en(UUID, UUID)              TO skf_app;
GRANT EXECUTE ON FUNCTION skf_mis_empresas()                          TO skf_app;
GRANT EXECUTE ON FUNCTION skf_asesor_resumen()                        TO skf_app;
GRANT EXECUTE ON FUNCTION skf_asesor_crear_empresa(TEXT, TEXT)        TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_invitar(CITEXT, TEXT, INTEGER)   TO skf_app;
GRANT EXECUTE ON FUNCTION skf_equipo_agregar_existente(CITEXT, TEXT)  TO skf_app;
