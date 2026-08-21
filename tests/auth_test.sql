-- ═══════════════════════════════════════════════════════════════════════════
--  Pruebas del flujo de autenticación (migrations/002_auth_functions.sql)
--
--  Se corre como skf_app, que es como corre la aplicación de verdad: sin
--  permiso de lectura sobre users ni authorized_emails. Si alguna función
--  necesitara más privilegios de los que tiene, aquí se caería.
--
--    psql -U skf_app -d skf -v ON_ERROR_STOP=1 -f tests/auth_test.sql
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  org   UUID := '33333333-3333-3333-3333-333333333333';
  super UUID := '44444444-4444-4444-4444-444444444444';
  r     RECORD;
  t     TEXT;
  n     INTEGER;
  tok   TEXT := encode(digest('token-de-prueba', 'sha256'), 'hex');
BEGIN
  -- Montaje mínimo como super admin.
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org, 'Cliente Prueba');
  INSERT INTO users (id, email, is_super_admin) VALUES (super, 'super@kanansentinel.com', true);

  -- ══ 1 · Sin autorizacion no hay registro ═════════════════════════════
  ASSERT NOT skf_auth_puede_registrarse('nadie@ejemplo.com'),
    'Un correo sin autorizar no deberia poder registrarse';

  SELECT * INTO r FROM skf_auth_registrar('nadie@ejemplo.com', 'Clave123!', 'Nadie');
  ASSERT r.resultado = 'no_autorizado',
    format('Se esperaba no_autorizado, se obtuvo %s', r.resultado);

  SELECT count(*) INTO n FROM users WHERE email = 'nadie@ejemplo.com';
  ASSERT n = 0, 'FUGA: se creo un usuario sin autorizacion';

  -- ══ 2 · El super admin autoriza y entonces si ════════════════════════
  INSERT INTO authorized_emails (email, org_id, rol_inicial, autorizado_por)
    VALUES ('inspector@cliente.com', org, 'editor', super);

  ASSERT skf_auth_puede_registrarse('inspector@cliente.com'),
    'Un correo autorizado deberia poder registrarse';

  SELECT * INTO r FROM skf_auth_registrar('inspector@cliente.com', 'Clave123!', 'Inspector');
  ASSERT r.resultado = 'ok', format('El registro fallo: %s', r.resultado);
  ASSERT r.org_id = org, 'El usuario no quedo en la organizacion correcta';

  SELECT count(*) INTO n FROM memberships WHERE user_id = r.user_id AND rol = 'editor';
  ASSERT n = 1, 'No se creo la membresia con el rol de la invitacion';

  -- ══ 3 · La invitacion se consume (no es reutilizable) ════════════════
  ASSERT NOT skf_auth_puede_registrarse('inspector@cliente.com'),
    'La invitacion deberia quedar consumida tras el registro';

  -- ══ 4 · Login correcto ═══════════════════════════════════════════════
  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'Clave123!');
  ASSERT r.resultado = 'ok', format('El login valido fallo: %s', r.resultado);
  ASSERT r.user_id IS NOT NULL, 'El login correcto no devolvio user_id';
  ASSERT NOT r.es_super, 'Un inspector no deberia salir como super admin';

  -- ══ 5 · Login incorrecto no revela nada ══════════════════════════════
  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'incorrecta');
  ASSERT r.resultado = 'credenciales', 'Se esperaba fallo de credenciales';
  ASSERT r.user_id IS NULL, 'FUGA: un login fallido devolvio user_id';

  -- Un correo inexistente responde igual que una clave mala.
  SELECT * INTO r FROM skf_auth_login('fantasma@ejemplo.com', 'lo-que-sea');
  ASSERT r.resultado = 'credenciales',
    'Un correo inexistente debe responder igual que una clave incorrecta';

  -- ══ 6 · Bloqueo por fuerza bruta ═════════════════════════════════════
  -- Van 1 fallo; con max=5 hacen falta 4 mas para bloquear.
  FOR n IN 1..4 LOOP
    PERFORM skf_auth_login('inspector@cliente.com', 'incorrecta', 5, 15);
  END LOOP;

  -- Ahora ni siquiera la clave correcta entra.
  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'Clave123!', 5, 15);
  ASSERT r.resultado = 'bloqueado',
    format('La cuenta deberia estar bloqueada, se obtuvo %s', r.resultado);
  ASSERT r.bloqueado_hasta > NOW(), 'El bloqueo deberia tener vencimiento futuro';

  -- ══ 7 · Restablecer contrasena limpia el bloqueo ═════════════════════
  ASSERT skf_auth_crear_token('inspector@cliente.com', tok, 60),
    'No se pudo crear el token de restablecimiento';

  t := skf_auth_consumir_token(tok, 'NuevaClave456!');
  ASSERT t = 'ok', format('El consumo del token fallo: %s', t);

  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'NuevaClave456!');
  ASSERT r.resultado = 'ok',
    format('Deberia entrar con la clave nueva y sin bloqueo, se obtuvo %s', r.resultado);

  -- La clave vieja ya no sirve.
  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'Clave123!');
  ASSERT r.resultado = 'credenciales', 'La contrasena anterior deberia haber dejado de servir';

  -- ══ 8 · El token no se reutiliza ═════════════════════════════════════
  t := skf_auth_consumir_token(tok, 'OtraMas789!');
  ASSERT t = 'usado', format('Un token ya usado deberia rechazarse, se obtuvo %s', t);

  t := skf_auth_consumir_token('token-que-no-existe', 'OtraMas789!');
  ASSERT t = 'invalido', 'Un token inexistente deberia rechazarse';

  -- ══ 9 · Un correo sin cuenta no se delata al pedir restablecer ═══════
  ASSERT NOT skf_auth_crear_token('fantasma@ejemplo.com', 'hash-cualquiera', 60),
    'No deberia crearse token para un correo sin cuenta';

  -- ══ 10 · Cambio de contrasena exige la actual ════════════════════════
  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'NuevaClave456!');
  t := skf_auth_cambiar_password(r.user_id, 'la-que-no-es', 'Intento999!');
  ASSERT t = 'credenciales', 'Deberia exigir la contrasena actual correcta';

  t := skf_auth_cambiar_password(r.user_id, 'NuevaClave456!', 'Final000!');
  ASSERT t = 'ok', format('El cambio de contrasena fallo: %s', t);

  -- ══ 11 · La app NO puede leer las tablas de credenciales ═════════════
  -- Es el complemento de todo lo anterior: aunque una inyeccion SQL lograra
  -- ejecutar un SELECT arbitrario, no hay hashes que llevarse.
  BEGIN
    SELECT count(*) INTO n FROM password_reset_tokens;
    ASSERT n = 0, 'FUGA: la app pudo leer password_reset_tokens';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  -- ══ 12 · Rehidratar la sesion en cada peticion ═══════════════════════
  -- Flask-Login reconstruye el usuario desde la cookie ANTES de que exista
  -- contexto de RLS. Si esto devuelve vacio, nadie puede iniciar sesion:
  -- exactamente el fallo que se colo la primera vez.
  SELECT * INTO r FROM skf_auth_login('inspector@cliente.com', 'Final000!');
  ASSERT r.resultado = 'ok', 'Precondicion: el login deberia funcionar aqui';

  DECLARE p RECORD;
  BEGIN
    SELECT * INTO p FROM skf_auth_perfil(r.user_id);
    ASSERT p.id IS NOT NULL,
      'skf_auth_perfil no devolvio nada: la sesion no se puede rehidratar';
    ASSERT p.email = 'inspector@cliente.com', 'Perfil con el correo equivocado';
    ASSERT p.is_active, 'El perfil deberia venir activo';
    ASSERT p.org_id = org, 'El perfil no trae la organizacion del usuario';
    ASSERT p.rol = 'editor', format('Rol esperado editor, se obtuvo %s', p.rol);
    ASSERT NOT p.es_super, 'Un inspector no deberia venir como super admin';
  END;

  RAISE NOTICE 'AUTH OK — 12 escenarios verificados';
END $$;

ROLLBACK;
