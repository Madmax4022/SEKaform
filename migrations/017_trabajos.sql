-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — control de trabajos (el portón del edificio)
--
--  Un «trabajo» es cualquier labor con riesgo que alguien va a hacer hoy en un
--  edificio: da igual si la ejecuta personal propio, un contratista nuestro, el
--  contratista de un arrendatario o el propio empleado del local. El comité del
--  edificio revisa lo que se exige para ese tipo de trabajo y lo autoriza o no.
--
--  Quién puede decidir sobre un trabajo:
--    · los encargados del edificio (unidad_encargados), o
--    · un administrador que TOMÓ EL RELEVO de ese edificio (unidades.relevo_por).
--  Ser administrador no basta: el relevo es un acto explícito y queda escrito,
--  para que siempre se sepa quién respondía por el edificio en ese momento.
--
--  El anónimo (quien solicita por enlace, el vigilante que consulta) nunca toca
--  las tablas: entra por funciones SECURITY DEFINER que derivan todo del token.
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Edificio: enlace de solicitudes y relevo ────────────────────────────────
ALTER TABLE unidades ADD COLUMN IF NOT EXISTS token_solicitud TEXT;
ALTER TABLE unidades ADD COLUMN IF NOT EXISTS relevo_por   UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE unidades ADD COLUMN IF NOT EXISTS relevo_desde TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS unidades_token_solicitud_uni ON unidades (token_solicitud) WHERE token_solicitud IS NOT NULL;

-- ── Comité del edificio ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS unidad_encargados (
  unidad_id UUID NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
  user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  org_id    UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  desde     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (unidad_id, user_id)
);
ALTER TABLE unidad_encargados ENABLE ROW LEVEL SECURITY;
ALTER TABLE unidad_encargados NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS unidad_encargados_sel ON unidad_encargados;
DROP POLICY IF EXISTS unidad_encargados_ins ON unidad_encargados;
DROP POLICY IF EXISTS unidad_encargados_del ON unidad_encargados;
CREATE POLICY unidad_encargados_sel ON unidad_encargados FOR SELECT USING (skf_puede_leer(org_id));
CREATE POLICY unidad_encargados_ins ON unidad_encargados FOR INSERT WITH CHECK (skf_es_admin_org(org_id));
CREATE POLICY unidad_encargados_del ON unidad_encargados FOR DELETE USING (skf_es_admin_org(org_id));

-- Encargados invitados que todavía no tienen cuenta. Al nombrar al comité de un edificio
-- lo normal es que la persona aún no exista en la app: se la invita por correo y aquí
-- queda anotado de qué edificio se va a encargar. Cuando entra por primera vez,
-- skf_encargos_reclamar() la convierte en encargada de verdad.
CREATE TABLE IF NOT EXISTS unidad_invitados (
  unidad_id UUID NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
  org_id    UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email     CITEXT NOT NULL CHECK (length(email) BETWEEN 5 AND 254),
  creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (unidad_id, email)
);
ALTER TABLE unidad_invitados ENABLE ROW LEVEL SECURITY;
ALTER TABLE unidad_invitados NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS unidad_invitados_sel ON unidad_invitados;
DROP POLICY IF EXISTS unidad_invitados_ins ON unidad_invitados;
DROP POLICY IF EXISTS unidad_invitados_del ON unidad_invitados;
CREATE POLICY unidad_invitados_sel ON unidad_invitados FOR SELECT USING (skf_es_admin_org(org_id));
CREATE POLICY unidad_invitados_ins ON unidad_invitados FOR INSERT WITH CHECK (skf_es_admin_org(org_id));
CREATE POLICY unidad_invitados_del ON unidad_invitados FOR DELETE USING (skf_es_admin_org(org_id));

-- Quien entra reclama los edificios para los que fue invitado en la empresa activa.
-- Solo con SU correo (el de la sesión) y solo si ya puede escribir en esa empresa.
CREATE OR REPLACE FUNCTION skf_encargos_reclamar()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o UUID := skf_org_id(); yo UUID := skf_user_id(); correo CITEXT; n INTEGER;
BEGIN
  IF o IS NULL OR yo IS NULL OR NOT skf_puede_escribir(o) THEN RETURN 0; END IF;
  SELECT email INTO correo FROM users WHERE id = yo;
  INSERT INTO unidad_encargados (unidad_id, user_id, org_id)
  SELECT i.unidad_id, yo, o FROM unidad_invitados i WHERE i.org_id = o AND i.email = correo
  ON CONFLICT DO NOTHING;
  DELETE FROM unidad_invitados i WHERE i.org_id = o AND i.email = correo;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ¿Quien pregunta responde hoy por este edificio? Encargado que sigue siendo
