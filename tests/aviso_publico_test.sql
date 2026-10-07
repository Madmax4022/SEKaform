-- ═══════════════════════════════════════════════════════════════════════════
--  Aviso por puntaje bajo en formularios públicos (migración 007)
--
--  Se corre como skf_app (sujeto a RLS) dentro de una transacción que se revierte.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := '91111111-1111-1111-1111-111111111111';
  org_b UUID := '92222222-2222-2222-2222-222222222222';
  super UUID := '95555555-0000-0000-0000-000000000000';
  pl_a  UUID := '9a000000-0000-0000-0000-000000000001';
  pl_b  UUID := '9b000000-0000-0000-0000-000000000001';
  pl_priv UUID := '9c000000-0000-0000-0000-000000000001';
  e1 UUID := '9e000000-0000-0000-0000-000000000001';
  e2 UUID := '9e000000-0000-0000-0000-000000000002';
  e3 UUID := '9e000000-0000-0000-0000-000000000003';
  e4 UUID := '9e000000-0000-0000-0000-000000000004';
  e5 UUID := '9e000000-0000-0000-0000-000000000005';
  e_int UUID := '9e000000-0000-0000-0000-0000000000a1';
  d RECORD; ok BOOLEAN; n INTEGER;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Aviso A'), (org_b, 'Aviso B');
  INSERT INTO users (id, email, is_super_admin) VALUES (super, 'super@aviso.com', true);
  INSERT INTO plantillas (id, org_id, nombre, codigo, campos, publica, share_token, correo_notificacion) VALUES
    (pl_a, org_a, 'Lista A', 'A', '[{"id":"s0","tipo":"si_no","etiqueta":"Extintores"}]', true, 'tok-a', 'jefe@a.com'),
    (pl_b, org_b, 'Lista B', 'B', '[{"id":"s0","tipo":"si_no","etiqueta":"Salidas"}]',   true, 'tok-b', 'jefe@b.com'),
    (pl_priv, org_a, 'Privada', 'P', '[]', false, 'tok-priv', 'x@a.com');
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.org_id', '', true);

  -- Sin sesión: se envía por el camino público, como lo hace la API.
  PERFORM skf_publico_envio(e1, 'tok-a', '{"s0":"No"}', 'Ana', NULL, NULL);
  PERFORM skf_publico_envio(e2, 'tok-a', '{"s0":"No"}', 'Beto', NULL, NULL);
  PERFORM skf_publico_envio(e3, 'tok-a', '{"s0":"No"}', 'Cris', NULL, NULL);
  PERFORM skf_publico_envio(e4, 'tok-a', '{"s0":"No"}', 'Dani', NULL, NULL);
  PERFORM skf_publico_envio(e5, 'tok-b', '{"s0":"No"}', 'Eli',  NULL, NULL);

  -- 1 · los datos salen con el token correcto: correo del formulario, campos y respuestas
  SELECT * INTO d FROM skf_publico_aviso_datos(e1, 'tok-a');
  ASSERT d.correo = 'jefe@a.com' AND d.formulario = 'Lista A', 'Debe devolver el formulario y su correo';
  ASSERT d.datos = '{"s0":"No"}'::jsonb AND d.llenado_por = 'Ana', 'Debe devolver las respuestas del envío';
  ASSERT d.ya_avisado = false, 'Aún no se avisó';

  -- 2 · un token ajeno NO ve el envío (aislamiento entre clientes)
  SELECT count(*) INTO n FROM skf_publico_aviso_datos(e1, 'tok-b');
  ASSERT n = 0, 'El token de otro formulario no debe ver este envío';
  SELECT count(*) INTO n FROM skf_publico_aviso_datos(e1, 'token-inventado');
  ASSERT n = 0, 'Un token inventado no debe devolver nada';
  ok := skf_publico_aviso_marcar(e1, 'tok-b', 5);
  ASSERT ok = false, 'No se puede reservar un aviso con el token de otro formulario';

  -- 3 · la primera reserva autoriza el envío; repetirla (reintento de la cola) NO
  ok := skf_publico_aviso_marcar(e1, 'tok-a', 3);
  ASSERT ok = true, 'La primera reserva debe autorizar el correo';
  ok := skf_publico_aviso_marcar(e1, 'tok-a', 3);
  ASSERT ok = false, 'Un reintento del mismo envío NO debe avisar otra vez';
  SELECT * INTO d FROM skf_publico_aviso_datos(e1, 'tok-a');
  ASSERT d.ya_avisado = true, 'Debe constar que ya se avisó';

  -- 4 · límite por hora: con p_max = 3, el cuarto envío del mismo formulario se omite
  ok := skf_publico_aviso_marcar(e2, 'tok-a', 3); ASSERT ok = true,  'Segundo aviso permitido';
  ok := skf_publico_aviso_marcar(e3, 'tok-a', 3); ASSERT ok = true,  'Tercer aviso permitido';
  ok := skf_publico_aviso_marcar(e4, 'tok-a', 3); ASSERT ok = false, 'El cuarto aviso en la hora debe omitirse';
  -- ...y esa omisión queda registrada: reintentar el cuarto NO lo envía más tarde
  SELECT * INTO d FROM skf_publico_aviso_datos(e4, 'tok-a');
  ASSERT d.ya_avisado = true, 'La omisión debe quedar registrada (ya_avisado)';
  ok := skf_publico_aviso_marcar(e4, 'tok-a', 99);
  ASSERT ok = false, 'Un envío omitido por el límite no debe enviarse después, aunque el límite suba';

  -- 5 · el límite es POR formulario: otro cliente no se ve afectado
  ok := skf_publico_aviso_marcar(e5, 'tok-b', 3);
  ASSERT ok = true, 'El límite de un formulario no debe afectar a otro';

  -- 6 · formulario ya no público: no se avisa
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  UPDATE plantillas SET publica = false WHERE id = pl_a;
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.user_id', '', true);
  SELECT count(*) INTO n FROM skf_publico_aviso_datos(e2, 'tok-a');
  ASSERT n = 0, 'Un formulario que dejó de ser público no debe exponer datos';

  -- 7 · la tabla está cerrada a la app: sin policies, nada se ve ni se escribe directo
  SELECT count(*) INTO n FROM avisos_puntaje;
  ASSERT n = 0, 'avisos_puntaje no debe ser legible directamente por la app';
  BEGIN
    INSERT INTO avisos_puntaje (envio_id, plantilla_id, org_id, enviado) VALUES (e5, pl_b, org_b, true);
    ASSERT false, 'La app no debe poder escribir directo en avisos_puntaje';
  EXCEPTION WHEN insufficient_privilege OR check_violation OR unique_violation THEN NULL;
  END;
END $$;

ROLLBACK;
\echo 'OK: aviso público (límite por hora, sin duplicados, aislado por token)'
