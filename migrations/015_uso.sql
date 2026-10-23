-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — qué se usa (para decidir qué se borra)
--
--  Recorte del 50 %, paso 1: lo que salió del producto principal se oculta y se
--  mide 30 a 60 días. Aquí se cuenta, por día, empresa, persona y «qué» (una
--  pantalla abierta o una función usada), cuántas veces. Solo lo lee el super
--  administrador (resumen sin nombres: veces, personas y empresas por «qué»).
--  Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS uso_diario (
  dia      DATE NOT NULL DEFAULT CURRENT_DATE,
  org_id   UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  que      TEXT NOT NULL CHECK (que ~ '^[a-z_]{2,30}(:[a-z0-9_.\-]{1,40})?$'),
  veces    INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (dia, org_id, user_id, que)
);
ALTER TABLE uso_diario ENABLE ROW LEVEL SECURITY;
ALTER TABLE uso_diario NO FORCE ROW LEVEL SECURITY;
-- Sin policies: la app no la lee ni la escribe directo; solo por las funciones de abajo.

CREATE OR REPLACE FUNCTION skf_uso_contar(p_que TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u UUID := skf_user_id(); o UUID := skf_org_id();
BEGIN
  IF u IS NULL OR o IS NULL OR NOT skf_es_miembro(o) THEN RETURN; END IF;
  INSERT INTO uso_diario (org_id, user_id, que) VALUES (o, u, p_que)
  ON CONFLICT (dia, org_id, user_id, que) DO UPDATE SET veces = uso_diario.veces + 1;
END $$;

-- Resumen de los últimos días, solo para el super administrador.
CREATE OR REPLACE FUNCTION skf_uso_resumen(p_dias INTEGER)
RETURNS TABLE (que TEXT, veces BIGINT, personas BIGINT, empresas BIGINT, ultimo DATE)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT u.que, sum(u.veces), count(DISTINCT u.user_id), count(DISTINCT u.org_id), max(u.dia)
    FROM uso_diario u
   WHERE current_setting('app.is_super_admin', true) = 'on'
     AND u.dia > CURRENT_DATE - LEAST(GREATEST(p_dias, 1), 365)
   GROUP BY u.que
   ORDER BY sum(u.veces) DESC;
$$;

GRANT EXECUTE ON FUNCTION skf_uso_contar(TEXT)        TO skf_app;
GRANT EXECUTE ON FUNCTION skf_uso_resumen(INTEGER)    TO skf_app;
