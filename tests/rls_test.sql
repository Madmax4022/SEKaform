-- ═══════════════════════════════════════════════════════════════════════════
--  Prueba de aislamiento entre clientes (RLS)
--
--  Es la prueba más importante del repositorio. Todo el multi-inquilino
--  descansa en que un miembro de la organización A jamás vea una fila de la
--  organización B, aunque la aplicación se equivoque y omita un WHERE.
--
--  Se corre como skf_app (NO como superusuario: un superusuario se salta RLS
--  y la prueba pasaría siempre, sin probar nada).
--
--    docker exec -i pg psql -U skf_app -d skf -v ON_ERROR_STOP=1 -f rls_test.sql
--
--  Cada bloque termina en un ASSERT: si el aislamiento se rompe, el script
--  falla ruidosamente en vez de imprimir algo que nadie lee.
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- Transaccion explicita: psql corre en autocommit, asi que sin este BEGIN el
-- bloque DO confirmaria los datos de prueba y la segunda ejecucion fallaria
-- por claves duplicadas. Con el, la prueba no deja rastro.
BEGIN;

DO $$
DECLARE
  org_a  UUID := '11111111-1111-1111-1111-111111111111';
  org_b  UUID := '22222222-2222-2222-2222-222222222222';
  user_a UUID := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  user_b UUID := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  super  UUID := '55555555-0000-0000-0000-000000000000';
  cat_id UUID := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  n      INTEGER;
BEGIN
  -- ── Montaje. Se hace con contexto de super admin, que es justo el rol que
  -- en producción da de alta organizaciones y usuarios. ────────────────────
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);

  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Cliente A'), (org_b, 'Cliente B');
  INSERT INTO users (id, email, is_super_admin) VALUES
    (user_a, 'a@cliente-a.com', false),
    (user_b, 'b@cliente-b.com', false),
    (super,  'super@kanansentinel.com', true);
  INSERT INTO memberships (org_id, user_id, rol) VALUES
    (org_a, user_a, 'dueno'), (org_b, user_b, 'dueno');

  -- Una plantilla del catálogo, todavía sin conceder a nadie.
  INSERT INTO plantillas (id, es_catalogo, org_id, nombre, vertical)
    VALUES (cat_id, true, NULL, 'Inspección de Extintores (NFPA 10)', 'inmuebles');

  -- ── Datos operativos de cada cliente ──────────────────────────────────
  PERFORM set_config('app.is_super_admin', 'off', true);

  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  INSERT INTO plantillas (id, es_catalogo, org_id, nombre)
    VALUES (gen_random_uuid(), false, org_a, 'Ronda nocturna — A');
  INSERT INTO unidades (id, org_id, nombre) VALUES (gen_random_uuid(), org_a, 'Sede Norte A');

  PERFORM set_config('app.user_id', user_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  INSERT INTO plantillas (id, es_catalogo, org_id, nombre)
    VALUES (gen_random_uuid(), false, org_b, 'Ronda nocturna — B');
  INSERT INTO unidades (id, org_id, nombre) VALUES (gen_random_uuid(), org_b, 'Sede Sur B');

  -- ══ 1 · Un miembro solo ve lo suyo ═══════════════════════════════════
  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);

  SELECT count(*) INTO n FROM unidades;
  ASSERT n = 1, format('A deberia ver 1 unidad, vio %s', n);

  SELECT count(*) INTO n FROM unidades WHERE org_id = org_b;
  ASSERT n = 0, 'FUGA: A vio unidades de B';

  SELECT count(*) INTO n FROM plantillas WHERE org_id = org_b;
  ASSERT n = 0, 'FUGA: A vio plantillas de B';

  -- ══ 2 · Sin concesion, el catalogo es invisible ══════════════════════
  SELECT count(*) INTO n FROM plantillas WHERE es_catalogo;
  ASSERT n = 0, 'FUGA: A vio una plantilla de catalogo sin concesion vigente';

  -- ══ 3 · Con concesion del super admin, aparece ═══════════════════════
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO form_access_grants (plantilla_id, org_id, otorgado_por)
    VALUES (cat_id, org_a, super);
  PERFORM set_config('app.is_super_admin', 'off', true);

  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  SELECT count(*) INTO n FROM plantillas WHERE es_catalogo;
  ASSERT n = 1, format('A deberia ver 1 plantilla de catalogo concedida, vio %s', n);

  -- ...y sigue invisible para B, que no la tiene concedida.
  PERFORM set_config('app.user_id', user_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  SELECT count(*) INTO n FROM plantillas WHERE es_catalogo;
  ASSERT n = 0, 'FUGA: la concesion a A dejo ver el formulario a B';

  -- ══ 4 · Revocar quita el acceso ══════════════════════════════════════
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  UPDATE form_access_grants SET revocado_en = NOW(), revocado_por = super
    WHERE plantilla_id = cat_id AND org_id = org_a;
  PERFORM set_config('app.is_super_admin', 'off', true);

  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  SELECT count(*) INTO n FROM plantillas WHERE es_catalogo;
  ASSERT n = 0, 'FUGA: la plantilla siguio visible despues de revocar';

  -- ══ 5 · Un cliente no puede tocar el catalogo ════════════════════════
  BEGIN
    UPDATE plantillas SET nombre = 'secuestrada' WHERE id = cat_id;
    ASSERT NOT FOUND, 'FUGA: un cliente pudo editar una plantilla del catalogo';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- rechazo correcto
  END;

  -- ══ 6 · Un cliente no puede escribir en otra organizacion ════════════
  BEGIN
    INSERT INTO unidades (id, org_id, nombre) VALUES (gen_random_uuid(), org_b, 'Inyectada por A');
    RAISE EXCEPTION 'FUGA: A pudo insertar una unidad en la organizacion B';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL; -- rechazo correcto: la WITH CHECK de la policy lo bloqueo
  END;

  -- ══ 7 · El super admin NO ve datos operativos sin modo soporte ═══════
  -- Administrar accesos no es lo mismo que leer las inspecciones del cliente.
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.org_id',  '', true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  PERFORM set_config('app.support_mode', 'off', true);

  SELECT count(*) INTO n FROM unidades;
  ASSERT n = 0, format('FUGA: el super admin vio %s unidades sin activar modo soporte', n);

  -- ...pero con modo soporte activo (ruta auditada) sí puede dar apoyo.
  PERFORM set_config('app.support_mode', 'on', true);
  SELECT count(*) INTO n FROM unidades;
  ASSERT n = 2, format('El modo soporte deberia ver las 2 unidades, vio %s', n);

  -- ══ 8 · Sin contexto de sesion, no se ve nada ════════════════════════
  -- Una conexion del pool que por error no fije las variables no puede
  -- convertirse en un volcado completo de la base.
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.org_id', '', true);
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.support_mode', 'off', true);

  SELECT count(*) INTO n FROM unidades;
  ASSERT n = 0, format('FUGA: una conexion sin contexto vio %s unidades', n);
  SELECT count(*) INTO n FROM envios;
  ASSERT n = 0, 'FUGA: una conexion sin contexto vio envios';

  RAISE NOTICE 'RLS OK — 8 escenarios de aislamiento verificados';
END $$;

ROLLBACK;