-- miembro, o administrador con el relevo tomado.
CREATE OR REPLACE FUNCTION skf_atiende_unidad(u UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM unidad_encargados e
                  WHERE e.unidad_id = u AND e.user_id = skf_user_id() AND skf_puede_escribir(e.org_id))
      OR EXISTS (SELECT 1 FROM unidades x
                  WHERE x.id = u AND x.relevo_por = skf_user_id() AND skf_es_admin_org(x.org_id));
$$;

-- ── Trabajos ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trabajos (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  unidad_id           UUID NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
  numero              INTEGER,
  token               TEXT NOT NULL UNIQUE CHECK (length(token) >= 24),
  titulo              TEXT NOT NULL CHECK (length(titulo) BETWEEN 3 AND 140),
  tipo                TEXT NOT NULL CHECK (tipo IN ('alturas','caliente','electrico','incendio','general','rutinario')),
  criticidad          TEXT NOT NULL CHECK (criticidad IN ('critico','medio','bajo')),
  origen              TEXT NOT NULL CHECK (origen IN ('propio','contratista','contratista_local','personal_local')),
  quien               TEXT NOT NULL CHECK (length(quien) BETWEEN 2 AND 140),
  lugar               TEXT CHECK (lugar IS NULL OR length(lugar) <= 140),
  contacto            TEXT CHECK (contacto IS NULL OR length(contacto) <= 80),
  fecha               DATE NOT NULL,
  estado              TEXT NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','autorizado','rechazado','cerrado')),
  requisitos          JSONB NOT NULL DEFAULT '{}'::jsonb,   -- {id del requisito: true}
  fotos               JSONB NOT NULL DEFAULT '{}'::jsonb,   -- {id del requisito: imagen}
  verificado_en_sitio BOOLEAN NOT NULL DEFAULT false,
  firma_ejecuta       TEXT CHECK (firma_ejecuta IS NULL OR length(firma_ejecuta) <= 120),
  firma_responsable   TEXT CHECK (firma_responsable IS NULL OR length(firma_responsable) <= 120),
  via                 TEXT NOT NULL DEFAULT 'comite' CHECK (via IN ('enlace','comite')),
  decidido_por        UUID REFERENCES users(id) ON DELETE SET NULL,
  decidido_nombre     TEXT,
  decidido_en         TIMESTAMPTZ,
  en_relevo           BOOLEAN NOT NULL DEFAULT false,
  motivo              TEXT CHECK (motivo IS NULL OR length(motivo) <= 300),
  cerrado_en          TIMESTAMPTZ,
  registro            JSONB NOT NULL DEFAULT '[]'::jsonb,   -- [{en, que, por}], solo se agrega
  creado_por          UUID REFERENCES users(id) ON DELETE SET NULL,
  creado_en           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS trabajos_unidad_idx ON trabajos (unidad_id, estado, fecha);
CREATE INDEX IF NOT EXISTS trabajos_org_idx    ON trabajos (org_id, creado_en DESC);
CREATE UNIQUE INDEX IF NOT EXISTS trabajos_numero_uni ON trabajos (unidad_id, numero);

-- Folio correlativo por edificio. SECURITY DEFINER para que cuente todas las
-- filas del edificio aunque quien inserta no las vea; el candado evita que dos
-- solicitudes simultáneas saquen el mismo número.
CREATE OR REPLACE FUNCTION trabajos_asignar_numero()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('trabajo:' || NEW.unidad_id::text));
  SELECT COALESCE(MAX(numero), 0) + 1 INTO NEW.numero FROM trabajos WHERE unidad_id = NEW.unidad_id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_trabajos_numero ON trabajos;
CREATE TRIGGER trg_trabajos_numero BEFORE INSERT ON trabajos FOR EACH ROW EXECUTE FUNCTION trabajos_asignar_numero();

ALTER TABLE trabajos ENABLE ROW LEVEL SECURITY;
ALTER TABLE trabajos NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trabajos_sel ON trabajos;
DROP POLICY IF EXISTS trabajos_ins ON trabajos;
DROP POLICY IF EXISTS trabajos_upd ON trabajos;
-- Ver: el administrador ve todos los edificios; el encargado, solo los suyos.
CREATE POLICY trabajos_sel ON trabajos FOR SELECT
  USING (skf_support_mode() OR (skf_es_miembro(org_id) AND (skf_es_admin_org(org_id) OR skf_atiende_unidad(unidad_id))));
-- Abrir un trabajo a mano y decidir: solo quien responde hoy por el edificio.
CREATE POLICY trabajos_ins ON trabajos FOR INSERT
  WITH CHECK (skf_puede_escribir(org_id) AND skf_atiende_unidad(unidad_id));
