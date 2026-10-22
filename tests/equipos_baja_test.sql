-- ═══════════════════════════════════════════════════════════════════════════
--  Equipos dados de baja (migración 012): quién puede y aislamiento por empresa
--  Se corre como skf_app (sujeto a RLS), en una transacción que se revierte.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'd1111111-1111-1111-1111-111111111111';
  org_b UUID := 'd2222222-2222-2222-2222-222222222222';
  edit_a UUID := 'da000000-0000-0000-0000-00000000000e';
  lect_a UUID := 'da000000-0000-0000-0000-00000000000c';
  admin_b UUID := 'db000000-0000-0000-0000-00000000000a';
  super UUID := 'd5555555-0000-0000-0000-000000000000';
  n INTEGER; u UUID;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Bajas A'), (org_b, 'Bajas B');
  INSERT INTO users (id, email) VALUES (edit_a, 'ed@bajas-a.co'), (lect_a, 'lec@bajas-a.co'), (admin_b, 'adm@bajas-b.co'), (super, 'super@bajas.co');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, edit_a, 'editor'), (org_a, lect_a, 'lector'), (org_b, admin_b, 'admin');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- 1 · un editor da de baja; queda quién lo hizo
  PERFORM set_config('app.user_id', edit_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  INSERT INTO equipos_baja (org_id, codigo, motivo) VALUES (org_a, 'EXT-004', 'Retirado de servicio');
  SELECT baja_por INTO u FROM equipos_baja WHERE codigo = 'EXT-004';
  ASSERT u = edit_a, 'Queda registrado quién lo dio de baja';
  BEGIN
    INSERT INTO equipos_baja (org_id, codigo) VALUES (org_a, 'EXT-004');
    ASSERT false, 'No dos veces el mismo código';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  -- 2 · un lector lo ve pero no da de baja ni reactiva
  PERFORM set_config('app.user_id', lect_a::text, true);
  SELECT count(*) INTO n FROM equipos_baja;
  ASSERT n = 1, 'El lector ve las bajas de su empresa';
  BEGIN
    INSERT INTO equipos_baja (org_id, codigo) VALUES (org_a, 'EXT-005');
    ASSERT false, 'Un lector no da de baja';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  DELETE FROM equipos_baja WHERE codigo = 'EXT-004';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Un lector no reactiva';

  -- 3 · otra empresa no ve, no toca, no escribe en la ajena
  PERFORM set_config('app.user_id', admin_b::text, true);
  PERFORM set_config('app.org_id', org_b::text, true);
  SELECT count(*) INTO n FROM equipos_baja;
  ASSERT n = 0, 'B no ve las bajas de A';
  DELETE FROM equipos_baja WHERE codigo = 'EXT-004';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'B no reactiva equipos de A';
  BEGIN
    INSERT INTO equipos_baja (org_id, codigo) VALUES (org_a, 'EXT-009');
    ASSERT false, 'B no escribe en A';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  INSERT INTO equipos_baja (org_id, codigo) VALUES (org_b, 'EXT-004');   -- el mismo código en otra empresa es otro equipo

  -- 4 · el editor de A lo reactiva
  PERFORM set_config('app.user_id', edit_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  DELETE FROM equipos_baja WHERE codigo = 'EXT-004';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'El editor reactiva el equipo (solo el suyo)';
END $$;

ROLLBACK;
\echo 'OK: equipos dados de baja (editor sí, lector no, aislado por empresa)'
