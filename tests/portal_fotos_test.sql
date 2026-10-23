-- ═══════════════════════════════════════════════════════════════════════════
--  Antes y después en el portal (migración 013): solo cerrados, ocultables, opcional
--  Se corre como skf_app (sujeto a RLS), en una transacción que se revierte.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'f1111111-1111-1111-1111-111111111111';
  admin_a UUID := 'fa000000-0000-0000-0000-00000000000a';
  edit_a  UUID := 'fa000000-0000-0000-0000-00000000000e';
  super UUID := 'f5555555-0000-0000-0000-000000000000';
  h_cer UUID := 'fb000000-0000-0000-0000-000000000001';
  h_abi UUID := 'fb000000-0000-0000-0000-000000000002';
  h_ocu UUID := 'fb000000-0000-0000-0000-000000000003';
  f TEXT := 'data:image/jpeg;base64,QUJD';
  r RECORD; t TEXT; d JSONB; x JSONB; n INTEGER;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Fotos A');
  INSERT INTO users (id, email) VALUES (admin_a, 'adm@fotos-a.co'), (edit_a, 'ed@fotos-a.co'), (super, 'super@fotos.co');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, admin_a, 'admin'), (org_a, edit_a, 'editor');
  PERFORM set_config('app.is_super_admin', 'off', true);

  PERFORM set_config('app.user_id', admin_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  INSERT INTO hallazgos (id, org_id, descripcion, severidad, estado, foto_url, cerrado_en) VALUES
    (h_cer, org_a, 'Extintor sin sello', 'mayor', 'cerrado', f, NOW()),
    (h_abi, org_a, 'Salida bloqueada', 'critico', 'abierto', f, NULL),
    (h_ocu, org_a, 'Foto con una cara', 'menor', 'cerrado', f, NOW());
  INSERT INTO acciones_correctivas (id, org_id, hallazgo_id, estado, evidencia_url, cerrado_en)
    VALUES (gen_random_uuid(), org_a, h_cer, 'completada', f || 'RA==', NOW());
  UPDATE hallazgos SET foto_oculta_portal = true WHERE id = h_ocu;

  -- 1 · por defecto un portal nuevo muestra fotos, solo de lo cerrado y no oculto
  SELECT * INTO r FROM skf_portal_crear(true); t := r.token;
  SELECT mostrar_fotos INTO r FROM skf_portal_actual();
  ASSERT r.mostrar_fotos, 'El portal nuevo muestra fotos';
  d := skf_portal_datos(t);
  SELECT e INTO x FROM jsonb_array_elements(d->'hallazgos') e WHERE e->>'descripcion' = 'Extintor sin sello';
  ASSERT x->>'antes' = f AND x->>'despues' = f || 'RA==', 'Cerrado: antes y después';
  SELECT e INTO x FROM jsonb_array_elements(d->'hallazgos') e WHERE e->>'descripcion' = 'Salida bloqueada';
  ASSERT NOT (x ? 'antes'), 'Abierto: sin fotos';
  SELECT e INTO x FROM jsonb_array_elements(d->'hallazgos') e WHERE e->>'descripcion' = 'Foto con una cara';
  ASSERT NOT (x ? 'antes'), 'Ocultado: sin fotos';

  -- 2 · un editor no cambia la opción; el admin la apaga sin cambiar el enlace
  PERFORM set_config('app.user_id', edit_a::text, true);
  ASSERT skf_portal_fotos(false) = 'sin_permiso', 'Un editor no la cambia';
  PERFORM set_config('app.user_id', admin_a::text, true);
  ASSERT skf_portal_fotos(false) = 'ok', 'El admin la apaga';
  d := skf_portal_datos(t);
  ASSERT d IS NOT NULL, 'El enlace sigue siendo el mismo';
  ASSERT position('base64' IN d::text) = 0, 'Apagado: ninguna foto sale';

  -- 3 · como mucho 20 con fotos (el portal no debe pesar megas)
  ASSERT skf_portal_fotos(true) = 'ok', 'Encender de nuevo';
  INSERT INTO hallazgos (id, org_id, descripcion, severidad, estado, foto_url, cerrado_en)
    SELECT gen_random_uuid(), org_a, 'Lote ' || g, 'menor', 'cerrado', f, NOW() - (g || ' minutes')::interval FROM generate_series(1, 25) g;
  d := skf_portal_datos(t);
  SELECT count(*) INTO n FROM jsonb_array_elements(d->'hallazgos') e WHERE e ? 'antes';
  ASSERT n = 20, 'Máximo 20 hallazgos con fotos: ' || n;
END $$;

ROLLBACK;

-- 4 · los portales que ya existían antes de la 013 quedan SIN fotos (se compartieron sin ellas):
--     lo garantiza el UPDATE … WHERE mostrar_fotos IS NULL de la migración.
\echo 'OK: portal con antes y después (solo cerrados, ocultables, opcional, máximo 20)'
