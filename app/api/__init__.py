"""API REST que consume la PWA.

Contrato con el frontend sin conexión, y el motivo de cada decisión:

* **El cliente elige el id.** Todo registro llega con un UUID generado en el
  navegador. El servidor hace UPSERT sobre ese id, así que reintentar un envío
  encolado durante horas sin señal no crea duplicados. Antes los ids eran
  `env_${Date.now()}`, que colisionan entre dispositivos y no son idempotentes.

* **`/api/sync` acepta lotes.** Un inspector que vuelve de una jornada sin
  cobertura tiene decenas de operaciones pendientes; mandarlas de una vez evita
  decenas de viajes por una red que apenas se recuperó. Cada operación se
  responde por separado: si una falla, las demás igual entran.

* **El servidor manda en lo que el cliente no puede saber.** Números
  correlativos, `org_id` y sellos de tiempo de recepción se fijan aquí. El
  cliente sí aporta `capturado_en`, que es un dato real de campo: cuándo se
  llenó de verdad, que puede ser muy anterior a cuándo llegó.
"""

from __future__ import annotations

import logging
import uuid
from typing import Any, Optional

import psycopg2.extras
from flask import Blueprint, jsonify, request
from flask_login import current_user

from .. import db
from ..security import (auditar, requiere_organizacion, requiere_escritura,
                        sesion_usuario)

log = logging.getLogger(__name__)
bp = Blueprint("api", __name__, url_prefix="/api")

# Tablas que el cliente puede sincronizar, con sus columnas permitidas. Es una
# lista blanca a propósito: el cuerpo de la petición nunca decide en qué tabla
# se escribe ni qué columnas se tocan.
SINCRONIZABLES: dict[str, dict[str, Any]] = {
    "unidad": {
        "tabla": "unidades",
        "columnas": ["id", "nombre", "tipo", "padre_id", "activa"],
    },
    "plantilla": {
        "tabla": "plantillas",
        "columnas": ["id", "nombre", "codigo", "descripcion", "norma", "campos",
                     "logo_url", "favorito", "publica", "share_token",
                     "correo_notificacion", "archivada"],
    },
    "envio": {
        "tabla": "envios",
        "columnas": ["id", "plantilla_id", "plantilla_nombre", "plantilla_codigo",
                     "unidad_id", "datos", "estado", "llenado_por", "llenado_correo",
                     "capturado_en"],
    },
    "hallazgo": {
        "tabla": "hallazgos",
        "columnas": ["id", "envio_id", "plantilla_id", "plantilla_nombre", "campo_id",
                     "campo_etiqueta", "origen", "severidad", "descripcion",
                     "foto_url", "unidad_id", "estado", "reportado_por"],
    },
    "accion_correctiva": {
        "tabla": "acciones_correctivas",
        "columnas": ["id", "hallazgo_id", "responsable", "correo", "fecha_limite",
                     "estado", "evidencia_url", "cerrado_en"],
    },
    "asignacion": {
        "tabla": "asignaciones",
        "columnas": ["id", "plantilla_id", "plantilla_nombre", "unidad_id", "nombre",
                     "correo", "fecha_limite", "completado_en", "envio_id"],
    },
    "inspeccion": {
        "tabla": "inspecciones_programadas",
        "columnas": ["id", "plantilla_id", "unidad_id", "nombre", "frecuencia",
                     "proximo_en", "responsable", "correo", "activa", "ultimo_completado"],
    },
}

# Borrados admitidos. Se listan aparte porque un borrado solo necesita el id,
# y porque conviene que sea explícito qué se puede borrar desde el cliente.
BORRABLES = {
    "deletePlantilla":   "plantillas",
    "deleteUnidad":      "unidades",
    "deleteAsignacion":  "asignaciones",
    "deleteInspeccion":  "inspecciones_programadas",
}

