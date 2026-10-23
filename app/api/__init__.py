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
import re
import uuid
from typing import Any, Optional

import psycopg2.extras
from flask import Blueprint, jsonify, request
from flask_login import current_user

# «correo_avisos» y no «alertas»: más abajo hay una ruta que se llama alertas() y, con el
# mismo nombre, tapaba al módulo — cada envío nuevo fallaba al intentar avisar.
from .. import alertas as correo_avisos, db, limiter
from ..security import (auditar, requiere_organizacion, requiere_escritura,
                        requiere_sesion, sesion_usuario)

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
                     "correo_notificacion", "archivada", "aviso_umbral", "aviso_max_hora"],
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


_HORA = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def _validar_turnos(cfg: Any):
    """Valida y normaliza turnos_config. Devuelve (config, error)."""
    if not isinstance(cfg, dict):
        return None, "La configuración de turnos no es válida."
    turnos, esperado = cfg.get("turnos", []), cfg.get("esperado", [])
    if not isinstance(turnos, list) or not isinstance(esperado, list):
        return None, "La configuración de turnos no es válida."
    if len(turnos) > 8:
        return None, "Máximo 8 turnos."
    limpios, vistos = [], set()
    for t in turnos:
        if not isinstance(t, dict):
            return None, "Un turno no es válido."
        nombre = str(t.get("nombre", "")).strip()[:40]
        ini, fin, tid = str(t.get("inicio", "")), str(t.get("fin", "")), str(t.get("id", "")).strip()[:20]
        if not nombre or not tid or tid in vistos:
            return None, "Cada turno necesita un nombre."
        if not _HORA.match(ini) or not _HORA.match(fin) or ini == fin:
            return None, f"El turno «{nombre}» necesita hora de inicio y de fin distintas (HH:MM)."
        vistos.add(tid)
        limpios.append({"id": tid, "nombre": nombre, "inicio": ini, "fin": fin})
    if len(esperado) > 40 or not all(isinstance(x, str) and 0 < len(x) <= 64 for x in esperado):
        return None, "La lista de formularios esperados no es válida."
    return {"turnos": limpios, "esperado": list(dict.fromkeys(esperado))}, None


def _uuid_valido(valor: Any) -> Optional[str]:
    try:
        return str(uuid.UUID(str(valor)))
    except (ValueError, AttributeError, TypeError):
        return None


_AVISO_CLAVES = ("aviso_umbral", "aviso_max_hora")
_AVISO_RANGOS = {"aviso_umbral": (0, 100), "aviso_max_hora": (1, 20)}


def _preparar_aviso(cur, payload: dict):
    """Valida los ajustes de aviso de una plantilla y, si la migración 008 aún no se corrió,
    los descarta en vez de fallar: sin esto, guardar CUALQUIER formulario quedaría reintentando
    para siempre contra una columna que no existe. Devuelve (payload, error)."""
    if not any(k in payload for k in _AVISO_CLAVES):
        return payload, None
    limpio = dict(payload)
    for k, (mn, mx) in _AVISO_RANGOS.items():
        if k not in limpio or limpio[k] is None:
            continue
        v = limpio[k]
        if isinstance(v, bool) or not isinstance(v, int) or not mn <= v <= mx:
            return payload, f"«{k}» debe ser un número entero entre {mn} y {mx}."
    cur.execute("SELECT 1 FROM pg_attribute WHERE attrelid = 'plantillas'::regclass "
                "AND attname = 'aviso_umbral' AND NOT attisdropped")
    if not cur.fetchone():
        log.warning("Migración 008 sin correr: se descartan los ajustes de aviso del formulario.")
        for k in _AVISO_CLAVES:
            limpio.pop(k, None)
    return limpio, None


# Nombres con que la app manda algunos tipos. «accionCorrectiva» no se reconocía y cada
# acción correctiva creada en la app quedaba rechazada en el teléfono, sin llegar a la nube.
_ALIAS_TIPO = {"accionCorrectiva": "accion_correctiva"}


def _upsert(cur, tipo: str, payload: dict) -> dict:
    """Inserta, actualiza o borra un registro del cliente. Idempotente por id."""
    tipo = _ALIAS_TIPO.get(tipo, tipo)
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
        campos = {k: v for k, v in payload.items() if k in ("nombre", "logo_url", "pais", "turnos_config")}
        if not campos:
            return {"ok": True, "tipo": tipo}
        if "turnos_config" in campos:
            cfg, error = _validar_turnos(campos["turnos_config"])
            if error:
                return {"ok": False, "error": error, "reintentable": False}
            campos["turnos_config"] = psycopg2.extras.Json(cfg)
        asigna = ", ".join(f'"{c}" = %s' for c in campos)
        cur.execute(
            f'UPDATE organizations SET {asigna} WHERE id = %s',
            list(campos.values()) + [current_user.org_id],
        )
        # RLS (org_upd) solo deja actualizar a dueño/admin: para ellos rowcount
        # es 1. Con otro rol la base devuelve 0 filas SIN error, y "ok" sería
        # mentira: el usuario creería haber guardado los turnos.
        if "turnos_config" in campos and cur.rowcount == 0:
            return {"ok": False, "reintentable": False,
                    "error": "Solo un administrador de la organización puede cambiar los turnos."}
        return {"ok": True, "id": current_user.org_id, "tipo": tipo}

    spec = SINCRONIZABLES.get(tipo)
    if not spec:
        return {"ok": False, "error": f"Tipo desconocido: {tipo}", "reintentable": False}

    if tipo == "plantilla":
        payload, error = _preparar_aviso(cur, payload)
        if error:
            return {"ok": False, "error": error, "reintentable": False}

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
        f'ON CONFLICT (id) {conflicto} RETURNING id, (xmax = 0) AS nuevo',
        valores,
    )
    fila = cur.fetchone()
    # Un hallazgo cerrado desde la app llega solo con su estado: la fecha y quién lo cerró
    # los pone el servidor (sin ellos, el portal y la carpeta de evidencia no lo ven cerrado).
    if tipo == "hallazgo" and fila:
        cur.execute(
            "UPDATE hallazgos SET cerrado_en = CASE WHEN estado = 'cerrado' THEN COALESCE(cerrado_en, NOW()) END, "
            "cerrado_por = CASE WHEN estado = 'cerrado' THEN COALESCE(cerrado_por, %s) END WHERE id = %s",
            (getattr(current_user, "nombre", None) or current_user.email, fila["id"]))
    r = {"ok": True, "id": fila["id"] if fila else registro_id, "tipo": tipo}
    # xmax = 0 solo en una fila INSERTADA ahora: un reintento de la cola (UPDATE) no cuenta como nuevo.
    if fila and fila.get("nuevo"):
        r["_nuevo"] = True
    return r


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
    avisos = []   # envíos nuevos con puntaje bajo: se avisa UNA vez por destinatario al final
    pushes = []   # hallazgos críticos y encargos nuevos: aviso al celular, al final

    for op in operaciones:
        op_id = op.get("opId")
        tipo = op.get("tipo")
        datos = op.get("datos") or {}
        try:
            # Cada operación en su propia transacción: una que falle por datos
            # inválidos no debe arrastrar a las que sí eran correctas.
            aviso = None
            with sesion_usuario() as cur:
                r = _upsert(cur, tipo, datos)
                nuevo = r.pop("_nuevo", False)
                if nuevo and r.get("tipo") == "envio":
                    aviso = correo_avisos.evaluar(cur, datos)
            # Solo si la transacción se confirmó: un envío revertido no debe avisar.
            if aviso:
                avisos.append(aviso)
            if nuevo and r.get("ok"):
                if r.get("tipo") == "hallazgo" and datos.get("severidad") == "critico":
                    pushes.append(("hallazgo", r["id"]))
                elif r.get("tipo") == "asignacion" and datos.get("correo"):
                    pushes.append(("encargo", r["id"]))
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
    if avisos:
        salieron = correo_avisos.enviar(avisos)
        auditar("aviso_puntaje_bajo", detalle={"inspecciones": len(avisos), "correos": salieron})
    if pushes:
        _enviar_pushes(pushes, excluir=current_user.id)

    return jsonify({"resultados": resultados, "aplicadas": aplicadas})


