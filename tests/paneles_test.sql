-- ═══════════════════════════════════════════════════════════════════════════
--  Prueba de los paneles compartidos y del reporte de correcciones
--
--  Lo que se juega aquí: el enlace de un panel lo abre gente SIN cuenta. Si el
--  token sirviera para tocar hallazgos de otra organización, un cliente podría
--  escribir en el expediente de otro. Por eso lo primero que se prueba es
--  justamente eso, y con un ASSERT que falla ruidosamente.
--
--  Se corre como skf_app (NO como superusuario: un superusuario se salta RLS
--  y la prueba pasaria siempre, sin probar nada).
--
--    docker exec -i pg psql -U skf_app -d skf -v ON_ERROR_STOP=1 -f paneles_test.sql
-- ═══════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  org_a  UUID := '11111111-1111-1111-1111-111111111111';
  org_b  UUID := '22222222-2222-2222-2222-222222222222';
  user_a UUID := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  user_b UUID := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  super  UUID := '55555555-0000-0000-0000-000000000000';
  hz_a   UUID := 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  hz_b   UUID := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
  tok_a  TEXT := 'panel-de-a';
  tok_b  TEXT := 'panel-de-b';
  ok     BOOLEAN;
  snap   JSONB;
  n      INTEGER;
BEGIN
  -- ── Montaje ──────────────────────────────────────────────────────────────
  PERFORM set_config('app.user_id', super::text, true);
  PERFORM set_config('app.is_super_admin', 'on', true);

  INSERT INTO organizations (id, nombre) VALUES (org_a, 'Cliente A'), (org_b, 'Cliente B');
  INSERT INTO users (id, email) VALUES (user_a, 'a@cliente-a.com'), (user_b, 'b@cliente-b.com');
  INSERT INTO memberships (org_id, user_id, rol) VALUES (org_a, user_a, 'dueno'), (org_b, user_b, 'dueno');

  PERFORM set_config('app.is_super_admin', 'off', true);

  -- Un hallazgo en cada organización.
  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  INSERT INTO hallazgos (id, org_id, plantilla_nombre, campo_etiqueta, severidad)
    VALUES (hz_a, org_a, 'Ronda nocturna A', 'Extintor sin carga', 'mayor');
  INSERT INTO paneles_publicos (token, org_id, titulo, snapshot)
    VALUES (tok_a, org_a, 'Panel A', '{"filtro":"operativo","kpis":{"abiertos":1}}'::jsonb);

  PERFORM set_config('app.user_id', user_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  INSERT INTO hallazgos (id, org_id, plantilla_nombre, campo_etiqueta, severidad)
    VALUES (hz_b, org_b, 'Ronda nocturna B', 'Salida bloqueada', 'critico');
  INSERT INTO paneles_publicos (token, org_id, titulo, snapshot)
    VALUES (tok_b, org_b, 'Panel B', '{"filtro":"estatus"}'::jsonb);

  -- ── 1 · Lo importante: el token de A NO puede tocar un hallazgo de B ─────
  -- Sin sesión: es exactamente el contexto del visitante anónimo.
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.org_id',  '', true);

  ok := skf_panel_marcar_corregido(tok_a, hz_b, 'intruso', 'no deberia entrar');
  ASSERT ok = false, 'FUGA: el token de A marcó un hallazgo de la organización B';

  -- Y se comprueba desde DENTRO de B, que es el único contexto donde una fuga
  -- sería visible. Contarlo como anónimo no probaría nada: RLS esconde la
  -- tabla igual, haya fuga o no, y el ASSERT pasaría siempre.
  PERFORM set_config('app.user_id', user_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  SELECT count(*) INTO n FROM correcciones_campo;
  ASSERT n = 0, 'FUGA: quedó registrada una corrección sobre un hallazgo de otra organización';
  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.org_id',  '', true);

  -- Un token inventado tampoco sirve para nada.
  ok := skf_panel_marcar_corregido('token-que-no-existe', hz_a, 'intruso', '');
  ASSERT ok = false, 'Un token inexistente pudo marcar un hallazgo';

  ASSERT skf_panel_publico('token-que-no-existe') IS NULL,
    'Un token inexistente devolvió un panel';

  -- ── 2 · El camino bueno sí funciona ─────────────────────────────────────
  snap := skf_panel_publico(tok_a);
  ASSERT snap IS NOT NULL AND snap->>'filtro' = 'operativo',
    'El panel publicado no se pudo leer por su token';

  ok := skf_panel_marcar_corregido(tok_a, hz_a, 'Juan', 'Se recargó el extintor');
  ASSERT ok = true, 'No se pudo marcar como corregido un hallazgo de la propia organización';

  SELECT jsonb_array_length(skf_panel_marcas(tok_a)) INTO n;
  ASSERT n = 1, format('skf_panel_marcas devolvió %s marcas, se esperaba 1', n);

  -- ── 3 · Volver a marcar actualiza, no duplica ───────────────────────────
  ok := skf_panel_marcar_corregido(tok_a, hz_a, 'Juan Pérez', 'Corregido y verificado');
  ASSERT ok = true, 'La segunda marca falló';

  -- Como el dueño, que es quien puede ver la tabla.
  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);

  SELECT count(*) INTO n FROM correcciones_campo WHERE token = tok_a AND hallazgo_id = hz_a;
  ASSERT n = 1, format('Marcar dos veces dejó %s filas; el índice único no está haciendo su trabajo', n);

  SELECT count(*) INTO n FROM correcciones_campo
   WHERE token = tok_a AND hallazgo_id = hz_a AND marcado_por = 'Juan Pérez';
  ASSERT n = 1, 'La segunda marca no actualizó quién la reportó';

  PERFORM set_config('app.user_id', '', true);
  PERFORM set_config('app.org_id',  '', true);

  -- ── 4 · Desmarcar deshace ───────────────────────────────────────────────
  ok := skf_panel_desmarcar_corregido(tok_a, hz_a);
  ASSERT ok = true, 'No se pudo deshacer la marca';
  SELECT jsonb_array_length(skf_panel_marcas(tok_a)) INTO n;
  ASSERT n = 0, 'La marca sobrevivió al desmarcado';

  -- Deja una marca puesta para las comprobaciones de RLS de abajo.
  PERFORM skf_panel_marcar_corregido(tok_a, hz_a, 'Juan', 'listo');

  -- ── 5 · RLS: B no ve los paneles ni las correcciones de A ───────────────
  PERFORM set_config('app.user_id', user_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);

  SELECT count(*) INTO n FROM paneles_publicos WHERE org_id = org_a;
  ASSERT n = 0, 'FUGA: B ve los paneles compartidos de A';

  SELECT count(*) INTO n FROM correcciones_campo WHERE org_id = org_a;
  ASSERT n = 0, 'FUGA: B ve las correcciones reportadas en A';

  -- Y sí ve lo suyo.
  SELECT count(*) INTO n FROM paneles_publicos;
  ASSERT n = 1, format('B debería ver exactamente su panel, ve %s', n);

  -- ── 6 · Rastro de cierre ────────────────────────────────────────────────
  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);

  UPDATE hallazgos SET estado = 'cerrado', cerrado_en = NOW(), cerrado_por = 'Ana'
   WHERE id = hz_a;
  SELECT count(*) INTO n FROM hallazgos
   WHERE id = hz_a AND estado = 'cerrado' AND cerrado_por = 'Ana' AND cerrado_en IS NOT NULL;
  ASSERT n = 1, 'No quedó registrado quién cerró el hallazgo';

  -- B no puede cerrar un hallazgo de A (RLS de UPDATE): la fila no le existe.
  PERFORM set_config('app.user_id', user_b::text, true);
  PERFORM set_config('app.org_id',  org_b::text,  true);
  UPDATE hallazgos SET estado = 'cerrado', cerrado_por = 'intruso' WHERE id = hz_a;
  PERFORM set_config('app.user_id', user_a::text, true);
  PERFORM set_config('app.org_id',  org_a::text,  true);
  SELECT count(*) INTO n FROM hallazgos WHERE id = hz_a AND cerrado_por = 'intruso';
  ASSERT n = 0, 'FUGA: B cerró un hallazgo de A';

  RAISE NOTICE '✓ paneles_test: aislamiento por token, marcas y rastro de cierre OK';
END $$;

ROLLBACK;