# Campos que el cliente NUNCA fija, aunque los mande: o los decide el servidor
# o comprometerían el aislamiento entre organizaciones.
PROHIBIDOS = {"org_id", "numero", "autor_id", "es_catalogo", "creado_en",
              "recibido_en", "enviado_en", "actualizado_en"}


def _uuid_valido(valor: Any) -> Optional[str]:
    try:
        return str(uuid.UUID(str(valor)))
    except (ValueError, AttributeError, TypeError):
        return None


def _upsert(cur, tipo: str, payload: dict) -> dict:
    """Inserta, actualiza o borra un registro del cliente. Idempotente por id."""
    if tipo in BORRABLES:
        registro_id = _uuid_valido(payload.get("id"))
        if not registro_id:
            return {"ok": False, "error": "Falta un id UUID válido.", "reintentable": False}
        # RLS acota el DELETE a la organización activa: basta el id. Borrar algo
        # que ya no está no es un error — la cola pudo reintentar.
        cur.execute(f'DELETE FROM {BORRABLES[tipo]} WHERE id = %s', (registro_id,))
        return {"ok": True, "id": registro_id, "tipo": tipo}

    if tipo == "org":
        # La organización no se crea desde el cliente, solo se editan sus datos
        # de marca. El id sale de la sesión, nunca del cuerpo de la petición.
        campos = {k: v for k, v in payload.items() if k in ("nombre", "logo_url", "pais")}
        if not campos:
            return {"ok": True, "tipo": tipo}
        asigna = ", ".join(f'"{c}" = %s' for c in campos)
        cur.execute(
            f'UPDATE organizations SET {asigna} WHERE id = %s',
            list(campos.values()) + [current_user.org_id],
        )
        return {"ok": True, "id": current_user.org_id, "tipo": tipo}

    spec = SINCRONIZABLES.get(tipo)
    if not spec:
        return {"ok": False, "error": f"Tipo desconocido: {tipo}", "reintentable": False}

    registro_id = _uuid_valido(payload.get("id"))
    if not registro_id:
        return {"ok": False, "error": "Falta un id UUID válido.", "reintentable": False}

    datos = {
        k: v for k, v in payload.items()
        if k in spec["columnas"] and k not in PROHIBIDOS and k != "id"
    }

    # Las columnas JSONB (plantillas.campos, envios.datos) llegan como dict o
    # list de Python, y psycopg2 no sabe convertirlas por su cuenta: falla con
    # "can't adapt type 'dict'". Json() las serializa correctamente.
    datos = {
        k: (psycopg2.extras.Json(v) if isinstance(v, (dict, list)) else v)
        for k, v in datos.items()
    }

    columnas = ["id", "org_id"] + list(datos.keys())
    valores = [registro_id, current_user.org_id] + list(datos.values())
    marcadores = ", ".join(["%s"] * len(columnas))
    lista = ", ".join(f'"{c}"' for c in columnas)

    # Al actualizar no se toca org_id: si un registro ya existe en otra
    # organización, la cláusula WHERE deja el UPDATE en cero filas y RLS impide
    # verlo. Nunca se puede "mover" un registro de un cliente a otro.
    if datos:
        set_clause = ", ".join(f'"{c}" = EXCLUDED."{c}"' for c in datos.keys())
        conflicto = f"DO UPDATE SET {set_clause}"
    else:
        conflicto = "DO NOTHING"

    cur.execute(
        f'INSERT INTO {spec["tabla"]} ({lista}) VALUES ({marcadores}) '
        f'ON CONFLICT (id) {conflicto} RETURNING id',
        valores,
    )
    fila = cur.fetchone()
    return {"ok": True, "id": fila["id"] if fila else registro_id, "tipo": tipo}


# ── Sincronización por lotes ───────────────────────────────────────────────