# ── Pruebas gratis por QR (migración 016) ───────────────────────────────────
# La página pública prueba.html?c=<código> crea la cuenta de prueba sin que un
# super administrador autorice el correo: el código de la campaña es el permiso.
_RE_CODIGO = re.compile(r"^[A-Za-z0-9_-]{8,40}$")
_RE_CORREO = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$")


@bp.route("/publico/prueba/<codigo>")
@limiter.limit("60 per minute")
def prueba_info(codigo):
    if not _RE_CODIGO.match(codigo or ""):
        return jsonify({"error": "Enlace no válido."}), 404
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT * FROM skf_prueba_info(%s)", (codigo,))
            f = cur.fetchone()
    except psycopg2.errors.UndefinedFunction:
        f = None
    if not f:
        return jsonify({"error": "Esta invitación no existe."}), 404
    return jsonify({"nombre": f["nombre"], "dias": f["dias"], "disponible": f["disponible"]})


@bp.route("/publico/prueba", methods=["POST"])
@limiter.limit("10 per hour")
def prueba_registro():
    from flask_login import login_user
    from ..auth.routes import _password_debil
    from ..security import cargar_usuario
    d = request.get_json(silent=True) or {}
    codigo, email = str(d.get("codigo") or ""), str(d.get("email") or "").strip().lower()
    nombre, password = str(d.get("nombre") or "").strip(), str(d.get("password") or "")
    if not _RE_CODIGO.match(codigo) or not _RE_CORREO.match(email) or len(nombre) < 2:
        return jsonify({"error": "Revisa tu nombre y tu correo."}), 400
    if d.get("acepto") is not True:
        return jsonify({"error": "Para crear la cuenta necesitamos tu autorización para tratar tus datos."}), 400
    problema = _password_debil(password)
    if problema:
        return jsonify({"error": problema}), 400
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT * FROM skf_prueba_registrar(%s, %s, %s, %s, %s, %s)",
                        (codigo, email, password, nombre, str(d.get("celular") or "").strip()[:30],
                         str(d.get("profesion") or "").strip()[:60]))
            r = cur.fetchone()
    except psycopg2.errors.UndefinedFunction:
        return jsonify({"error": "Las pruebas todavía no están habilitadas."}), 503
    if r["resultado"] == "campana_no_disponible":
        return jsonify({"error": "Esta invitación ya no está disponible. Pide una nueva a quien te la compartió."}), 410
    if r["resultado"] != "ok":
        # Sin decir si el correo existe: se ofrece iniciar sesión.
        return jsonify({"error": "No pudimos crear la cuenta con ese correo. Si ya tienes cuenta, inicia sesión."}), 409
    usuario = cargar_usuario(str(r["user_id"]))
    login_user(usuario, remember=True)
    auditar("prueba_registro", entidad="user", entidad_id=usuario.id, detalle={"campana": codigo})
    return jsonify({"ok": True, "destino": "clientes.html?demo=1"}), 201


# ── Qué se usa (migración 015, app/uso.py) ─────────────────────────────────
@bp.route("/uso", methods=["POST"])
@limiter.limit("120 per minute")
@requiere_sesion
def uso():
    from ..uso import contar
    contar(str((request.get_json(silent=True) or {}).get("que") or ""))
    return ("", 204)


# ── Avisos push al celular (migración 014, app/push.py) ─────────────────────
def _enviar_pushes(eventos, excluir=None) -> None:
    """Hallazgo crítico → dueños y administradores de la empresa (menos quien lo reportó).
    Encargo nuevo → la persona encargada. Nunca rompe la petición que lo origina."""
    from .. import push
    if not push.disponible():
        return
    for tipo, rid in eventos:
        try:
            with db.sesion_privilegiada(timeout_ms=3000) as cur:
                if tipo == "hallazgo":
                    cur.execute("SELECT * FROM skf_push_hallazgo_critico(%s, %s)", (rid, excluir))
                else:
                    cur.execute("SELECT * FROM skf_push_encargo(%s)", (rid,))
                subs = cur.fetchall()
        except Exception as e:   # sin la 014 o la base ocupada: sin aviso, nada más
            log.info("Push omitido (%s %s): %s", tipo, rid, e)
            continue
        if not subs:
            continue
        f = subs[0]
        if tipo == "hallazgo":
            aviso = {"titulo": f"🔴 Hallazgo crítico · {f['org']}",
                     "cuerpo": " · ".join(x for x in (f["descripcion"] or "Sin descripción", f["formulario"], f["lugar"]) if x)[:180],
                     "url": "/hallazgos.html", "tag": f"hz-{rid}"}
        else:
            limite = f" — antes del {f['fecha_limite']:%d/%m}" if f.get("fecha_limite") else ""
            aviso = {"titulo": f"👤 Te encargaron un formulario · {f['org']}",
                     "cuerpo": f"{f['formulario'] or 'Formulario'}{limite}",
                     "url": f"/llenar.html?tmpl={f['plantilla_id']}" if f.get("plantilla_id") else "/plan.html",
                     "tag": f"enc-{rid}"}
        enviados = push.enviar_a(subs, aviso)
        auditar("push_" + tipo, detalle={"id": str(rid), "dispositivos": len(subs), "enviados": enviados})


