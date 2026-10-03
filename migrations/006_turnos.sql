-- ═══════════════════════════════════════════════════════════════════════════
--  Kanan Sentinel · SEKaform — turnos de la organización
--
--  Control por turnos: cada organización define sus turnos (nombre, hora de
--  inicio y de fin) y qué formularios se esperan en cada uno. Se guarda como
--  un JSONB en la propia organización: es configuración pequeña, de lectura
--  frecuente, y viaja con /api/bootstrap sin una consulta adicional.
--
--    turnos_config = {
--      "turnos":   [{"id":"t1","nombre":"Mañana","inicio":"06:00","fin":"14:00"}, …],
--      "esperado": ["<id de plantilla>", …]
--    }
--
--  La edición queda protegida por la política org_upd ya existente: solo
--  dueño/admin de la organización (o super admin) puede actualizarla; el resto
--  de miembros la lee. Idempotente: se puede re-ejecutar completo.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS turnos_config JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN organizations.turnos_config IS
  'Turnos de la organización y formularios esperados por turno (ver migración 006).';
