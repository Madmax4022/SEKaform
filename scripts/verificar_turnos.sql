-- ═══════════════════════════════════════════════════════════════════════════
--  Verifica que la migración 006 (turnos) quedó bien aplicada.
--  SOLO LECTURA: no modifica nada. Cada fila dice OK o FALLA y por qué.
--
--    psql "host=127.0.0.1 port=55432 dbname=<base> user=skf_owner sslmode=disable" \
--         -f scripts/verificar_turnos.sql
-- ═══════════════════════════════════════════════════════════════════════════
\pset format aligned
\pset border 2

-- Guarda: si la columna no existe, las comprobaciones que la leen darían un error
-- técnico en vez de un mensaje claro. Se decide aquí qué mostrar.
SELECT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name='organizations' AND column_name='turnos_config') AS tiene_columna \gset

\if :tiene_columna
SELECT '1 · la columna existe y es JSONB' AS comprobacion,
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                         WHERE table_name='organizations' AND column_name='turnos_config' AND data_type='jsonb')
            THEN 'OK' ELSE 'FALLA: falta organizations.turnos_config (corre la migración 006)' END AS resultado
UNION ALL
SELECT '2 · no admite NULL (todas valen {} o un objeto)',
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                         WHERE table_name='organizations' AND column_name='turnos_config' AND is_nullable='NO')
            THEN 'OK' ELSE 'FALLA: la columna admite NULL' END
UNION ALL
SELECT '3 · valor por defecto {}',
       CASE WHEN (SELECT column_default FROM information_schema.columns
                  WHERE table_name='organizations' AND column_name='turnos_config') LIKE '%{}%'
            THEN 'OK' ELSE 'FALLA: el valor por defecto no es {}' END
UNION ALL
SELECT '4 · solo dueño/admin puede editar (política org_upd)',
       CASE WHEN EXISTS (SELECT 1 FROM pg_policies WHERE tablename='organizations' AND policyname='org_upd' AND cmd='UPDATE')
            THEN 'OK' ELSE 'FALLA: falta la política org_upd — cualquier miembro podría editar' END
UNION ALL
SELECT '5 · RLS activo en organizations',
       CASE WHEN (SELECT relrowsecurity FROM pg_class WHERE relname='organizations')
            THEN 'OK' ELSE 'FALLA: RLS desactivado en organizations' END
UNION ALL
SELECT '6 · skf_app puede leer y actualizar la columna',
       CASE WHEN has_column_privilege('skf_app','organizations','turnos_config','SELECT')
             AND has_column_privilege('skf_app','organizations','turnos_config','UPDATE')
            THEN 'OK' ELSE 'FALLA: skf_app sin permisos sobre la columna' END
UNION ALL
SELECT '7 · todos los valores son objetos JSON',
       CASE WHEN NOT EXISTS (SELECT 1 FROM organizations WHERE jsonb_typeof(turnos_config) <> 'object')
            THEN 'OK' ELSE 'FALLA: hay organizaciones con turnos_config que no es un objeto' END;

-- Informativo: cuántas organizaciones ya configuraron turnos.
SELECT count(*)                                              AS organizaciones,
       count(*) FILTER (WHERE turnos_config ? 'turnos')      AS con_turnos_configurados
FROM organizations;
\else
  \echo
  \echo '  FALLA: falta organizations.turnos_config — la migración 006 NO está aplicada.'
  \echo '         Corre:  ./scripts/migrar.sh <proyecto:region:instancia> <base>'
  \echo '         y vuelve a ejecutar esta verificación.'
  \echo
\endif
