-- ═══════════════════════════════════════════════════════════════════════════
--  Turnos: la configuración es editable solo por admin y aislada por cliente
--
--  Se corre como skf_app (sujeto a RLS). Todo dentro de una transacción que se
--  revierte, así que no deja rastro.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a  UUID := '71111111-1111-1111-1111-111111111111';
  org_b  UUID := '72222222-2222-2222-2222-222222222222';
  admin_a UUID := '7aaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  edit_a  UUID := '7eeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
  admin_b UUID := '7bbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  super   UUID := '75555555-0000-0000-0000-000000000000';
  cfg     JSONB := '{"turnos":[{"id":"t1","nombre":"Noche","inicio":"22:00","fin":"06:00"}],"esperado":["x"]}';
  n INTEGER; leido JSONB;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Turnos A'), (org_b, 'Turnos B');
  INSERT INTO users (id, email, is_super_admin) VALUES
    (admin_a, 'adm@turnos-a.com', false), (edit_a, 'ed@turnos-a.com', false),
    (admin_b, 'adm@turnos-b.com', false), (super, 'super@turnos.com', true);
  INSERT INTO memberships (org_id, user_id, rol) VALUES
    (org_a, admin_a, 'admin'), (org_a, edit_a, 'editor'), (org_b, admin_b, 'dueno');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- 1 · el valor por defecto es un objeto vacío (nunca NULL)
  PERFORM set_config('app.user_id', admin_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  SELECT turnos_config INTO leido FROM organizations WHERE id = org_a;
  ASSERT leido = '{}'::jsonb, 'El valor por defecto de turnos_config debe ser {}';

  -- 2 · el admin de la organización puede guardar y leerlo de vuelta
  UPDATE organizations SET turnos_config = cfg WHERE id = org_a;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'El admin debe poder actualizar los turnos de su organización';
  SELECT turnos_config INTO leido FROM organizations WHERE id = org_a;
  ASSERT leido = cfg, 'El JSONB debe volver idéntico';

  -- 3 · un editor (no admin) lee, pero NO puede cambiar
  PERFORM set_config('app.user_id', edit_a::text, true);
  SELECT turnos_config INTO leido FROM organizations WHERE id = org_a;
  ASSERT leido = cfg, 'Un miembro debe poder leer los turnos';
  UPDATE organizations SET turnos_config = '{"turnos":[]}' WHERE id = org_a;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Un editor NO debe poder cambiar los turnos';

  -- 4 · otro cliente no ve ni toca los turnos de A
  PERFORM set_config('app.user_id', admin_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  SELECT count(*) INTO n FROM organizations WHERE id = org_a;
  ASSERT n = 0, 'El cliente B no debe ver la organización A';
  UPDATE organizations SET turnos_config = '{"turnos":[]}' WHERE id = org_a;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'El cliente B no debe poder cambiar los turnos de A';
END $$;

ROLLBACK;
\echo 'turnos_test: OK'
