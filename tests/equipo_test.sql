-- ═══════════════════════════════════════════════════════════════════════════
--  Equipo (migración 009): la empresa administra su gente, sin salirse de ella
--
--  Se corre como skf_app (sujeto a RLS). Todo dentro de una transacción que se
--  revierte, así que no deja rastro.
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  org_a UUID := 'e1111111-1111-1111-1111-111111111111';
  org_b UUID := 'e2222222-2222-2222-2222-222222222222';
  dueno_a UUID := 'ea000000-0000-0000-0000-00000000000d';
  admin_a UUID := 'ea000000-0000-0000-0000-00000000000a';
  admin2_a UUID := 'ea000000-0000-0000-0000-0000000000a2';
  edit_a  UUID := 'ea000000-0000-0000-0000-00000000000e';
  admin_b UUID := 'eb000000-0000-0000-0000-00000000000a';
  super   UUID := 'e5555555-0000-0000-0000-000000000000';
  r RECORD; t TEXT; n INTEGER; inv UUID;
BEGIN
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);
  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Equipo A'), (org_b, 'Equipo B');
  INSERT INTO users (id, email, is_super_admin) VALUES
    (dueno_a, 'dueno@eq-a.com', false), (admin_a, 'admin@eq-a.com', false), (admin2_a, 'admin2@eq-a.com', false),
    (edit_a, 'editor@eq-a.com', false), (admin_b, 'admin@eq-b.com', false), (super, 'super@eq.com', true);
  INSERT INTO memberships (org_id, user_id, rol) VALUES
    (org_a, dueno_a, 'dueno'), (org_a, admin_a, 'admin'), (org_a, admin2_a, 'admin'), (org_a, edit_a, 'editor'),
    (org_b, admin_b, 'admin');
  INSERT INTO authorized_emails (email, org_id, rol_inicial) VALUES ('ajeno@otra.com', org_b, 'editor');
  PERFORM set_config('app.is_super_admin', 'off', true);

  -- ── Como administrador de A ────────────────────────────────────────────
  PERFORM set_config('app.user_id', admin_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);

  SELECT * INTO r FROM skf_equipo_invitar('nuevo@eq-a.com', 'editor', 14);
  ASSERT r.resultado = 'ok', 'Un admin debe poder invitar: ' || r.resultado;
  inv := r.invitacion_id;
  SELECT org_id, rol_inicial INTO r FROM authorized_emails WHERE id = inv;
  -- (ae_sel deja al admin leer las invitaciones de SU organización)
  ASSERT r.org_id = org_a AND r.rol_inicial = 'editor', 'La invitación queda en SU organización';

  SELECT * INTO r FROM skf_equipo_invitar('nuevo@eq-a.com', 'lector', 7);
  ASSERT r.resultado = 'renovada' AND r.invitacion_id = inv, 'Reinvitar el mismo correo renueva, no duplica';

  SELECT resultado INTO t FROM skf_equipo_invitar('otro@eq-a.com', 'dueno');
  ASSERT t = 'rol_invalido', 'Nadie puede invitar a un «dueño»';
  SELECT resultado INTO t FROM skf_equipo_invitar('no-es-correo', 'editor');
  ASSERT t = 'correo_invalido', 'Correo inválido';
  SELECT resultado INTO t FROM skf_equipo_invitar('editor@eq-a.com', 'editor');
  ASSERT t = 'no_disponible', 'Un correo con cuenta no se puede invitar (sin revelar cuál es el caso)';
  SELECT resultado INTO t FROM skf_equipo_invitar('ajeno@otra.com', 'editor');
  ASSERT t = 'no_disponible', 'No se puede «robar» la invitación de otra organización';
  SELECT org_id INTO r FROM authorized_emails WHERE email = 'ajeno@otra.com';
  ASSERT NOT FOUND OR r.org_id = org_b, 'La invitación ajena sigue intacta';

  SELECT count(*) INTO n FROM skf_equipo_listar() WHERE tipo = 'miembro';
  ASSERT n = 4, 'El admin ve los 4 miembros de A (no los de B): ' || n;
  SELECT count(*) INTO n FROM skf_equipo_listar() WHERE tipo = 'invitacion';
  ASSERT n = 1, 'Y su invitación pendiente';

  -- Cambiar permisos y quitar: reglas sobre el dueño, otros admin y uno mismo
  ASSERT skf_equipo_cambiar_rol(edit_a, 'lector') = 'ok', 'Admin cambia a un editor';
  ASSERT (SELECT rol FROM memberships WHERE org_id = org_a AND user_id = edit_a) = 'lector', 'El cambio quedó';
  ASSERT skf_equipo_cambiar_rol(edit_a, 'admin') = 'solo_dueno', 'Solo el dueño nombra administradores';
  ASSERT skf_equipo_cambiar_rol(dueno_a, 'editor') = 'es_dueno', 'Nadie degrada al dueño';
  ASSERT skf_equipo_quitar(dueno_a) = 'es_dueno', 'Nadie quita al dueño';
  ASSERT skf_equipo_cambiar_rol(admin2_a, 'editor') = 'solo_dueno', 'Un admin no toca a otro admin';
  ASSERT skf_equipo_cambiar_rol(admin_a, 'lector') = 'a_ti_mismo', 'Nadie se cambia a sí mismo';
  ASSERT skf_equipo_quitar(admin_a) = 'a_ti_mismo', 'Nadie se quita a sí mismo';
  ASSERT skf_equipo_quitar(admin_b) = 'no_encontrado', 'No se puede tocar a alguien de otra organización';
  ASSERT skf_equipo_cambiar_rol(edit_a, 'dueno') = 'rol_invalido', 'No se asigna «dueño»';

  -- ── Como editor (ahora lector) de A: no administra nada ─────────────────
  PERFORM set_config('app.user_id', edit_a::text, true);
  SELECT resultado INTO t FROM skf_equipo_invitar('x@eq-a.com', 'editor');
  ASSERT t = 'sin_permiso', 'Un no-admin no invita';
  ASSERT skf_equipo_revocar(inv) = 'sin_permiso', 'Un no-admin no revoca';
  ASSERT skf_equipo_cambiar_rol(admin_a, 'editor') = 'sin_permiso', 'Un no-admin no cambia permisos';
  SELECT count(*) INTO n FROM skf_equipo_listar() WHERE tipo = 'invitacion';
  ASSERT n = 0, 'Un no-admin ve el equipo pero no las invitaciones';
  SELECT count(*) INTO n FROM skf_equipo_listar() WHERE tipo = 'miembro';
  ASSERT n = 4, 'Pero sí ve a sus compañeros';

  -- ── Como admin de B: no puede tocar lo de A ─────────────────────────────
  PERFORM set_config('app.user_id', admin_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  ASSERT skf_equipo_revocar(inv) = 'no_encontrada', 'B no revoca invitaciones de A';
  ASSERT skf_equipo_quitar(edit_a) = 'no_encontrado', 'B no quita gente de A';
  SELECT count(*) INTO n FROM skf_equipo_listar() WHERE tipo = 'miembro';
  ASSERT n = 1, 'B solo ve a su gente';
  -- Cambiar el contexto a la organización de otro NO da acceso: hay que ser miembro.
  PERFORM set_config('app.org_id', org_a::text, true);
  SELECT count(*) INTO n FROM skf_equipo_listar();
  ASSERT n = 0, 'Con el org_id de otra empresa no ve nada';
  SELECT resultado INTO t FROM skf_equipo_invitar('cuela@eq-a.com', 'admin');
  ASSERT t = 'sin_permiso', 'Ni puede invitar en ella';

  -- ── El dueño de A sí nombra administradores y revoca ───────────────────
  PERFORM set_config('app.user_id', dueno_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  ASSERT skf_equipo_cambiar_rol(edit_a, 'admin') = 'ok', 'El dueño nombra administradores';
  ASSERT skf_equipo_cambiar_rol(admin2_a, 'editor') = 'ok', 'El dueño cambia a un admin';
  ASSERT skf_equipo_quitar(admin2_a) = 'ok', 'El dueño quita a alguien';
  ASSERT skf_equipo_revocar(inv) = 'ok', 'El dueño revoca una invitación';
  ASSERT skf_equipo_revocar(inv) = 'no_encontrada', 'Revocar dos veces no falla, solo no encuentra';
END $$;

ROLLBACK;
\echo 'OK: equipo (invitar, permisos y quitar dentro de la propia organización)'
