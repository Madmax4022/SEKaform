-- ¿Qué migraciones tiene esta base? SOLO LECTURA: no cambia nada.
-- Úsalo antes y después de ./scripts/migrar.sh:
--   psql "host=127.0.0.1 port=55432 dbname=<base> user=skf_owner sslmode=disable" -f scripts/verificar_migraciones.sql
-- Cada migración se reconoce por algo que solo ella crea.
SELECT m.migracion, CASE WHEN m.ok THEN '✓ aplicada' ELSE '✗ FALTA' END AS estado, m.que_trae
FROM (VALUES
  ('001_core',               to_regclass('public.envios') IS NOT NULL,                                   'tablas base y RLS'),
  ('002_auth_functions',     to_regprocedure('skf_auth_login(citext,text,integer,integer)') IS NOT NULL, 'inicio de sesión'),
  ('003_super_admin',        EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'authorized_emails' AND column_name = 'es_super_admin'), 'super administrador'),
  ('004_publico',            to_regprocedure('skf_publico_envio(uuid,text,jsonb,text,text,timestamp with time zone)') IS NOT NULL, 'formularios públicos'),
  ('005_paneles',            EXISTS (SELECT 1 FROM pg_proc WHERE proname LIKE 'skf_panel%'),              'paneles compartidos'),
  ('006_turnos',             EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'organizations' AND column_name = 'turnos_config'), 'turnos'),
  ('007_aviso_publico',      to_regclass('public.avisos_puntaje') IS NOT NULL,                           'avisos de puntaje en formularios públicos'),
  ('008_aviso_configurable', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'plantillas' AND column_name = 'aviso_umbral'), 'umbral y tope de avisos por formulario'),
  ('009_equipo',             to_regprocedure('skf_equipo_invitar(citext,text,integer)') IS NOT NULL,     'invitar y administrar el equipo desde la app'),
  ('010_asesores',           to_regprocedure('skf_asesor_crear_empresa(text,text)') IS NOT NULL,         'asesores con varias empresas; datos solo de la empresa activa'),
  ('011_portal',             to_regclass('public.portales') IS NOT NULL,                                 'portal del cliente (resumen en vivo)'),
  ('012_equipos_baja',       to_regclass('public.equipos_baja') IS NOT NULL,                             'dar de baja equipos retirados'),
  ('013_portal_fotos',       EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'portales' AND column_name = 'mostrar_fotos'), 'antes y después en el portal del cliente'),
  ('014_push',               to_regclass('public.push_suscripciones') IS NOT NULL,                       'avisos push al celular')
) AS m(migracion, ok, que_trae);
