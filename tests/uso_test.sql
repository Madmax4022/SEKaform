-- ═══════════════════════════════════════════════════════════════════════════
--  Qué se usa (migración 015): solo se cuenta lo propio; solo el super lo lee
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'a8111111-1111-1111-1111-111111111111';
  org_b UUID := 'a8222222-2222-2222-2222-222222222222';
  u_a UUID := 'a8000000-0000-0000-0000-0000000000a1';
  super UUID := 'a8555555-0000-0000-0000-000000000000';
  n INTEGER; r RECORD;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Uso A'), (org_b, 'Uso B');
  INSERT INTO users (id, email) VALUES (u_a, 'a@uso.co'), (super, 's@uso.co');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, u_a, 'editor');
  PERFORM set_config('app.is_super_admin', 'off', true);

  PERFORM set_config('app.user_id', u_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  PERFORM skf_uso_contar('pagina:turnos');
  PERFORM skf_uso_contar('pagina:turnos');
  PERFORM skf_uso_contar('panel:completo');
  BEGIN
    PERFORM skf_uso_contar('<script>');
    ASSERT false, 'Un «qué» con forma rara no entra';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- en una empresa de la que no es miembro: no se cuenta
  PERFORM set_config('app.org_id', org_b::text, true);
  PERFORM skf_uso_contar('pagina:plan');

  SELECT count(*) INTO n FROM uso_diario;
  ASSERT n = 0, 'La app no lee la tabla directo (sin policies: RLS no deja ver nada)';
  SELECT count(*) INTO n FROM skf_uso_resumen(30);
  ASSERT n = 0, 'Quien no es super no ve el resumen';

  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  SELECT * INTO r FROM skf_uso_resumen(30) WHERE que = 'pagina:turnos';
  ASSERT r.veces = 2 AND r.personas = 1 AND r.empresas = 1, 'Turnos: 2 veces, 1 persona, 1 empresa';
  SELECT count(*) INTO n FROM skf_uso_resumen(30) WHERE que = 'pagina:plan';
  ASSERT n = 0, 'Lo de una empresa ajena no se contó';
END $$;

ROLLBACK;
\echo 'OK: uso (se cuenta lo propio, el super lo lee, nada más)'
