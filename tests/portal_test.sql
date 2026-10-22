-- ═══════════════════════════════════════════════════════════════════════════
--  Portal del cliente (migración 011): enlace en vivo, revocable, sin detalle
--
--  Se corre como skf_app (sujeto a RLS). Todo dentro de una transacción que se
--  revierte, así que no deja rastro.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'b1111111-1111-1111-1111-111111111111';
  org_b UUID := 'b2222222-2222-2222-2222-222222222222';
  admin_a UUID := 'ba000000-0000-0000-0000-00000000000a';
  edit_a  UUID := 'ba000000-0000-0000-0000-00000000000e';
  admin_b UUID := 'bb000000-0000-0000-0000-00000000000a';
  super UUID := 'b5555555-0000-0000-0000-000000000000';
  pl UUID := 'bc000000-0000-0000-0000-000000000001';
  r RECORD; t1 TEXT; t2 TEXT; d JSONB; n INTEGER;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre, pais) VALUES (org_a, 'Portal A', 'CO'), (org_b, 'Portal B', 'CO');
  INSERT INTO users (id, email, is_super_admin) VALUES (admin_a, 'adm@portal-a.co', false), (edit_a, 'ed@portal-a.co', false),
    (admin_b, 'adm@portal-b.co', false), (super, 'super@portal.co', true);
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, admin_a, 'admin'), (org_a, edit_a, 'editor'), (org_b, admin_b, 'admin');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- datos de A (con cosas que el portal NO debe mostrar: quién llenó, firma, foto)
  PERFORM set_config('app.user_id', admin_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  INSERT INTO plantillas (id, org_id, nombre, campos) VALUES (pl, org_a, 'Lista SST', '[{"id":"q","tipo":"si_no","etiqueta":"P"}]');
  INSERT INTO envios (id, org_id, plantilla_id, plantilla_nombre, datos, estado, llenado_por, llenado_correo)
    VALUES (gen_random_uuid(), org_a, pl, 'Lista SST', '{"q":"No","firma":"data:image/png;base64,SECRETO"}', 'enviado', 'Juana Pérez', 'juana@a.co');
  INSERT INTO hallazgos (id, org_id, plantilla_id, plantilla_nombre, descripcion, severidad, estado, foto_url, reportado_por)
    VALUES (gen_random_uuid(), org_a, pl, 'Lista SST', 'Extintor vencido', 'critico', 'abierto', 'gs://fotos/secreta.jpg', 'Juana Pérez');

  -- 1 · un editor no crea el portal; el admin sí
  PERFORM set_config('app.user_id', edit_a::text, true);
  SELECT * INTO r FROM skf_portal_crear();
  ASSERT r.resultado = 'sin_permiso', 'Un editor no crea el portal';
  PERFORM set_config('app.user_id', admin_a::text, true);
  SELECT * INTO r FROM skf_portal_crear();
  ASSERT r.resultado = 'ok' AND length(r.token) >= 40, 'El admin crea el portal con un token largo';
  t1 := r.token;
  SELECT count(*) INTO n FROM skf_portal_actual();
  ASSERT n = 1, 'Hay un portal vigente';

  -- 2 · por el token: estado en vivo, SIN nombres, firmas, correos ni fotos
  d := skf_portal_datos(t1);
  ASSERT d->'org'->>'nombre' = 'Portal A', 'Trae la empresa del token';
  ASSERT jsonb_array_length(d->'hallazgos') = 1 AND d->'hallazgos'->0->>'descripcion' = 'Extintor vencido', 'Trae el hallazgo';
  ASSERT (d->>'envios_30d')::int = 1, 'Cuenta los registros';
  ASSERT position('Juana' IN d::text) = 0, 'No sale el nombre de quien llenó ni de quien reportó';
  ASSERT position('juana@a.co' IN d::text) = 0, 'No sale el correo';
  ASSERT position('secreta.jpg' IN d::text) = 0, 'No sale la foto';
  -- (las respuestas sí viajan al servidor para el puntaje; la API las descarta: tests/api_test.py)
  SELECT accesos INTO n FROM skf_portal_actual();
  ASSERT n = 1, 'Cuenta la visita';

  -- 3 · tokens que no sirven: inventado, de otra empresa, revocado
  ASSERT skf_portal_datos('token-inventado-que-no-existe-0000000000') IS NULL, 'Token inventado: nada';
  SELECT * INTO r FROM skf_portal_crear();
  t2 := r.token;
  ASSERT t2 <> t1 AND skf_portal_datos(t1) IS NULL, 'Cambiar el enlace deja sin efecto el anterior';
  ASSERT skf_portal_datos(t2) IS NOT NULL, 'El nuevo funciona';

  -- 4 · el admin de B no ve ni revoca el portal de A
  PERFORM set_config('app.user_id', admin_b::text, true);
  PERFORM set_config('app.org_id', org_b::text, true);
  SELECT count(*) INTO n FROM skf_portal_actual();
  ASSERT n = 0, 'B no ve el portal de A';
  ASSERT skf_portal_revocar() = 'no_encontrado', 'B no tiene portal que revocar';
  ASSERT skf_portal_datos(t2) IS NOT NULL, 'El de A sigue vivo';
  SELECT count(*) INTO n FROM portales;
  ASSERT n = 0, 'B no lee la tabla de portales de A';
  BEGIN
    INSERT INTO portales (token, org_id) VALUES (repeat('x', 40), org_a);
    ASSERT false, 'La app no debe poder escribir portales directamente';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 5 · el admin de A lo desactiva
  PERFORM set_config('app.user_id', admin_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  ASSERT skf_portal_revocar() = 'ok', 'El admin lo desactiva';
  ASSERT skf_portal_datos(t2) IS NULL, 'Desactivado: ya no abre';
  SELECT count(*) INTO n FROM skf_portal_actual();
  ASSERT n = 0, 'No queda portal vigente';
END $$;

ROLLBACK;
\echo 'OK: portal (en vivo, revocable, sin nombres ni fotos, aislado por empresa)'
