-- ═══════════════════════════════════════════════════════════════════════════
--  Control de trabajos (migración 017): quién ve y quién decide, y aislamiento
--  por empresa. Se corre como skf_app (sujeto a RLS), en una transacción que se
--  revierte.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'e1111111-1111-1111-1111-111111111111';
  org_b UUID := 'e2222222-2222-2222-2222-222222222222';
  admin_a UUID := 'ea000000-0000-0000-0000-00000000000a';
  enc_a   UUID := 'ea000000-0000-0000-0000-00000000000e';   -- editor, encargado de Plaza
  otro_a  UUID := 'ea000000-0000-0000-0000-00000000000f';   -- editor, sin edificio
  admin_b UUID := 'eb000000-0000-0000-0000-00000000000a';
  super   UUID := 'e5555555-0000-0000-0000-000000000000';
  plaza   UUID := 'e1000000-0000-0000-0000-000000000001';
  bodega  UUID := 'e1000000-0000-0000-0000-000000000002';
  tok TEXT := 'enlace-de-prueba-0123456789abcdef';
  n INTEGER; t UUID; r RECORD; j JSONB;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Trabajos A'), (org_b, 'Trabajos B');
  INSERT INTO users (id, email) VALUES (admin_a, 'adm@trab-a.co'), (enc_a, 'enc@trab-a.co'), (otro_a, 'otro@trab-a.co'),
                                       (admin_b, 'adm@trab-b.co'), (super, 'super@trab.co');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, admin_a, 'admin'), (org_a, enc_a, 'editor'),
                                                        (org_a, otro_a, 'editor'), (org_b, admin_b, 'admin');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- 1 · el administrador arma el edificio: lugares, comité y enlace
  PERFORM set_config('app.user_id', admin_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  INSERT INTO unidades (id, org_id, nombre, tipo) VALUES (plaza, org_a, 'Plaza', 'sede'), (bodega, org_a, 'Bodega', 'sede');
  UPDATE unidades SET token_solicitud = tok WHERE id = plaza;
  INSERT INTO unidad_encargados (unidad_id, user_id, org_id) VALUES (plaza, enc_a, org_a);

  -- 2 · solicitud por enlace: el edificio y la empresa salen del token; folio por edificio
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.org_id', '', true);
  SELECT count(*) INTO n FROM skf_solicitud_info('no-existe-0000000000000000000000');
  ASSERT n = 0, 'Un enlace inventado no revela nada';
  SELECT * INTO r FROM skf_solicitud_crear(tok, 'Cambio de luminarias', 'alturas', 'critico', 'personal_local', 'Local 214', 'Mezanine', NULL, CURRENT_DATE, 'Ana', 'Luis');
  ASSERT r.resultado = 'ok' AND r.numero = 1, 'La primera solicitud del edificio es la número 1';
  SELECT * INTO r FROM skf_solicitud_crear(tok, 'Pintura de fachada', 'general', 'medio', 'contratista', 'Pinturas SA', NULL, NULL, CURRENT_DATE, 'Eva', 'Raúl');
  ASSERT r.numero = 2, 'El folio avanza dentro del edificio';
  j := skf_trabajo_publico(r.token);
  ASSERT j->>'estado' = 'pendiente' AND j ? 'unidad' AND NOT j ? 'contacto' AND NOT j ? 'requisitos', 'Portería ve el estado, no el detalle';
  SELECT count(*) INTO n FROM trabajos;
  ASSERT n = 0, 'El anónimo no lee la tabla';
  SELECT resultado INTO r FROM skf_solicitud_crear('no-existe-0000000000000000000000', 'X y Z', 'general', 'medio', 'propio', 'Yo', NULL, NULL, CURRENT_DATE, 'A', 'B');
  ASSERT r.resultado = 'no_existe', 'Sin enlace válido no hay solicitud';

  -- 3 · el encargado ve y decide en su edificio
  PERFORM set_config('app.user_id', enc_a::text, true);
  PERFORM set_config('app.org_id', org_a::text, true);
  SELECT count(*) INTO n FROM trabajos;
  ASSERT n = 2, 'El encargado ve la cola de su edificio';
  UPDATE trabajos SET estado = 'autorizado' WHERE titulo = 'Pintura de fachada';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'El encargado decide en su edificio';
  BEGIN
    INSERT INTO trabajos (org_id, unidad_id, token, titulo, tipo, criticidad, origen, quien, fecha)
    VALUES (org_a, bodega, 'token-ajeno-000000000000000000', 'En edificio ajeno', 'general', 'medio', 'propio', 'Yo', CURRENT_DATE);
    ASSERT false, 'El encargado no abre trabajos en un edificio que no es suyo';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  DELETE FROM trabajos;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Un trabajo no se borra';
  BEGIN
    INSERT INTO unidad_encargados (unidad_id, user_id, org_id) VALUES (bodega, enc_a, org_a);
    ASSERT false, 'El encargado no se nombra a sí mismo en otro edificio';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 4 · otro editor de la misma empresa, sin edificio: ni ve ni decide
  PERFORM set_config('app.user_id', otro_a::text, true);
  SELECT count(*) INTO n FROM trabajos;
  ASSERT n = 0, 'Sin edificio a cargo no se ve la cola';
  UPDATE trabajos SET estado = 'rechazado';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Ni se decide';

  -- 5 · el administrador ve todo, pero solo decide con el relevo tomado
  PERFORM set_config('app.user_id', admin_a::text, true);
  SELECT count(*) INTO n FROM trabajos;
  ASSERT n = 2, 'El administrador ve todos los edificios';
  UPDATE trabajos SET estado = 'rechazado' WHERE titulo = 'Cambio de luminarias';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Sin relevo, el administrador no decide';
  UPDATE unidades SET relevo_por = admin_a, relevo_desde = NOW() WHERE id = plaza;
  UPDATE trabajos SET estado = 'rechazado', motivo = 'Sin arnés' WHERE titulo = 'Cambio de luminarias';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 1, 'Con el relevo tomado, decide';
  UPDATE unidades SET relevo_por = NULL WHERE id = plaza;
  UPDATE trabajos SET estado = 'pendiente' WHERE titulo = 'Cambio de luminarias';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Al devolver el relevo deja de decidir';

  -- 6 · quien dejó de ser miembro pierde el edificio aunque siga en la lista de encargados
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  DELETE FROM memberships WHERE org_id = org_a AND user_id = enc_a;
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.user_id', enc_a::text, true);
  SELECT count(*) INTO n FROM trabajos;
  ASSERT n = 0, 'Un ex miembro ya no ve la cola';

  -- 7 · otra empresa: no ve, no decide, no nombra, no toma el relevo
  PERFORM set_config('app.user_id', admin_b::text, true);
  PERFORM set_config('app.org_id', org_b::text, true);
  SELECT count(*) INTO n FROM trabajos;
  ASSERT n = 0, 'B no ve los trabajos de A';
  SELECT count(*) INTO n FROM unidad_encargados;
  ASSERT n = 0, 'B no ve el comité de A';
  UPDATE unidades SET relevo_por = admin_b WHERE id = plaza;
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'B no toma el relevo de un edificio de A';
  BEGIN
    INSERT INTO unidad_encargados (unidad_id, user_id, org_id) VALUES (plaza, admin_b, org_a);
    ASSERT false, 'B no se nombra encargado en A';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

ROLLBACK;
\echo 'OK: control de trabajos (comité decide, relevo explícito, folio por edificio, aislado por empresa)'