_RE_ENDPOINT = re.compile(r"^https://[A-Za-z0-9.\-]+(:\d+)?/\S{1,900}$")


@bp.route("/push/clave")
@requiere_sesion
def push_clave():
    from .. import push
    return jsonify({"disponible": push.disponible(), "clave": push.clave_publica() if push.disponible() else None})


@bp.route("/push/suscribir", methods=["POST"])
@requiere_sesion
def push_suscribir():
    d = request.get_json(silent=True) or {}
    llaves = d.get("keys") or {}
    endpoint, p256dh, auth = str(d.get("endpoint") or ""), str(llaves.get("p256dh") or ""), str(llaves.get("auth") or "")
    if not _RE_ENDPOINT.match(endpoint) or not (40 <= len(p256dh) <= 200) or not (10 <= len(auth) <= 60):
        return jsonify({"error": "Suscripción inválida."}), 400
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT skf_push_suscribir(%s, %s, %s, %s) AS r",
                        (endpoint, p256dh, auth, (request.headers.get("User-Agent") or "")[:200]))
            r = cur.fetchone()["r"]
    except psycopg2.errors.UndefinedFunction:
        return jsonify({"error": "Falta preparar la base (migración 014) para los avisos."}), 503
    if r != "ok":
        return jsonify({"error": "Necesitas iniciar sesión."}), 401
    auditar("push_activado")
    return jsonify({"ok": True}), 201


@bp.route("/push/suscribir", methods=["DELETE"])
@requiere_sesion
def push_quitar():
    endpoint = str((request.get_json(silent=True) or {}).get("endpoint") or "")
    try:
        with sesion_usuario() as cur:
            cur.execute("DELETE FROM push_suscripciones WHERE endpoint = %s", (endpoint,))
    except psycopg2.errors.UndefinedTable:
        pass
    return jsonify({"ok": True})


@bp.route("/push/probar", methods=["POST"])
@limiter.limit("6 per minute")
@requiere_sesion
def push_probar():
    """Un aviso de prueba a mis celulares (o solo a este, si manda su endpoint)."""
    from .. import push
    if not push.disponible():
        return jsonify({"error": "Los avisos al celular no están activados en este servidor."}), 503
    endpoint = (request.get_json(silent=True) or {}).get("endpoint")
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT endpoint, p256dh, auth FROM push_suscripciones" + (" WHERE endpoint = %s" if endpoint else ""),
                        (endpoint,) if endpoint else None)
            subs = cur.fetchall()
    except psycopg2.errors.UndefinedTable:
        return jsonify({"error": "Falta preparar la base (migración 014)."}), 503
    if not subs:
        return jsonify({"error": "Este celular no tiene los avisos activados."}), 404
    n = push.enviar_a(subs, {"titulo": "✅ Avisos activados", "cuerpo": "Así te llegará un hallazgo crítico o un encargo nuevo.",
                             "url": "/index.html", "tag": "prueba"})
    return jsonify({"ok": n > 0, "enviados": n, "dispositivos": len(subs)})


# ── Lectura ────────────────────────────────────────────────────────────────

@bp.route("/bootstrap")
@requiere_organizacion
def bootstrap():
    """Todo lo que la PWA necesita para funcionar sin conexión, en una llamada.

    Se pide al abrir la app con señal y se guarda en localStorage. A partir de
    ahí el inspector puede trabajar desconectado con datos frescos.
    """
    with sesion_usuario(solo_lectura=True) as cur:
        # correo_notificacion y los ajustes de aviso DEBEN viajar al cliente: si no, al reenviar
        # un formulario (p. ej. al marcarlo favorito) el cliente lo guarda sin correo y borra el
        # del servidor, apagando los avisos sin que nadie lo note. Los ajustes de aviso llegan con la
        # migración 008: sin ella se piden sin esas columnas (misma tolerancia que turnos_config).
        base = ("SELECT id, nombre, codigo, descripcion, norma, campos, logo_url, favorito, "
                "publica, share_token, es_catalogo, vertical, correo_notificacion{extra} "
                "FROM plantillas WHERE NOT archivada ORDER BY favorito DESC, actualizado_en DESC")
        cur.execute("SAVEPOINT sp_plantillas")
        try:
            cur.execute(base.format(extra=", aviso_umbral, aviso_max_hora"))
        except psycopg2.errors.UndefinedColumn:
            cur.execute("ROLLBACK TO SAVEPOINT sp_plantillas")
            cur.execute(base.format(extra=""))
        plantillas = cur.fetchall()

        cur.execute("SELECT id, nombre, tipo, padre_id FROM unidades WHERE activa ORDER BY nombre")
        unidades = cur.fetchall()

        cur.execute(
            "SELECT id, plantilla_id, plantilla_nombre, unidad_id, nombre, correo, "
            "fecha_limite, completado_en, creado_en FROM asignaciones ORDER BY creado_en DESC LIMIT 500"
        )
        asignaciones = cur.fetchall()

        cur.execute(
            "SELECT id, plantilla_id, unidad_id, nombre, frecuencia, proximo_en, "
            "responsable, activa FROM inspecciones_programadas WHERE activa ORDER BY proximo_en"
        )
        programadas = cur.fetchall()

        # turnos_config llega con la migración 006, que se corre aparte del
        # despliegue. Si el código se publica antes, la columna no existe: sin esta
        # tolerancia /api/bootstrap fallaría y la app entera dejaría de abrir.
        # El SAVEPOINT evita que el error aborte la transacción (y con ella las
        # variables de RLS que fija sesion_usuario).
        cur.execute("SAVEPOINT sp_org")
        try:
            cur.execute("SELECT id, nombre, logo_url, pais, plan, turnos_config FROM organizations WHERE id = %s",
                        (current_user.org_id,))
        except psycopg2.errors.UndefinedColumn:
            cur.execute("ROLLBACK TO SAVEPOINT sp_org")
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
    # Con el envío ya guardado: un puntaje bajo avisa por correo (una vez, con límite por hora).
    correo_avisos.avisar_publico(r["envio_id"], token)
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
    if d.get("severidad") == "critico":   # reportado por alguien sin cuenta: igual se avisa
        _enviar_pushes([("hallazgo", hz_id)])
    return jsonify({"ok": True}), 201


