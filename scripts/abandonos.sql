-- ¿Dónde se pierde la gente? Embudo de activación por organización, solo con datos que ya existen
-- (sin analítica nueva, sin contenido de formularios ni datos personales: solo conteos y fechas).
--
-- Solo lectura. Ejecutar como skf_owner (el rol de la aplicación, skf_app, ve una organización a la vez
-- por RLS y no sirve para esto):
--   psql "host=... dbname=... user=skf_owner" -f scripts/abandonos.sql
--
-- «Activada» = tiene al menos un envío. Quien no llega ahí no recibió valor de la app.

-- 1) Embudo: de las cuentas creadas hace más de 3 días, ¿hasta dónde llegó cada una?
WITH base AS (
  SELECT o.id, o.creado_en,
         EXISTS (SELECT 1 FROM plantillas p WHERE p.org_id = o.id AND NOT p.es_catalogo)        AS tiene_form,
         EXISTS (SELECT 1 FROM envios e WHERE e.org_id = o.id AND e.estado = 'enviado')          AS tiene_envio,
         (SELECT count(*) FROM envios e WHERE e.org_id = o.id AND e.estado = 'enviado')          AS n_envios,
         (SELECT count(DISTINCT date_trunc('week', e.recibido_en))
            FROM envios e WHERE e.org_id = o.id AND e.estado = 'enviado')                        AS semanas_activas
  FROM organizations o
  WHERE o.activa AND o.creado_en < NOW() - INTERVAL '3 days'
)
SELECT
  count(*)                                                    AS cuentas_con_mas_de_3_dias,
  count(*) FILTER (WHERE tiene_form)                          AS agregaron_un_formulario,
  count(*) FILTER (WHERE tiene_envio)                         AS enviaron_algo,
  count(*) FILTER (WHERE n_envios >= 3)                       AS enviaron_3_o_mas,
  count(*) FILTER (WHERE semanas_activas >= 2)                AS volvieron_otra_semana,
  round(100.0 * count(*) FILTER (WHERE tiene_envio) / NULLIF(count(*), 0), 1) AS pct_activadas
FROM base;

-- 2) Quiénes se quedaron a medias, y en qué paso (para escribirles o mirar qué les falló).
--    «paso» es el último hito que alcanzaron.
SELECT o.id AS org_id, o.nombre, o.pais, o.creado_en::date AS creada,
       CASE
         WHEN NOT EXISTS (SELECT 1 FROM plantillas p WHERE p.org_id = o.id AND NOT p.es_catalogo)
           THEN '1 · Se registró, nunca agregó un formulario'
         ELSE '2 · Tiene formulario, nunca envió un registro'
       END AS paso,
       (SELECT count(*) FROM memberships m WHERE m.org_id = o.id) AS usuarios
FROM organizations o
WHERE o.activa
  AND o.creado_en < NOW() - INTERVAL '3 days'
  AND NOT EXISTS (SELECT 1 FROM envios e WHERE e.org_id = o.id AND e.estado = 'enviado')
ORDER BY o.creado_en DESC;

-- 3) Los que sí llegaron y luego se apagaron: tuvieron envíos, pero ninguno en los últimos 30 días.
SELECT o.id AS org_id, o.nombre, count(e.*) AS envios_totales,
       max(e.recibido_en)::date AS ultimo_envio,
       (CURRENT_DATE - max(e.recibido_en)::date) AS dias_sin_actividad
FROM organizations o
JOIN envios e ON e.org_id = o.id AND e.estado = 'enviado'
WHERE o.activa
GROUP BY o.id, o.nombre
HAVING max(e.recibido_en) < NOW() - INTERVAL '30 days'
ORDER BY max(e.recibido_en) DESC;
