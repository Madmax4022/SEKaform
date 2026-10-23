-- ═══════════════════════════════════════════════════════════════════════════
--  Pruebas por QR (migración 016): el código es el permiso, con límites
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  super UUID := 'a9555555-0000-0000-0000-000000000000';
  r RECORD; n INTEGER; u RECORD; h TIMESTAMPTZ;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO users (id, email, is_super_admin) VALUES (super, 's@pruebas.co', true);
  INSERT INTO campanas_prueba (codigo, nombre, dias, max_usos) VALUES ('CODIGOprueba1', 'Congreso SST', 30, 2),
                                                                     ('CODIGOpausada', 'Pausada', 30, 5);
  UPDATE campanas_prueba SET activa = false WHERE codigo = 'CODIGOpausada';
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.user_id', '', true);

  -- 1 · sin sesión: la página pública ve nombre y días, nunca cuántos usos quedan
  SELECT * INTO r FROM skf_prueba_info('CODIGOprueba1');
  ASSERT r.nombre = 'Congreso SST' AND r.dias = 30 AND r.disponible, 'Info pública de la campaña';
  SELECT count(*) INTO n FROM skf_prueba_info('NOEXISTE1234');
  ASSERT n = 0, 'Código inventado: nada';

  -- 2 · registro: asesor, con prueba de 30 días y su registro de contacto
  SELECT * INTO r FROM skf_prueba_registrar('CODIGOprueba1', 'ana@sst.co', 'Clave-segura-1', 'Ana SST', '3001234567', 'Asesor o consultor SST');
  ASSERT r.resultado = 'ok', 'Registro con código válido';
  h := skf_prueba_estado(r.user_id);
  ASSERT h > NOW() + INTERVAL '29 days' AND h < NOW() + INTERVAL '31 days', 'Prueba de 30 días';
  SELECT * INTO u FROM skf_auth_login('ana@sst.co', 'Clave-segura-1', 5, 15);
  ASSERT u.resultado = 'ok', 'Puede iniciar sesión con la contraseña elegida';
  SELECT * INTO r FROM skf_prueba_registrar('CODIGOprueba1', 'ANA@sst.co', 'Clave-segura-1', 'Otra', NULL, NULL);
  ASSERT r.resultado = 'ya_existe', 'El mismo correo no crea dos cuentas';
  SELECT * INTO r FROM skf_prueba_registrar('CODIGOpausada', 'beto@sst.co', 'Clave-segura-1', 'Beto', NULL, NULL);
  ASSERT r.resultado = 'campana_no_disponible', 'Campaña pausada: no';
  SELECT * INTO r FROM skf_prueba_registrar('CODIGOprueba1', 'caro@sst.co', 'Clave-segura-1', 'Caro', NULL, NULL);
  ASSERT r.resultado = 'ok', 'Segunda cuenta (máximo 2)';
  SELECT * INTO r FROM skf_prueba_registrar('CODIGOprueba1', 'dani@sst.co', 'Clave-segura-1', 'Dani', NULL, NULL);
  ASSERT r.resultado = 'campana_no_disponible', 'Llegó al máximo de cuentas';
  SELECT disponible INTO r FROM skf_prueba_info('CODIGOprueba1');
  ASSERT NOT r.disponible, 'Ya no aparece disponible';

  -- 3 · la app (sin super) no ve campañas ni registros
  PERFORM set_config('app.user_id', (SELECT id::text FROM users WHERE email = 'ana@sst.co'), true);
  SELECT count(*) INTO n FROM campanas_prueba;
  ASSERT n = 0, 'Un usuario no ve las campañas';
  SELECT count(*) INTO n FROM skf_pruebas_registros();
  ASSERT n = 0, 'Ni los registros de contacto';
  BEGIN
    INSERT INTO campanas_prueba (codigo, nombre) VALUES ('CODIGOcolado1', 'Colada');
    ASSERT false, 'Ni crea campañas';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 4 · el super administrador sí ve quién se registró
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  SELECT count(*) INTO n FROM skf_pruebas_registros();
  ASSERT n = 2, 'El super ve los 2 registros';
  SELECT * INTO r FROM skf_pruebas_registros() WHERE email = 'ana@sst.co';
  ASSERT r.celular = '3001234567' AND r.profesion = 'Asesor o consultor SST' AND r.campana = 'Congreso SST', 'Con su contacto y campaña';
END $$;

ROLLBACK;
\echo 'OK: pruebas por QR (código con límites, asesor con días, contacto solo para el super)'