# ── Paneles compartidos de solo lectura ────────────────────────────────────
# Entregar el panel a un cliente o a un jefe SIN cuenta, por un enlace no
# listado. Se publica una FOTO inmutable de los datos ya filtrados, no acceso
# en vivo: el visitante ve lo que el dueño decidió enseñarle en ese momento, y
# un enlace compartido no se convierte en una ventana permanente a la
# operación. Para actualizarlo, se vuelve a compartir.

# El token es la ÚNICA credencial de un panel compartido, así que se exige que
# parezca lo que debe ser: largo y sin caracteres raros. Los que genera la app
# son UUID v4 (122 bits de azar); el mínimo de 16 deja pasar los `pnl_...`
# antiguos, más cortos, que ya estuvieran circulando.
_TOKEN_PANEL = re.compile(r"^[A-Za-z0-9_-]{16,128}$")

# Un snapshot lleva dentro los envíos y hallazgos ya filtrados: puede ser
# grande, pero no ilimitado. Sin tope, compartir un panel sin filtrar sobre un
# histórico de años deja megabytes muertos en la tabla por cada clic.
MAX_SNAPSHOT_BYTES = 4 * 1024 * 1024


def _token_panel(valor: Any) -> Optional[str]:
    t = (str(valor or "")).strip()
    return t if _TOKEN_PANEL.match(t) else None


