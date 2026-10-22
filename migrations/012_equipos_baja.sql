-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — equipos dados de baja
--
--  Los equipos (EXT-001, GAB-002…) no tienen inventario: salen de las
--  inspecciones. Esta tabla solo guarda los que se retiraron, para que dejen de
--  avisar como atrasados. Si un equipo dado de baja se vuelve a inspeccionar
--  DESPUÉS de la baja, la app lo trata como activo otra vez (volvió a servicio).
--  Quitar la fila = reactivarlo. Idempotente.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS equipos_baja (
  org_id    UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  codigo    TEXT NOT NULL CHECK (length(codigo) BETWEEN 1 AND 40),
  motivo    TEXT CHECK (motivo IS NULL OR length(motivo) <= 120),
  baja_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  baja_por  UUID REFERENCES users(id) ON DELETE SET NULL DEFAULT skf_user_id(),
  PRIMARY KEY (org_id, codigo)
);
ALTER TABLE equipos_baja ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipos_baja NO FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS equipos_baja_sel ON equipos_baja;
DROP POLICY IF EXISTS equipos_baja_ins ON equipos_baja;
DROP POLICY IF EXISTS equipos_baja_upd ON equipos_baja;
DROP POLICY IF EXISTS equipos_baja_del ON equipos_baja;
CREATE POLICY equipos_baja_sel ON equipos_baja FOR SELECT USING (skf_puede_leer(org_id));
CREATE POLICY equipos_baja_ins ON equipos_baja FOR INSERT WITH CHECK (skf_puede_escribir(org_id));
CREATE POLICY equipos_baja_upd ON equipos_baja FOR UPDATE USING (skf_puede_escribir(org_id)) WITH CHECK (skf_puede_escribir(org_id));
-- Reactivar lo puede hacer quien da de baja: devolver un equipo al aviso no borra nada.
CREATE POLICY equipos_baja_del ON equipos_baja FOR DELETE USING (skf_puede_escribir(org_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON equipos_baja TO skf_app;
