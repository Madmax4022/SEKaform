#!/usr/bin/env python3
"""Carga las 69 plantillas de form-library.js en la tabla `plantillas`.

Entran como CATÁLOGO GLOBAL (es_catalogo = true, org_id = NULL): pertenecen al
producto, no a un cliente. Ninguna organización las ve hasta que un super
administrador se las conceda desde /admin — es el mecanismo de "dar acceso al
formulario".

Los ids son UUID v5 derivados del id textual del catálogo
(`inspeccion_extintores` → siempre el mismo UUID). Eso hace el script
idempotente y, sobre todo, hace que las concesiones ya otorgadas sigan
apuntando a la plantilla correcta cuando se vuelva a sembrar tras editar el
catálogo. Con UUID aleatorios, cada carga habría revocado en la práctica todos
los accesos concedidos.

No se conecta a la base: escribe SQL en la salida estándar, para canalizarlo a
psql. Así no hace falta psycopg2 ni ningún entorno de Python preparado —basta
node (que ya se usa en las pruebas) y psql—, y el mismo comando sirve en local,
en CI y contra Cloud SQL a través del proxy.

Uso:
    python3 scripts/seed_catalogo.py | psql "$DSN_OWNER" -v ON_ERROR_STOP=1
    python3 scripts/seed_catalogo.py --resumen     # solo el recuento

Se canaliza a una sesión de skf_owner: el catálogo es esquema del producto, y
la aplicación (skf_app) no puede escribirlo — sus policies solo le permiten
crear plantillas propias, nunca de catálogo.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent

# Espacio de nombres propio para derivar UUID estables. No cambiar nunca:
# hacerlo reasignaría el id de las 69 plantillas y rompería las concesiones.
NS_CATALOGO = uuid.UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")


def leer_biblioteca() -> list[dict]:
    """Evalúa form-library.js con node y devuelve FORM_LIBRARY como JSON.

    El catálogo vive en un .js porque el navegador lo carga con <script>. En
    vez de mantener una segunda copia en JSON —que se desincronizaría— se deja
    que node lo evalúe: una sola fuente de verdad.
    """
    # form-library.js declara `const FORM_LIBRARY` sin exportarlo. Un `const`
    # dentro de eval() no escapa a su ámbito, así que no basta con evaluarlo:
    # se le añade la expresión `;FORM_LIBRARY` al final y se recoge el valor de
    # terminación que devuelve eval.
    script = (
        "const fs=require('fs');"
        "const src=fs.readFileSync('form-library.js','utf8');"
        "console.log(JSON.stringify(eval(src + ';FORM_LIBRARY')));"
    )
    try:
        salida = subprocess.run(
            ["node", "-e", script],
            cwd=RAIZ, capture_output=True, text=True, check=True,
        ).stdout
    except FileNotFoundError:
        sys.exit("Falta node. Instálalo: brew install node")
    except subprocess.CalledProcessError as e:
        sys.exit(f"No se pudo leer form-library.js:\n{e.stderr}")

    return json.loads(salida)


def convertir_campos(plantilla: dict) -> list[dict]:
    """Pasa `campos_clave` del catálogo al formato que llenar.html sabe pintar."""
    campos = []
    for i, c in enumerate(plantilla.get("campos_clave", [])):
        tipo = c.get("tipo", "texto")
        campo = {
            # id estable dentro de la plantilla: los datos de un envío se
            # guardan bajo esta clave, así que no puede cambiar entre siembras.
            "id": f"c{i:03d}",
            "tipo": tipo,
            "etiqueta": c.get("etiqueta", ""),
            "requerido": tipo != "separador",
        }
        if c.get("opciones"):
            campo["opciones"] = c["opciones"]
        campos.append(campo)
    return campos


def sql_literal(valor) -> str:
    """Literal SQL con comillas escapadas. Los datos vienen del repositorio,
    no de usuarios, pero escapar siempre es más barato que razonar sobre ello."""
    if valor is None:
        return "NULL"
    return "'" + str(valor).replace("'", "''") + "'"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--resumen", action="store_true",
                    help="Imprime el recuento por vertical en vez del SQL.")
    args = ap.parse_args()

    biblioteca = leer_biblioteca()

    if args.resumen:
        por_vertical: dict[str, int] = {}
        for p in biblioteca:
            v = p.get("vertical", "—")
            por_vertical[v] = por_vertical.get(v, 0) + 1
        print(f"→ {len(biblioteca)} plantillas en form-library.js")
        for v, n in sorted(por_vertical.items()):
            print(f"    {v:<15} {n:>3}")
        return

    out = sys.stdout.write
    out("-- Generado por scripts/seed_catalogo.py — no editar a mano.\n")
    out("BEGIN;\n")

    for p in biblioteca:
        pid = uuid.uuid5(NS_CATALOGO, p["id"])
        campos = json.dumps(convertir_campos(p), ensure_ascii=False)
        out(
            "INSERT INTO plantillas (id, es_catalogo, org_id, vertical, nombre, norma, campos)\n"
            f"VALUES ({sql_literal(pid)}, true, NULL, {sql_literal(p.get('vertical'))}, "
            f"{sql_literal(p['nombre'])}, {sql_literal(p.get('norma'))}, {sql_literal(campos)}::jsonb)\n"
            "ON CONFLICT (id) DO UPDATE SET\n"
            "  nombre = EXCLUDED.nombre, vertical = EXCLUDED.vertical,\n"
            "  norma = EXCLUDED.norma, campos = EXCLUDED.campos, actualizado_en = NOW();\n"
        )

    out("COMMIT;\n")
    out("\\echo '✓ Catálogo sembrado. Concede acceso desde /admin → Acceso a formularios.'\n")
    out("SELECT count(*) AS plantillas_de_catalogo FROM plantillas WHERE es_catalogo;\n")


if __name__ == "__main__":
    main()
