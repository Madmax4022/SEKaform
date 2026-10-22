-- ═══════════════════════════════════════════════════════════════════════════
--  Asesores con varias empresas (migración 010)
--
--  Se corre como skf_app (sujeto a RLS). Todo dentro de una transacción que se
--  revierte, así que no deja rastro.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_x UUID := 'c1111111-1111-1111-1111-111111111111';   -- empresa de otro, sin el asesor
  asesor UUID := 'ca000000-0000-0000-0000-0000000000a5';
  normal UUID := 'ca000000-0000-0000-0000-00000000000e';
  dueno_x UUID := 'ca000000-0000-0000-0000-00000000000d';
  super UUID := 'c5555555-0000-0000-0000-000000000000';
  r RECORD; t TEXT; n INTEGER; e1 UUID; e2 UUID;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_x, 'Empresa ajena');
  INSERT INTO users (id, email, is_super_admin, es_asesor) VALUES
    (asesor, 'asesor@sst.co', false, true), (normal, 'normal@sst.co', false, false),
    (dueno_x, 'dueno@ajena.co', false, false), (super, 'super@sst.co', true, false);
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_x, dueno_x, 'dueno'), (org_x, normal, 'editor');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- 1 · un usuario normal no crea empresas
  PERFORM set_config('app.user_id', normal::text, true);
  SELECT * INTO r FROM skf_asesor_crear_empresa('Mi empresa nueva', 'CO');
  ASSERT r.resultado = 'sin_permiso', 'Un usuario que no es asesor no crea empresas';

  -- 2 · el asesor crea dos clientes y queda como admin
  PERFORM set_config('app.user_id', asesor::text, true);
  SELECT * INTO r FROM skf_asesor_crear_empresa('  Panadería La Espiga ', 'CO');
  ASSERT r.resultado = 'ok', 'El asesor crea su empresa cliente';
  e1 := r.org_id;
  SELECT * INTO r FROM skf_asesor_crear_empresa('Taller El Pistón', 'PA'); e2 := r.org_id;
  SELECT * INTO r FROM skf_asesor_crear_empresa('x', 'CO');
  ASSERT r.resultado = 'nombre_invalido', 'Nombre demasiado corto';
  SELECT count(*) INTO n FROM skf_mis_empresas();
  ASSERT n = 2, 'El asesor ve sus 2 empresas (no la ajena): ' || n;
  SELECT rol INTO t FROM skf_mis_empresas() WHERE org_id = e1;
  ASSERT t = 'admin', 'Entra como admin, no como dueño';
  SELECT nombre INTO t FROM skf_mis_empresas() WHERE org_id = e1;
  ASSERT t = 'Panadería La Espiga', 'El nombre se guarda sin espacios sobrantes';

  -- 3 · perfil en una empresa: solo si es miembro
  SELECT * INTO r FROM skf_auth_perfil_en(asesor, e2);
  ASSERT r.org_id = e2 AND r.rol = 'admin' AND r.es_asesor AND r.n_empresas = 2, 'Perfil en la empresa elegida';
  SELECT * INTO r FROM skf_auth_perfil_en(asesor, org_x);
  ASSERT r.org_id IS NULL AND r.rol IS NULL, 'Elegir una empresa ajena NO da acceso';
  SELECT * INTO r FROM skf_auth_perfil_en(asesor, NULL);
  ASSERT r.org_id = e1, 'Sin preferencia: la primera membresía';

  -- 4 · resumen: solo sus empresas; los datos de otra no aparecen
  SELECT count(*) INTO n FROM skf_asesor_resumen();
  ASSERT n = 2, 'El resumen trae solo sus empresas';
  SELECT tiene_dueno INTO r FROM skf_asesor_resumen() WHERE org_id = e1;
  ASSERT r.tiene_dueno = false, 'Empresa recién creada: aún sin dueño';

  -- 5 · en su cliente, el asesor invita al cliente como «dueño» (una sola vez)
  PERFORM set_config('app.org_id', e1::text, true);
  SELECT * INTO r FROM skf_equipo_invitar('gerente@espiga.co', 'dueno', 14);
  ASSERT r.resultado = 'ok', 'El asesor invita al cliente como dueño';
  SELECT * INTO r FROM skf_equipo_invitar('otro@espiga.co', 'dueno', 14);
  ASSERT r.resultado = 'rol_invalido', 'No dos invitaciones de dueño a la vez';
  SELECT * INTO r FROM skf_equipo_invitar('gerente@espiga.co', 'dueno', 7);
  ASSERT r.resultado = 'renovada', 'Reenviar la misma invitación de dueño sí se puede';

  -- 6 · un admin que NO es asesor no puede invitar dueños
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO memberships (org_id, user_id, rol) VALUES (e2, normal, 'admin');
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.user_id', normal::text, true);
  PERFORM set_config('app.org_id', e2::text, true);
  SELECT * INTO r FROM skf_equipo_invitar('jefe@piston.co', 'dueno', 14);
  ASSERT r.resultado = 'rol_invalido', 'Solo un asesor invita dueños';

  -- 7 · agregar a alguien que YA tiene cuenta
  ASSERT skf_equipo_agregar_existente('dueno@ajena.co', 'editor') = 'ok', 'Un admin agrega a alguien con cuenta';
  ASSERT skf_equipo_agregar_existente('dueno@ajena.co', 'editor') = 'ya_miembro', 'No dos veces';
  ASSERT skf_equipo_agregar_existente('nadie@ninguno.co', 'editor') = 'no_disponible', 'Correo sin cuenta';
  ASSERT skf_equipo_agregar_existente('asesor@sst.co', 'editor') = 'ya_miembro', 'El asesor ya está';
  ASSERT skf_equipo_agregar_existente('super@sst.co', 'admin') = 'solo_dueno', 'Un admin común no agrega administradores';
  ASSERT skf_equipo_agregar_existente('super@sst.co', 'dueno') = 'rol_invalido', 'Nadie agrega dueños por esta vía';

  -- 8 · desde una empresa ajena (org_id falso en el contexto) no se crea ni se agrega nada
  PERFORM set_config('app.user_id', asesor::text, true);
  PERFORM set_config('app.org_id', org_x::text, true);
  ASSERT skf_equipo_agregar_existente('normal@sst.co', 'editor') = 'sin_permiso', 'Con el org_id de otra empresa no hay permiso';
  SELECT * INTO r FROM skf_equipo_invitar('cuela@ajena.co', 'dueno', 14);
  ASSERT r.resultado = 'sin_permiso', 'Ni invitar en ella';

  -- 8b · los datos NO se cruzan entre empresas del mismo asesor: solo la empresa activa
  PERFORM set_config('app.user_id', asesor::text, true);
  PERFORM set_config('app.org_id', e1::text, true);
  INSERT INTO plantillas (id, org_id, nombre, campos) VALUES ('cb000000-0000-0000-0000-0000000000f1', e1, 'Solo de Espiga', '[]');
  SELECT count(*) INTO n FROM plantillas WHERE id = 'cb000000-0000-0000-0000-0000000000f1';
  ASSERT n = 1, 'En su empresa activa la ve';
  PERFORM set_config('app.org_id', e2::text, true);
  SELECT count(*) INTO n FROM plantillas WHERE id = 'cb000000-0000-0000-0000-0000000000f1';
  ASSERT n = 0, 'Con OTRA empresa activa no la ve, aunque sea miembro de ambas';
  BEGIN
    INSERT INTO plantillas (id, org_id, nombre, campos) VALUES ('cb000000-0000-0000-0000-0000000000f2', e1, 'Colada', '[]');
    ASSERT false, 'No debe poder escribir en una empresa que no es la activa';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  UPDATE plantillas SET nombre = 'Cambiada' WHERE id = 'cb000000-0000-0000-0000-0000000000f1';
  GET DIAGNOSTICS n = ROW_COUNT;
  ASSERT n = 0, 'Ni modificar datos de la otra empresa';

  -- 9 · el cliente (dueño) puede quitar al asesor: la empresa es suya
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO users (id, email) VALUES ('ca000000-0000-0000-0000-0000000000c1', 'gerente2@espiga.co');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (e1, 'ca000000-0000-0000-0000-0000000000c1', 'dueno');
  PERFORM set_config('app.is_super_admin', 'off', true);
  PERFORM set_config('app.user_id', 'ca000000-0000-0000-0000-0000000000c1', true);
  PERFORM set_config('app.org_id', e1::text, true);
  ASSERT skf_equipo_quitar(asesor) = 'ok', 'El dueño de la empresa puede quitar al asesor';
  PERFORM set_config('app.user_id', asesor::text, true);
  SELECT count(*) INTO n FROM skf_mis_empresas();
  ASSERT n = 1, 'El asesor ya no ve esa empresa';
END $$;

ROLLBACK;
\echo 'OK: asesores (crear clientes, empresa activa validada, dueño del cliente)'
