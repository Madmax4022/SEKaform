-- ═══════════════════════════════════════════════════════════════════════════
--  Avisos push (migración 014): cada quien sus celulares; a quién se avisa
--  Se corre como skf_app (sujeto a RLS), en una transacción que se revierte.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'a7111111-1111-1111-1111-111111111111';
  org_b UUID := 'a7222222-2222-2222-2222-222222222222';
  dueno UUID := 'a7000000-0000-0000-0000-0000000000d0';
  admin UUID := 'a7000000-0000-0000-0000-0000000000a0';
  edit  UUID := 'a7000000-0000-0000-0000-0000000000e0';
  ajeno UUID := 'a7000000-0000-0000-0000-0000000000b0';
  super UUID := 'a7555555-0000-0000-0000-000000000000';
  k TEXT := repeat('B', 87); au TEXT := repeat('a', 22);
  h1 UUID := 'a7b00000-0000-0000-0000-000000000001'; h2 UUID := 'a7b00000-0000-0000-0000-000000000002';
  h3 UUID := 'a7b00000-0000-0000-0000-000000000003'; asg UUID := 'a7c00000-0000-0000-0000-000000000001';
  n INTEGER; t TEXT;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Push A'), (org_b, 'Push B');
  INSERT INTO users (id, email) VALUES (dueno, 'd@push-a.co'), (admin, 'a@push-a.co'), (edit, 'e@push-a.co'), (ajeno, 'x@push-b.co'), (super, 's@push.co');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, dueno, 'dueno'), (org_a, admin, 'admin'), (org_a, edit, 'editor'), (org_b, ajeno, 'admin');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- 1 · cada uno activa su celular; nadie ve los ajenos
  PERFORM set_config('app.user_id', dueno::text, true);  ASSERT skf_push_suscribir('https://push.example/d', k, au, 'cel dueño') = 'ok';
  PERFORM set_config('app.user_id', admin::text, true);  PERFORM skf_push_suscribir('https://push.example/a', k, au, NULL);
  PERFORM set_config('app.user_id', edit::text, true);   PERFORM skf_push_suscribir('https://push.example/e', k, au, NULL);
  PERFORM set_config('app.user_id', ajeno::text, true);  PERFORM skf_push_suscribir('https://push.example/x', k, au, NULL);
  SELECT count(*) INTO n FROM push_suscripciones;
  ASSERT n = 1, 'Cada quien ve solo su celular: ' || n;
  BEGIN
    INSERT INTO push_suscripciones (endpoint, user_id, p256dh, auth) VALUES ('https://push.example/z', dueno, k, au);
    ASSERT false, 'La app no inserta directo (ni a nombre de otro)';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  DELETE FROM push_suscripciones WHERE endpoint = 'https://push.example/d';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'No borra el celular de otro';
  BEGIN
    PERFORM skf_push_suscribir('http://inseguro/x', k, au, NULL);
    ASSERT false, 'Solo endpoints https';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- 2 · hallazgo crítico reciente → dueño y admin de A (menos quien lo reportó); nunca B
  PERFORM set_config('app.user_id', edit::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  INSERT INTO hallazgos (id, org_id, descripcion, severidad) VALUES (h1, org_a, 'Salida bloqueada', 'critico'),
                                                                    (h2, org_a, 'Algo menor', 'menor');
  SELECT count(*) INTO n FROM skf_push_hallazgo_critico(h1, edit);
  ASSERT n = 2, 'Crítico: dueño y admin reciben: ' || n;
  SELECT string_agg(endpoint, ',' ORDER BY endpoint) INTO t FROM skf_push_hallazgo_critico(h1, admin);
  ASSERT t = 'https://push.example/d', 'Quien lo reportó no se avisa a sí mismo';
  SELECT count(*) INTO n FROM skf_push_hallazgo_critico(h2, NULL);
  ASSERT n = 0, 'Un hallazgo menor no avisa';
  INSERT INTO hallazgos (id, org_id, descripcion, severidad) VALUES (h3, org_a, 'Viejo', 'critico');
  UPDATE hallazgos SET creado_en = NOW() - INTERVAL '1 hour' WHERE id = h3;
  SELECT count(*) INTO n FROM skf_push_hallazgo_critico(h3, NULL);
  ASSERT n = 0, 'Un hallazgo viejo no sirve para listar celulares';

  -- 3 · encargo → la persona encargada, si es de esa empresa
  PERFORM set_config('app.user_id', dueno::text, true);
  INSERT INTO plantillas (id, org_id, nombre, campos) VALUES ('a7d00000-0000-0000-0000-000000000001', org_a, 'Ronda', '[]');
  INSERT INTO asignaciones (id, org_id, plantilla_id, plantilla_nombre, nombre, correo)
    VALUES (asg, org_a, 'a7d00000-0000-0000-0000-000000000001', 'Ronda', 'Edgar', 'E@PUSH-A.CO');
  SELECT string_agg(endpoint, ',') INTO t FROM skf_push_encargo(asg);
  ASSERT t = 'https://push.example/e', 'El encargo avisa a quien se le encargó (correo sin importar mayúsculas)';
  UPDATE asignaciones SET correo = 'x@push-b.co' WHERE id = asg;
  SELECT count(*) INTO n FROM skf_push_encargo(asg);
  ASSERT n = 0, 'Alguien de otra empresa no recibe encargos de esta';

  -- 4 · resultados: baja del navegador borra; 5 fallos seguidos borran
  PERFORM skf_push_resultado('https://push.example/x', false, true);
  PERFORM skf_push_resultado('https://push.example/a', false, false);
  PERFORM skf_push_resultado('https://push.example/a', false, false);
  PERFORM skf_push_resultado('https://push.example/a', false, false);
  PERFORM skf_push_resultado('https://push.example/a', false, false);
  PERFORM set_config('app.user_id', admin::text, true);
  SELECT fallos INTO n FROM push_suscripciones;
  ASSERT n = 4, 'Cuatro fallos: sigue';
  PERFORM skf_push_resultado('https://push.example/a', false, false);
  SELECT count(*) INTO n FROM push_suscripciones;
  ASSERT n = 0, 'Quinto fallo: se borra';
  PERFORM set_config('app.user_id', ajeno::text, true);
  SELECT count(*) INTO n FROM push_suscripciones;
  ASSERT n = 0, 'Baja del navegador: se borra';

  -- 5 · el mismo celular con otra cuenta pasa a ser de esa cuenta
  PERFORM set_config('app.user_id', edit::text, true);
  PERFORM skf_push_suscribir('https://push.example/d', k, au, 'ahora de Edgar');
  SELECT count(*) INTO n FROM push_suscripciones;
  ASSERT n = 2, 'Edgar ve su celular de siempre y el que heredó';
END $$;

ROLLBACK;
\echo 'OK: push (cada quien sus celulares, a quién se avisa, bajas y fallos)'