@bp.route("/panel", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def publicar_panel():
    """Publica (o vuelve a publicar) el snapshot de un panel compartido."""
    d = request.get_json(silent=True) or {}
    token = _token_panel(d.get("token"))
    snapshot = d.get("snapshot")

    if not token:
        return jsonify({"error": "Token de panel inválido."}), 400
    if not isinstance(snapshot, dict):
        return jsonify({"error": "Falta el snapshot del panel."}), 400

    import json as _json
    crudo = _json.dumps(snapshot)
    if len(crudo.encode("utf-8")) > MAX_SNAPSHOT_BYTES:
        return jsonify({
            "error": "El panel es demasiado grande para compartirlo. "
                     "Acota el periodo o la unidad y vuelve a intentarlo."
        }), 413

    titulo = (d.get("titulo") or None)
    with sesion_usuario() as cur:
        # El WHERE del ON CONFLICT impide que republicar pise el panel de otra
        # organización si dos tokens llegaran a coincidir. RLS ya lo impediría;
        # esto lo convierte en un 409 legible en vez de un error de la base.
        cur.execute(
            """
            INSERT INTO paneles_publicos (token, org_id, titulo, snapshot)
                 VALUES (%s, %s, %s, %s)
            ON CONFLICT (token) DO UPDATE
                    SET titulo = EXCLUDED.titulo,
                        snapshot = EXCLUDED.snapshot,
                        actualizado_en = NOW()
                  WHERE paneles_publicos.org_id = EXCLUDED.org_id
              RETURNING token
            """,
            (token, current_user.org_id, titulo, psycopg2.extras.Json(snapshot)),
        )
        fila = cur.fetchone()

    if not fila:
        return jsonify({"error": "Ese enlace ya está en uso."}), 409

    auditar("panel_publicado", entidad="paneles_publicos", entidad_id=token)
    return jsonify({"ok": True, "token": token}), 201


@bp.route("/panel/<token>")
def leer_panel(token: str):
    """Lee un panel por su token. Sin sesión: es el enlace compartido.

    Va por la función SECURITY DEFINER, que devuelve UNA fila por su token
    exacto y solo el snapshot — no se puede enumerar la tabla ni averiguar de
    qué organización es el panel.
    """
    tok = _token_panel(token)
    if not tok:
        return jsonify({"error": "Panel no disponible."}), 404

    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT skf_panel_publico(%s) AS snapshot", (tok,))
        fila = cur.fetchone()

    if not fila or fila["snapshot"] is None:
        return jsonify({"error": "Panel no disponible."}), 404
    return jsonify(fila["snapshot"])


# ── Cierre del ciclo: el campo reporta lo corregido ────────────────────────
# Desde el enlace operativo, quien ejecuta la corrección la REPORTA. Es un
# reporte, no un cierre: el dueño lo ve en su panel y confirma. Por eso vive en
# su propia tabla y no toca `hallazgos.estado` — quien ejecuta no decide el
# estado del hallazgo, solo avisa de que ya lo atendió.

@bp.route("/panel/<token>/marcas")
def marcas_panel(token: str):
    """Lo ya reportado desde este enlace, para que la página lo muestre."""
    tok = _token_panel(token)
    if not tok:
        return jsonify({"marcas": []})
    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT skf_panel_marcas(%s) AS marcas", (tok,))
        return jsonify({"marcas": cur.fetchone()["marcas"] or []})


@bp.route("/panel/<token>/marca", methods=["POST"])
def marcar_corregido(token: str):
    tok = _token_panel(token)
    hallazgo_id = _uuid_valido((request.get_json(silent=True) or {}).get("hallazgoId"))
    if not tok or not hallazgo_id:
        return jsonify({"error": "Datos incompletos."}), 400

    d = request.get_json(silent=True) or {}
    with db.sesion_privilegiada() as cur:
        # La función comprueba que el token existe Y que el hallazgo es de la
        # misma organización de ese panel. Sin lo segundo, cualquiera con un
        # enlace válido podría marcar hallazgos de otro cliente pasando ids.
        cur.execute(
            "SELECT skf_panel_marcar_corregido(%s, %s, %s, %s) AS ok",
            (tok, hallazgo_id, (d.get("por") or "")[:120], (d.get("nota") or "")[:500]),
        )
        ok = cur.fetchone()["ok"]

    if not ok:
        return jsonify({"error": "No se pudo registrar la corrección."}), 403
    return jsonify({"ok": True}), 201


@bp.route("/panel/<token>/marca/<hallazgo_id>", methods=["DELETE"])
def desmarcar_corregido(token: str, hallazgo_id: str):
    tok = _token_panel(token)
    hz = _uuid_valido(hallazgo_id)
    if not tok or not hz:
        return jsonify({"error": "Datos incompletos."}), 400

    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT skf_panel_desmarcar_corregido(%s, %s) AS ok", (tok, hz))
        ok = cur.fetchone()["ok"]

    if not ok:
        return jsonify({"error": "No se pudo deshacer la marca."}), 403
    return jsonify({"ok": True})


@bp.route("/correcciones")
@requiere_organizacion
def correcciones():
    """Todo lo reportado desde los enlaces de la organización. Lo lee el dueño
    en su panel para saber qué dice el campo que ya está corregido."""
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute(
            "SELECT hallazgo_id, marcado_por, nota, marcado_en "
            "FROM correcciones_campo ORDER BY marcado_en DESC LIMIT 2000"
        )
        return jsonify({"correcciones": cur.fetchall()})


# ── Cierre y reapertura de hallazgos ───────────────────────────────────────
# Un clic desde el panel. El UPDATE toca solo lo del cierre: la fila puede venir
# de la nube con campos que la página no conoce, y reescribirla entera sería
# arriesgarse a pisarlos.

@bp.route("/hallazgos/<hallazgo_id>/cerrar", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def cerrar_hallazgo(hallazgo_id: str):
    hz = _uuid_valido(hallazgo_id)
    if not hz:
        return jsonify({"error": "Id inválido."}), 400

    por = ((request.get_json(silent=True) or {}).get("por") or "")[:120] or None
    with sesion_usuario() as cur:
        cur.execute(
            "UPDATE hallazgos SET estado = 'cerrado', cerrado_en = NOW(), cerrado_por = %s "
            "WHERE id = %s RETURNING id",
            (por, hz),
        )
        fila = cur.fetchone()

    if not fila:
        return jsonify({"error": "No encontrado."}), 404
    auditar("hallazgo_cerrado", entidad="hallazgos", entidad_id=hz, detalle={"por": por})
    return jsonify({"ok": True})


@bp.route("/hallazgos/<hallazgo_id>/reabrir", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def reabrir_hallazgo(hallazgo_id: str):
    hz = _uuid_valido(hallazgo_id)
    if not hz:
        return jsonify({"error": "Id inválido."}), 400

    with sesion_usuario() as cur:
        cur.execute(
            "UPDATE hallazgos SET estado = 'abierto', cerrado_en = NULL, cerrado_por = NULL "
            "WHERE id = %s RETURNING id",
            (hz,),
        )
        fila = cur.fetchone()

    if not fila:
        return jsonify({"error": "No encontrado."}), 404
    # Reabrir es tan digno de bitácora como cerrar: alguien decidió que aquello
    # no estaba resuelto, y esa decisión también tiene dueño y fecha.
    auditar("hallazgo_reabierto", entidad="hallazgos", entidad_id=hz)
    return jsonify({"ok": True})


# ── Equipo: la propia empresa invita y administra a su gente (migración 009) ───
# Las reglas (solo dueño/admin, nadie nombra dueño, nadie se toca a sí mismo, todo
# dentro de la organización activa) viven en las funciones de la base: esta capa solo
# traduce sus respuestas a mensajes claros.
_EQUIPO_MSG = {
    "sin_permiso": ("Solo el dueño o un administrador puede hacer esto.", 403),
    "rol_invalido": ("Ese permiso no existe.", 400),
    "correo_invalido": ("Revisa el correo: no parece válido.", 400),
    "no_disponible": ("No se puede invitar ese correo. Si ya usa SEKaform en otra empresa, escríbenos.", 409),
    "a_ti_mismo": ("No puedes cambiar tu propio permiso ni quitarte del equipo.", 400),
    "es_dueno": ("Al dueño de la cuenta no se le puede cambiar el permiso ni quitar.", 403),
    "solo_dueno": ("Solo el dueño de la cuenta puede nombrar o cambiar administradores.", 403),
    "no_encontrado": ("Esa persona no está en tu equipo.", 404),
    "no_encontrada": ("Esa invitación ya no existe.", 404),
}


def _equipo_resp(resultado: str, **extra):
    if resultado in ("ok", "renovada"):
        return jsonify({"ok": True, "resultado": resultado, **extra})
    msg, codigo = _EQUIPO_MSG.get(resultado, ("No se pudo completar.", 400))
    return jsonify({"error": msg, "resultado": resultado}), codigo


def _sin_migracion_009(e) -> bool:
    return isinstance(e, (psycopg2.errors.UndefinedFunction,))


@bp.route("/equipo")
@requiere_organizacion
def equipo():
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT * FROM skf_equipo_listar() ORDER BY tipo DESC, nombre NULLS LAST, email")
            filas = cur.fetchall()
    except Exception as e:
        if _sin_migracion_009(e):
            return jsonify({"disponible": False, "miembros": [], "invitaciones": [], "miRol": current_user.rol})
        raise
    miembros = [{"id": f["id"], "email": f["email"], "nombre": f["nombre"] or "", "rol": f["rol"],
                 "desde": f["desde"], "ultimoIngreso": f["ultimo_ingreso"], "soyYo": str(f["id"]) == str(current_user.id)}
                for f in filas if f["tipo"] == "miembro"]
    invit = [{"id": f["id"], "email": f["email"], "rol": f["rol"], "desde": f["desde"], "expira": f["expira_en"]}
             for f in filas if f["tipo"] == "invitacion"]
    return jsonify({"disponible": True, "miembros": miembros, "invitaciones": invit, "miRol": current_user.rol})


@bp.route("/equipo/invitar", methods=["POST"])
@requiere_organizacion
def equipo_invitar():
    d = request.get_json(silent=True) or {}
    email = (d.get("email") or "").strip().lower()
    rol = (d.get("rol") or "editor").strip()
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT * FROM skf_equipo_invitar(%s, %s, 14)", (email, rol))
            r = cur.fetchone()
    except Exception as e:
        if _sin_migracion_009(e):
            return jsonify({"error": "Falta preparar la base (migración 009) para invitar desde la app."}), 503
        raise
    if r["resultado"] not in ("ok", "renovada"):
        return _equipo_resp(r["resultado"])
    from ..config import Config
    enlace = f"{Config.URL_PUBLICA or request.host_url.rstrip('/')}/registro?email={email}"
    enviado = correo_avisos.enviar_invitacion(email, current_user.org_nombre or "tu empresa",
                                        current_user.nombre or current_user.email, rol, enlace)
    auditar("equipo_invitar", entidad="authorized_email", entidad_id=str(r["invitacion_id"]),
            detalle={"email": email, "rol": rol, "correoEnviado": enviado})
    return _equipo_resp(r["resultado"], id=r["invitacion_id"], enlace=enlace, correoEnviado=enviado)


@bp.route("/equipo/invitacion/<uuid:inv_id>", methods=["DELETE"])
@requiere_organizacion
def equipo_revocar(inv_id):
    with sesion_usuario() as cur:
        cur.execute("SELECT skf_equipo_revocar(%s) AS r", (str(inv_id),))
        r = cur.fetchone()["r"]
    if r == "ok":
        auditar("equipo_revocar", entidad="authorized_email", entidad_id=str(inv_id))
    return _equipo_resp(r)


@bp.route("/equipo/<uuid:user_id>/rol", methods=["POST"])
@requiere_organizacion
def equipo_rol(user_id):
    rol = ((request.get_json(silent=True) or {}).get("rol") or "").strip()
    with sesion_usuario() as cur:
        cur.execute("SELECT skf_equipo_cambiar_rol(%s, %s) AS r", (str(user_id), rol))
        r = cur.fetchone()["r"]
    if r == "ok":
        auditar("equipo_rol", entidad="user", entidad_id=str(user_id), detalle={"rol": rol})
    return _equipo_resp(r)


@bp.route("/equipo/<uuid:user_id>", methods=["DELETE"])
@requiere_organizacion
def equipo_quitar(user_id):
    with sesion_usuario() as cur:
        cur.execute("SELECT skf_equipo_quitar(%s) AS r", (str(user_id),))
        r = cur.fetchone()["r"]
    if r == "ok":
        auditar("equipo_quitar", entidad="user", entidad_id=str(user_id))
    return _equipo_resp(r)


# ── Varias empresas y asesores (migración 010) ───────────────────────────────
# Un asesor de SST atiende a varias empresas. La empresa activa vive en la sesión y
# la base la valida en cada petición (skf_auth_perfil_en): elegir una empresa de la
# que no se es miembro no da acceso a nada.
_ASESOR_MSG = {"sin_permiso": ("Solo una cuenta de asesor puede crear empresas clientes.", 403),
               "nombre_invalido": ("Escribe el nombre de la empresa (2 a 120 caracteres).", 400),
               "limite": ("Llegaste al límite de empresas nuevas por hoy.", 429)}


def _sin_010(e) -> bool:
    return isinstance(e, psycopg2.errors.UndefinedFunction)


@bp.route("/empresas")
@requiere_sesion
def empresas():
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT * FROM skf_mis_empresas()")
            filas = cur.fetchall()
    except Exception as e:
        if not _sin_010(e):
            raise
        filas = [{"org_id": current_user.org_id, "nombre": current_user.org_nombre, "pais": None, "rol": current_user.rol}] if current_user.org_id else []
    return jsonify({"activa": current_user.org_id, "esAsesor": current_user.es_asesor,
                    "empresas": [{"id": str(f["org_id"]), "nombre": f["nombre"], "pais": f.get("pais"), "rol": f["rol"]} for f in filas]})


@bp.route("/empresas/activa", methods=["POST"])
@requiere_sesion
def empresa_activa():
    from flask import session
    org = _uuid_valido((request.get_json(silent=True) or {}).get("orgId"))
    if not org:
        return jsonify({"error": "Falta la empresa."}), 400
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT 1 FROM skf_mis_empresas() WHERE org_id = %s", (org,))
            ok = cur.fetchone()
    except Exception as e:
        if _sin_010(e):
            return jsonify({"error": "Falta preparar la base (migración 010) para cambiar de empresa."}), 503
        raise
    if not ok:
        return jsonify({"error": "No perteneces a esa empresa."}), 403
    session["org_activa"] = org
    auditar("cambio_empresa", entidad="organization", entidad_id=org, org_id=org)
    return jsonify({"ok": True, "activa": org})


@bp.route("/asesor/empresas", methods=["POST"])
@requiere_sesion
def asesor_crear_empresa():
    if current_user.prueba_vencida:
        return jsonify({"error": "Tu prueba terminó. Escríbenos para seguir usando SEKaform."}), 403
    d = request.get_json(silent=True) or {}
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT * FROM skf_asesor_crear_empresa(%s, %s)", ((d.get("nombre") or "").strip(), (d.get("pais") or "").strip()))
            r = cur.fetchone()
    except Exception as e:
        if _sin_010(e):
            return jsonify({"error": "Falta preparar la base (migración 010)."}), 503
        raise
    if r["resultado"] != "ok":
        msg, codigo = _ASESOR_MSG.get(r["resultado"], ("No se pudo crear la empresa.", 400))
        return jsonify({"error": msg, "resultado": r["resultado"]}), codigo
    auditar("asesor_crea_empresa", entidad="organization", entidad_id=str(r["org_id"]), org_id=str(r["org_id"]),
            detalle={"nombre": d.get("nombre")})
    if not current_user.org_id:          # su primera empresa: queda activa de una vez
        from flask import session
        session["org_activa"] = str(r["org_id"])
    return jsonify({"ok": True, "id": str(r["org_id"])}), 201


@bp.route("/asesor/resumen")
@requiere_sesion
def asesor_resumen():
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT * FROM skf_asesor_resumen()")
            filas = cur.fetchall()
    except Exception as e:
        if _sin_010(e):
            return jsonify({"disponible": False, "empresas": []})
        raise
    return jsonify({"disponible": True, "activa": current_user.org_id, "empresas": [{
        "id": str(f["org_id"]), "nombre": f["nombre"], "pais": f["pais"], "rol": f["rol"],
        "envios30d": f["envios_30d"], "ultimoEnvio": f["ultimo_envio"], "hallazgosAbiertos": f["hallazgos_abiertos"],
        "criticosAbiertos": f["criticos_abiertos"], "accionesVencidas": f["acciones_vencidas"],
        "formularios": f["formularios"], "tieneDueno": f["tiene_dueno"], "evidencia": f["evidencia"] or []} for f in filas]})


@bp.route("/equipo/agregar", methods=["POST"])
@requiere_organizacion
def equipo_agregar():
    d = request.get_json(silent=True) or {}
    email, rol = (d.get("email") or "").strip().lower(), (d.get("rol") or "editor").strip()
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT skf_equipo_agregar_existente(%s, %s) AS r", (email, rol))
            r = cur.fetchone()["r"]
    except Exception as e:
        if _sin_010(e):
            return jsonify({"error": "Falta preparar la base (migración 010)."}), 503
        raise
    if r == "ok":
        auditar("equipo_agregar", entidad="user", detalle={"email": email, "rol": rol})
        return jsonify({"ok": True})
    if r == "ya_miembro":
        return jsonify({"error": "Esa persona ya está en tu equipo.", "resultado": r}), 409
    if r == "no_disponible":
        return jsonify({"error": "Ese correo no tiene cuenta en SEKaform: invítalo para que cree una.", "resultado": r}), 404
    return _equipo_resp(r)


# ── Equipos dados de baja (migración 012) ───────────────────────────────────
_RE_COD_EQUIPO = re.compile(r"^[^\x00-\x1f<>]{1,40}$")


def _sin_012(e) -> bool:
    return isinstance(e, psycopg2.errors.UndefinedTable)


@bp.route("/equipos/bajas")
@requiere_organizacion
def equipos_bajas():
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT codigo, motivo, baja_en FROM equipos_baja WHERE org_id = %s ORDER BY codigo",
                        (current_user.org_id,))
            filas = cur.fetchall()
    except Exception as e:
        if _sin_012(e):
            return jsonify({"disponible": False, "bajas": []})
        raise
    return jsonify({"disponible": True, "bajas": [{"codigo": f["codigo"], "motivo": f["motivo"], "bajaEn": f["baja_en"]} for f in filas]})


@bp.route("/equipos/baja", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def equipo_dar_baja():
    d = request.get_json(silent=True) or {}
    codigo = str(d.get("codigo") or "").strip()
    motivo = (str(d.get("motivo") or "").strip() or None)
    if not _RE_COD_EQUIPO.match(codigo):
        return jsonify({"error": "Código de equipo inválido."}), 400
    if motivo and len(motivo) > 120:
        motivo = motivo[:120]
    try:
        with sesion_usuario() as cur:
            cur.execute("""INSERT INTO equipos_baja (org_id, codigo, motivo) VALUES (%s, %s, %s)
                           ON CONFLICT (org_id, codigo) DO UPDATE SET motivo = EXCLUDED.motivo, baja_en = NOW()
                           RETURNING baja_en""", (current_user.org_id, codigo, motivo))
            baja_en = cur.fetchone()["baja_en"]
    except Exception as e:
        if _sin_012(e):
            return jsonify({"error": "Falta preparar la base (migración 012) para dar de baja equipos."}), 503
        raise
    auditar("equipo_baja", entidad="equipo", detalle={"codigo": codigo, "motivo": motivo})
    return jsonify({"ok": True, "baja": {"codigo": codigo, "motivo": motivo, "bajaEn": baja_en}}), 201


@bp.route("/equipos/baja/<path:codigo>", methods=["DELETE"])
@requiere_organizacion
@requiere_escritura
def equipo_reactivar(codigo):
    try:
        with sesion_usuario() as cur:
            cur.execute("DELETE FROM equipos_baja WHERE org_id = %s AND codigo = %s", (current_user.org_id, codigo))
            n = cur.rowcount
    except Exception as e:
        if _sin_012(e):
            return jsonify({"error": "Falta preparar la base (migración 012)."}), 503
        raise
    if not n:
        return jsonify({"error": "Ese equipo no estaba dado de baja."}), 404
    auditar("equipo_reactivar", entidad="equipo", detalle={"codigo": codigo})
    return jsonify({"ok": True})


# ── Portal del cliente (migración 011): resumen en vivo por enlace ───────────
def _sin_011(e) -> bool:
    return isinstance(e, psycopg2.errors.UndefinedFunction)


_RE_FOTO = re.compile(r"^(data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+|https://storage\.googleapis\.com/\S+)$")


def _url_portal(token: str) -> str:
    from ..config import Config
    return f"{Config.URL_PUBLICA or request.host_url.rstrip('/')}/portal.html?t={token}"


@bp.route("/portal")
@requiere_organizacion
def portal_actual():
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("SELECT * FROM skf_portal_actual()")
            f = cur.fetchone()
    except Exception as e:
        if _sin_011(e):
            return jsonify({"disponible": False})
        raise
    if not f:
        return jsonify({"disponible": True, "portal": None})
    return jsonify({"disponible": True, "portal": {"url": _url_portal(f["token"]), "creadoEn": f["creado_en"],
                                                   "accesos": f["accesos"], "ultimoAcceso": f["ultimo_acceso"],
                                                   # None = falta la 013: el portal no puede mostrar fotos todavía
                                                   "mostrarFotos": f.get("mostrar_fotos")}})


@bp.route("/portal", methods=["POST"])
@requiere_organizacion
def portal_crear():
    fotos = (request.get_json(silent=True) or {}).get("fotos")
    try:
        with sesion_usuario() as cur:
            # Con la 013 se elige si muestra el antes y después; sin ella, el portal de siempre.
            cur.execute("SAVEPOINT sp_portal")
            try:
                cur.execute("SELECT * FROM skf_portal_crear(%s)", (fotos if isinstance(fotos, bool) else True,))
            except psycopg2.errors.UndefinedFunction:
                cur.execute("ROLLBACK TO SAVEPOINT sp_portal")
                cur.execute("SELECT * FROM skf_portal_crear()")
            r = cur.fetchone()
    except Exception as e:
        if _sin_011(e):
            return jsonify({"error": "Falta preparar la base (migración 011) para el portal."}), 503
        raise
    if r["resultado"] != "ok":
        return jsonify({"error": "Solo el dueño o un administrador puede crear el portal."}), 403
    auditar("portal_crear", entidad="portal")
    return jsonify({"ok": True, "portal": {"url": _url_portal(r["token"]), "accesos": 0, "ultimoAcceso": None}}), 201


@bp.route("/portal/fotos", methods=["POST"])
@requiere_organizacion
def portal_fotos():
    fotos = (request.get_json(silent=True) or {}).get("fotos")
    if not isinstance(fotos, bool):
        return jsonify({"error": "Indica si se muestran las fotos."}), 400
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT skf_portal_fotos(%s) AS r", (fotos,))
            r = cur.fetchone()["r"]
    except Exception as e:
        if _sin_011(e):
            return jsonify({"error": "Falta preparar la base (migración 013) para mostrar fotos en el portal."}), 503
        raise
    if r == "sin_permiso":
        return jsonify({"error": "Solo el dueño o un administrador puede cambiarlo."}), 403
    if r != "ok":
        return jsonify({"error": "No hay un portal activo."}), 404
    auditar("portal_fotos", entidad="portal", detalle={"fotos": fotos})
    return jsonify({"ok": True, "mostrarFotos": fotos})


@bp.route("/hallazgos/<hallazgo_id>/foto-portal", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def hallazgo_foto_portal(hallazgo_id):
    """Ocultar (o volver a mostrar) en el portal las fotos de un hallazgo."""
    hz = _uuid_valido(hallazgo_id)
    oculta = (request.get_json(silent=True) or {}).get("oculta")
    if not hz or not isinstance(oculta, bool):
        return jsonify({"error": "Datos inválidos."}), 400
    try:
        with sesion_usuario() as cur:
            cur.execute("UPDATE hallazgos SET foto_oculta_portal = %s WHERE id = %s RETURNING id", (oculta, hz))
            fila = cur.fetchone()
    except psycopg2.errors.UndefinedColumn:
        return jsonify({"error": "Falta preparar la base (migración 013)."}), 503
    if not fila:
        return jsonify({"error": "No encontrado."}), 404
    auditar("hallazgo_foto_portal", entidad="hallazgos", entidad_id=hz, detalle={"oculta": oculta})
    return jsonify({"ok": True, "oculta": oculta})


@bp.route("/portal", methods=["DELETE"])
@requiere_organizacion
def portal_revocar():
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT skf_portal_revocar() AS r")
            r = cur.fetchone()["r"]
    except Exception as e:
        if _sin_011(e):
            return jsonify({"error": "Falta preparar la base (migración 011)."}), 503
        raise
    if r == "sin_permiso":
        return jsonify({"error": "Solo el dueño o un administrador puede desactivar el portal."}), 403
    auditar("portal_revocar", entidad="portal")
    return jsonify({"ok": True})


# El portal es público y se abre por enlace: se limita por IP para que no se pueda usar
# para adivinar tokens ni para cargar la base. (El límite va junto a la ruta: aplicado
# después de registrarla, Flask-Limiter no lo reconoce.)
@bp.route("/publico/portal/<token>")
@limiter.limit("60 per minute")
def portal_publico(token: str):
    """Lo que ve el cliente. Las respuestas de cada inspección se usan aquí SOLO para
    calcular su puntaje y no salen del servidor: el portal muestra resúmenes."""
    from ..puntaje import puntaje
    if not re.fullmatch(r"[A-Za-z0-9_\-]{32,128}", token or ""):
        return jsonify({"error": "Portal no disponible."}), 404
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT skf_portal_datos(%s) AS d", (token,))
            d = cur.fetchone()["d"]
    except Exception as e:
        if _sin_011(e):
            return jsonify({"error": "Portal no disponible."}), 404
        raise
    if not d or not d.get("org"):
        return jsonify({"error": "Este portal ya no está disponible. Pide un enlace nuevo."}), 404
    insp, pcts = [], []
    for i in d.get("inspecciones") or []:
        p = puntaje(i.get("campos"), i.get("datos"))
        if p:
            pcts.append(p["pct"])
        insp.append({"formulario": i.get("formulario"), "fecha": i.get("fecha"), "lugar": i.get("lugar"),
                     "pct": p["pct"] if p else None, "nivel": p["nivel"] if p else None})
    # Solo imágenes de verdad (lo guardado viene de los teléfonos): lo demás no sale.
    hallazgos = []
    for h in d.get("hallazgos") or []:
        h = dict(h)
        for k in ("antes", "despues"):
            if k in h and not (isinstance(h[k], str) and _RE_FOTO.match(h[k])):
                h.pop(k)
        hallazgos.append(h)
    resp = jsonify({"org": d["org"], "evidencia": d.get("evidencia") or [], "inspecciones": insp,
                    "hallazgos": hallazgos, "envios30d": d.get("envios_30d") or 0,
                    "puntajePromedio": round(sum(pcts) / len(pcts)) if pcts else None})
    resp.headers["Cache-Control"] = "no-store"
    resp.headers["X-Robots-Tag"] = "noindex"
    return resp


def registrar_api(app, csrf) -> None:
    app.register_blueprint(bp)
    # Los envíos públicos llegan de gente sin sesión y, por tanto, sin token
    # CSRF. No hay nada que proteger: no existe sesión que suplantar, y la
    # única escritura posible es contra una plantilla marcada como pública.
    csrf.exempt(publico_envio)
    # El registro de prueba llega de alguien sin sesión (sin token CSRF que traer).
    csrf.exempt(prueba_registro)
    csrf.exempt(publico_hallazgo)
    # Igual que los envíos públicos: quien abre un panel compartido no tiene
    # sesión, así que no hay token CSRF que traer ni sesión que suplantar. Lo
    # único que puede hacer es marcar un hallazgo de la organización dueña de
    # ese token, y eso lo valida la función en la base.
    csrf.exempt(marcar_corregido)
    csrf.exempt(desmarcar_corregido)