@bp.route("/sync", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def sync():
    """Vacía la cola sin conexión del cliente.

    Cuerpo: {"operaciones": [{"opId": "...", "tipo": "envio", "datos": {...}}, ...]}

    Cada operación se responde con su `opId` para que el cliente sepa
    exactamente cuáles borrar de su cola y cuáles reintentar. Una operación
    inválida no aborta el lote: se marca y las demás continúan, porque perder
    un día de inspecciones por un registro corrupto sería inaceptable.
    """
    cuerpo = request.get_json(silent=True) or {}
    operaciones = cuerpo.get("operaciones") or []

    if not isinstance(operaciones, list):
        return jsonify({"error": "«operaciones» debe ser una lista."}), 400
    if len(operaciones) > 500:
        return jsonify({"error": "Máximo 500 operaciones por lote."}), 413

    resultados = []
    aplicadas = 0

    for op in operaciones:
        op_id = op.get("opId")
        tipo = op.get("tipo")
        datos = op.get("datos") or {}
        try:
            # Cada operación en su propia transacción: una que falle por datos
            # inválidos no debe arrastrar a las que sí eran correctas.
            with sesion_usuario() as cur:
                r = _upsert(cur, tipo, datos)
            r["opId"] = op_id
            resultados.append(r)
            if r.get("ok"):
                aplicadas += 1
        except Exception as e:
            log.warning("Fallo al sincronizar op %s (%s): %s", op_id, tipo, e)
            resultados.append({
                "opId": op_id, "ok": False, "tipo": tipo,
                # `reintentable` distingue "la red falló, vuelve a intentarlo"
                # de "estos datos nunca van a entrar, deséchalos". Sin eso, un
                # registro corrupto se reintenta para siempre.
                "error": "No se pudo aplicar.", "reintentable": True,
            })

    if aplicadas:
        auditar("sync", detalle={"operaciones": len(operaciones), "aplicadas": aplicadas})

    return jsonify({"resultados": resultados, "aplicadas": aplicadas})


# ── Lectura ────────────────────────────────────────────────────────────────

@bp.route("/bootstrap")
@requiere_organizacion
def bootstrap():
    """Todo lo que la PWA necesita para funcionar sin conexión, en una llamada.

    Se pide al abrir la app con señal y se guarda en localStorage. A partir de
    ahí el inspector puede trabajar desconectado con datos frescos.
    """
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute(
            "SELECT id, nombre, codigo, descripcion, norma, campos, logo_url, favorito, "
            "publica, share_token, es_catalogo, vertical "
            "FROM plantillas WHERE NOT archivada ORDER BY favorito DESC, actualizado_en DESC"
        )
        plantillas = cur.fetchall()

        cur.execute("SELECT id, nombre, tipo, padre_id FROM unidades WHERE activa ORDER BY nombre")
        unidades = cur.fetchall()

        cur.execute(
            "SELECT id, plantilla_id, plantilla_nombre, unidad_id, nombre, correo, "
            "fecha_limite, completado_en FROM asignaciones ORDER BY creado_en DESC LIMIT 500"
        )
        asignaciones = cur.fetchall()

        cur.execute(
            "SELECT id, plantilla_id, unidad_id, nombre, frecuencia, proximo_en, "
            "responsable, activa FROM inspecciones_programadas WHERE activa ORDER BY proximo_en"
        )
        programadas = cur.fetchall()

        cur.execute("SELECT id, nombre, logo_url, pais, plan FROM organizations WHERE id = %s",
                    (current_user.org_id,))
        organizacion = cur.fetchone()

    return jsonify({
        "usuario": current_user.to_dict(),
        "organizacion": organizacion,
        "plantillas": plantillas,
        "unidades": unidades,
        "asignaciones": asignaciones,
        "programadas": programadas,
    })


@bp.route("/envios")
@requiere_organizacion
def envios():
    limite = min(int(request.args.get("limite", 500)), 2000)
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute(
            "SELECT id, plantilla_id, plantilla_nombre, plantilla_codigo, unidad_id, "
            "datos, estado, numero, llenado_por, capturado_en, enviado_en "
            "FROM envios ORDER BY enviado_en DESC LIMIT %s",
            (limite,),
        )
        return jsonify({"envios": cur.fetchall()})


@bp.route("/hallazgos")
@requiere_organizacion
def hallazgos():
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute("SELECT * FROM hallazgos ORDER BY creado_en DESC LIMIT 1000")
        h = cur.fetchall()
        cur.execute("SELECT * FROM acciones_correctivas ORDER BY creado_en DESC LIMIT 1000")
        a = cur.fetchall()
    return jsonify({"hallazgos": h, "acciones": a})


@bp.route("/dashboard")
@requiere_organizacion
def dashboard():
    """Agregados del panel, calculados en SQL.

    Hoy el dashboard se descarga todos los envíos y los agrega en JavaScript.
    Con cientos de inspecciones eso es megabytes por carga y un móvil que se
    arrastra. Postgres resuelve lo mismo en una consulta y devuelve kilobytes;
    es también la razón principal por la que este producto quiere una base
    relacional y no un almacén documental.
    """
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute("""
            WITH por_dia AS (
              SELECT date_trunc('day', enviado_en)::date AS dia, count(*) AS n
                FROM envios WHERE enviado_en > NOW() - INTERVAL '30 days'
               GROUP BY 1 ORDER BY 1
            ), por_unidad AS (
              SELECT u.id, u.nombre, u.tipo, count(e.id) AS envios,
                     count(h.id) FILTER (WHERE h.estado <> 'cerrado') AS hallazgos_abiertos
                FROM unidades u
                LEFT JOIN envios e    ON e.unidad_id = u.id
                LEFT JOIN hallazgos h ON h.unidad_id = u.id
               GROUP BY u.id, u.nombre, u.tipo ORDER BY envios DESC
            ), recurrentes AS (
              SELECT plantilla_nombre, campo_etiqueta, count(*) AS veces,
                     max(creado_en) AS ultimo
                FROM hallazgos WHERE campo_etiqueta IS NOT NULL
               GROUP BY 1, 2 HAVING count(*) >= 2
               ORDER BY veces DESC LIMIT 10
            ), cierre AS (
              SELECT avg(EXTRACT(EPOCH FROM (cerrado_en - creado_en)) / 86400) AS dias
                FROM acciones_correctivas WHERE estado = 'completada' AND cerrado_en IS NOT NULL
            )
            SELECT
              (SELECT json_agg(por_dia)      FROM por_dia)      AS por_dia,
              (SELECT json_agg(por_unidad)   FROM por_unidad)   AS por_unidad,
              (SELECT json_agg(recurrentes)  FROM recurrentes)  AS recurrentes,
              (SELECT dias FROM cierre)                         AS dias_cierre_promedio,
              (SELECT count(*) FROM envios)                     AS total_envios,
              (SELECT count(*) FROM envios
                WHERE enviado_en > date_trunc('month', NOW()))  AS envios_mes,
              (SELECT count(*) FROM hallazgos
                WHERE estado <> 'cerrado')                      AS hallazgos_abiertos,
              (SELECT count(*) FROM hallazgos
                WHERE estado <> 'cerrado' AND severidad = 'critico') AS criticos_abiertos
        """)
        return jsonify(cur.fetchone())


@bp.route("/csrf")
def csrf_token():
    """Entrega el token CSRF a la PWA.

    Las páginas de la aplicación son HTML estático (herencia de GitHub Pages),
    no plantillas Jinja, así que no pueden llevar {{ csrf_token() }} incrustado.
    Sin esto, toda escritura se rechazaría con 400 y la app parecería rota.

    Entregarlo por GET no debilita la protección: un sitio de terceros no puede
    leer la respuesta (política del mismo origen), y sin leerla no puede forjar
    la cabecera X-CSRFToken que exige cada escritura.
    """
    from flask_wtf.csrf import generate_csrf
    return jsonify({"token": generate_csrf()})


# ── Alertas de hallazgos críticos ──────────────────────────────────────────

@bp.route("/alertas")
@requiere_organizacion
def alertas():
    """Hallazgos críticos abiertos desde una fecha. Sustituye a Supabase
    Realtime: sin WebSocket, el cliente pregunta cada minuto. Para un aviso de
    seguridad esa latencia es aceptable y ahorra mantener una conexión abierta
    en móviles con batería contada."""
    desde = request.args.get("desde") or "1970-01-01T00:00:00Z"
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute(
            "SELECT id, plantilla_nombre, campo_etiqueta, descripcion, creado_en "
            "FROM hallazgos WHERE severidad = 'critico' AND estado <> 'cerrado' "
            "AND creado_en > %s ORDER BY creado_en DESC LIMIT 20",
            (desde,),
        )
        return jsonify({"alertas": cur.fetchall()})


# ── Formularios públicos (enlace / QR, sin sesión) ─────────────────────────
# Van por funciones SECURITY DEFINER del esquema (migrations/004_publico.sql):
# el visitante no tiene identidad, así que RLS no puede protegerle nada. La
# organización se deriva SIEMPRE de la plantilla, nunca del cuerpo enviado.

@bp.route("/publico/plantilla/<token>")
def publico_plantilla(token: str):
    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT * FROM skf_publico_plantilla(%s)", (token,))
        fila = cur.fetchone()
    if not fila:
        return jsonify({"error": "Formulario no disponible."}), 404
    return jsonify(fila)


@bp.route("/publico/envio", methods=["POST"])
def publico_envio():
    d = request.get_json(silent=True) or {}
    envio_id = _uuid_valido(d.get("id"))
    token = (d.get("token") or "").strip()
    if not envio_id or not token:
        return jsonify({"error": "Faltan id o token."}), 400

    import json as _json
    with db.sesion_privilegiada() as cur:
        cur.execute(
            "SELECT * FROM skf_publico_envio(%s, %s, %s::jsonb, %s, %s, %s)",
            (envio_id, token, _json.dumps(d.get("datos") or {}),
             (d.get("llenadoPor") or None), (d.get("llenadoCorreo") or None),
             d.get("capturadoEn") or None),
        )
        r = cur.fetchone()

    if r["resultado"] != "ok":
        return jsonify({"error": "Ese formulario ya no acepta respuestas."}), 403
    return jsonify({"ok": True, "id": r["envio_id"], "numero": r["numero"]}), 201


@bp.route("/publico/hallazgo", methods=["POST"])
def publico_hallazgo():
    d = request.get_json(silent=True) or {}
    hz_id = _uuid_valido(d.get("id"))
    token = (d.get("token") or "").strip()
    if not hz_id or not token:
        return jsonify({"error": "Faltan id o token."}), 400

    with db.sesion_privilegiada() as cur:
        cur.execute(
            "SELECT skf_publico_hallazgo(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) AS r",
            (hz_id, token, _uuid_valido(d.get("envioId")), d.get("campoId"),
             d.get("campoEtiqueta"), d.get("origen"), d.get("severidad"),
             d.get("descripcion"), d.get("fotoUrl"), d.get("reportadoPor")),
        )
        r = cur.fetchone()["r"]

    if r != "ok":
        return jsonify({"error": "No se pudo registrar el hallazgo."}), 403
    return jsonify({"ok": True}), 201


def registrar_api(app, csrf) -> None:
    app.register_blueprint(bp)
    # Los envíos públicos llegan de gente sin sesión y, por tanto, sin token
    # CSRF. No hay nada que proteger: no existe sesión que suplantar, y la
    # única escritura posible es contra una plantilla marcada como pública.
    csrf.exempt(publico_envio)
    csrf.exempt(publico_hallazgo)
