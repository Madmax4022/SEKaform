\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE r RECORD; t TEXT; n INT;
BEGIN
  PERFORM set_config('app.is_super_admin','on',true);

  -- Autorizar a alguien que aún NO existe
  t := skf_autorizar_super_admin('nuevo.super@kanansentinel.com');
  ASSERT t = 'autorizado', format('esperaba autorizado, obtuve %s', t);

  -- Al registrarse debe quedar super admin SOLO (sin segundo paso)
  SELECT * INTO r FROM skf_auth_registrar('nuevo.super@kanansentinel.com','ClaveLarga123!','Nuevo');
  ASSERT r.resultado = 'ok', format('registro fallo: %s', r.resultado);

  SELECT count(*) INTO n FROM users WHERE email='nuevo.super@kanansentinel.com' AND is_super_admin;
  ASSERT n = 1, 'FALLO: no quedo como super admin tras registrarse';

  -- Un usuario normal NO debe quedar super admin
  INSERT INTO authorized_emails (email, rol_inicial, is_active) VALUES ('normal@x.com','editor',true);
  SELECT * INTO r FROM skf_auth_registrar('normal@x.com','ClaveLarga123!','Normal');
  SELECT count(*) INTO n FROM users WHERE email='normal@x.com' AND is_super_admin;
  ASSERT n = 0, 'FUGA: un usuario normal quedo como super admin';

  -- Promover a alguien que YA existe
  t := skf_autorizar_super_admin('normal@x.com');
  ASSERT t = 'promovido', format('esperaba promovido, obtuve %s', t);
  SELECT count(*) INTO n FROM users WHERE email='normal@x.com' AND is_super_admin;
  ASSERT n = 1, 'FALLO: no se promovio la cuenta existente';

  RAISE NOTICE 'SUPERADMIN OK — 4 escenarios verificados';
END $$;
ROLLBACK;