CREATE POLICY trabajos_upd ON trabajos FOR UPDATE
  USING (skf_puede_escribir(org_id) AND skf_atiende_unidad(unidad_id))
  WITH CHECK (skf_puede_escribir(org_id) AND skf_atiende_unidad(unidad_id));
-- Sin policy de borrado: un trabajo no se borra, se rechaza o se cierra.

GRANT SELECT, INSERT, DELETE ON unidad_encargados TO skf_app;
GRANT SELECT, INSERT, DELETE ON unidad_invitados TO skf_app;
GRANT SELECT, INSERT, UPDATE ON trabajos TO skf_app;

-- ── Enlace público de solicitudes ───────────────────────────────────────────
-- A qué edificio pertenece un enlace (para pintar el formulario).
CREATE OR REPLACE FUNCTION skf_solicitud_info(p_token TEXT)
RETURNS TABLE (unidad_id UUID, unidad TEXT, org TEXT)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT u.id, u.nombre, o.nombre FROM unidades u JOIN organizations o ON o.id = u.org_id
   WHERE u.token_solicitud = p_token AND u.activa;
$$;

-- Crear la solicitud. La criticidad y los valores permitidos los valida el
-- servidor antes de llamar; aquí el edificio y la empresa salen SOLO del token.
CREATE OR REPLACE FUNCTION skf_solicitud_crear(
  p_token TEXT, p_titulo TEXT, p_tipo TEXT, p_criticidad TEXT, p_origen TEXT, p_quien TEXT,
  p_lugar TEXT, p_contacto TEXT, p_fecha DATE, p_firma_ejecuta TEXT, p_firma_responsable TEXT)
RETURNS TABLE (resultado TEXT, numero INTEGER, token TEXT, unidad TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u unidades%ROWTYPE; t TEXT; n INTEGER;
BEGIN
  SELECT * INTO u FROM unidades x WHERE x.token_solicitud = p_token AND x.activa;
  IF NOT FOUND THEN RETURN QUERY SELECT 'no_existe'::TEXT, NULL::INTEGER, NULL::TEXT, NULL::TEXT; RETURN; END IF;
  -- Freno al abuso de un enlace que circula: 40 solicitudes por edificio y hora.
  IF (SELECT count(*) FROM trabajos x WHERE x.unidad_id = u.id AND x.via = 'enlace' AND x.creado_en > NOW() - INTERVAL '1 hour') >= 40 THEN
    RETURN QUERY SELECT 'demasiadas'::TEXT, NULL::INTEGER, NULL::TEXT, NULL::TEXT; RETURN;
  END IF;
  t := translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
  INSERT INTO trabajos (org_id, unidad_id, token, titulo, tipo, criticidad, origen, quien, lugar, contacto, fecha,
                        firma_ejecuta, firma_responsable, via, registro)
  VALUES (u.org_id, u.id, t, p_titulo, p_tipo, p_criticidad, p_origen, p_quien, p_lugar, p_contacto, p_fecha,
          p_firma_ejecuta, p_firma_responsable, 'enlace',
          jsonb_build_array(jsonb_build_object('en', NOW(), 'que', 'Solicitud recibida por enlace', 'por', p_quien)))
  RETURNING trabajos.numero INTO n;
  RETURN QUERY SELECT 'ok'::TEXT, n, t, u.nombre;
END $$;

-- Lo que ve el vigilante (o quien solicitó) con el código del trabajo: si puede
-- trabajar o no. Sin fotos, sin requisitos, sin datos de contacto.
CREATE OR REPLACE FUNCTION skf_trabajo_publico(p_token TEXT)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT jsonb_build_object(
    'numero', t.numero, 'titulo', t.titulo, 'tipo', t.tipo, 'criticidad', t.criticidad, 'quien', t.quien,
    'lugar', t.lugar, 'fecha', t.fecha, 'estado', t.estado, 'motivo', t.motivo,
    'decididoEn', t.decidido_en, 'decididoPor', t.decidido_nombre, 'unidad', u.nombre, 'org', o.nombre)
  FROM trabajos t JOIN unidades u ON u.id = t.unidad_id JOIN organizations o ON o.id = t.org_id
  WHERE t.token = p_token;
$$;

GRANT EXECUTE ON FUNCTION skf_atiende_unidad(UUID) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_encargos_reclamar() TO skf_app;
GRANT EXECUTE ON FUNCTION skf_solicitud_info(TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_solicitud_crear(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) TO skf_app;
GRANT EXECUTE ON FUNCTION skf_trabajo_publico(TEXT) TO skf_app;
