"""Control de trabajos (migración 017): el portón del edificio.

Tres públicos distintos usan estas rutas:

* **El comité del edificio** (o un administrador con el relevo tomado) ve la
  cola de su edificio, revisa los requisitos y autoriza, rechaza o cierra.
* **El director** (dueño o administrador) ve todos los edificios, nombra a los
  encargados, genera el enlace de solicitudes y puede tomar el relevo.
* **Gente sin cuenta**: quien solicita un trabajo por enlace y el vigilante que
  consulta si un trabajo puede iniciar. Solo pasan por funciones de la base que
  derivan todo del token.

Lo que el servidor nunca delega en el navegador: la lista de requisitos (sale
de app/trabajos.py), la regla de que todo debe cumplirse para autorizar y que
un trabajo crítico exige verificación en el sitio.
"""

from __future__ import annotations

import datetime
import re
from typing import Any, Optional

import psycopg2
import psycopg2.extras
from flask import jsonify, request
from flask_login import current_user

from .. import db, limiter
from .. import trabajos as cat
from ..security import (auditar, requiere_admin_org, requiere_escritura,
                        requiere_organizacion, sesion_usuario)
from . import _uuid_valido, bp

_RE_TOKEN = re.compile(r"^[A-Za-z0-9_\-]{24,128}$")
_RE_FOTO = re.compile(r"^data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$")
_MAX_FOTO = 700_000          # ~500 KB de imagen ya comprimida por el teléfono
_COLS = ("id, unidad_id, numero, token, titulo, tipo, criticidad, origen, quien, lugar, contacto, fecha, estado, "
         "requisitos, verificado_en_sitio, firma_ejecuta, firma_responsable, via, decidido_nombre, decidido_en, "
         "en_relevo, motivo, cerrado_en, registro, creado_en")


def _sin_017(e: Exception) -> bool:
    return isinstance(e, (psycopg2.errors.UndefinedTable, psycopg2.errors.UndefinedFunction,
                          psycopg2.errors.UndefinedColumn))


_FALTA_017 = "Falta preparar la base (migración 017) para el control de trabajos."


def _texto(valor: Any, maximo: int) -> Optional[str]:
    t = " ".join(str(valor or "").split())
    return t[:maximo] or None


def _fecha(valor: Any) -> Optional[str]:
    try:
        return datetime.date.fromisoformat(str(valor)[:10]).isoformat()
    except ValueError:
        return None


def _yo() -> str:
    return current_user.nombre or current_user.email


def _nota(que: str) -> psycopg2.extras.Json:
    """Una línea del registro del permiso. La hora la pone el servidor."""
    return psycopg2.extras.Json([{"en": datetime.datetime.now(datetime.timezone.utc).isoformat(), "que": que, "por": _yo()}])


def _json(f: dict, *, fotos: bool = False) -> dict[str, Any]:
    d = {"id": f["id"], "unidadId": f["unidad_id"], "numero": f["numero"], "token": f["token"],
         "titulo": f["titulo"], "tipo": f["tipo"], "criticidad": f["criticidad"], "origen": f["origen"],
         "quien": f["quien"], "lugar": f["lugar"], "contacto": f["contacto"], "fecha": f["fecha"],
         "estado": f["estado"], "requisitos": f["requisitos"] or {}, "verificadoEnSitio": f["verificado_en_sitio"],
         "firmaEjecuta": f["firma_ejecuta"], "firmaResponsable": f["firma_responsable"], "via": f["via"],
         "decididoPor": f["decidido_nombre"], "decididoEn": f["decidido_en"], "enRelevo": f["en_relevo"],
         "motivo": f["motivo"], "cerradoEn": f["cerrado_en"], "registro": f["registro"] or [],
         "creadoEn": f["creado_en"]}
    if fotos:
        d["fotos"] = f.get("fotos") or {}
    return d


def _datos_solicitud(d: dict) -> tuple[Optional[dict], Optional[str]]:
    """Valida lo que llega para abrir un trabajo. Devuelve (datos, error)."""
    tipo, origen = str(d.get("tipo") or ""), str(d.get("origen") or "")
    if tipo not in cat.TIPOS:
        return None, "Elige el tipo de trabajo."
    if origen not in cat.ORIGENES:
        return None, "Indica quién hace el trabajo."
    titulo, quien, fecha = _texto(d.get("titulo"), 140), _texto(d.get("quien"), 140), _fecha(d.get("fecha"))
    if not titulo or len(titulo) < 3:
        return None, "Describe el trabajo en pocas palabras."
    if not quien or len(quien) < 2:
        return None, "Escribe la empresa o las personas que harán el trabajo."
    if not fecha:
        return None, "Indica el día del trabajo."
    return {"titulo": titulo, "tipo": tipo, "criticidad": cat.TIPOS[tipo]["criticidad"], "origen": origen,
            "quien": quien, "lugar": _texto(d.get("lugar"), 140), "contacto": _texto(d.get("contacto"), 80),
            "fecha": fecha, "firma_ejecuta": _texto(d.get("firmaEjecuta"), 120),
            "firma_responsable": _texto(d.get("firmaResponsable"), 120)}, None


# ── Catálogo y tablero ──────────────────────────────────────────────────────
@bp.route("/trabajos/catalogo")
@requiere_organizacion
def trabajos_catalogo():
    return jsonify(cat.catalogo())


@bp.route("/trabajos/tablero")
@requiere_organizacion
def trabajos_tablero():
    """Los edificios que le tocan a quien pregunta, con su estado de hoy."""
    hoy = _fecha(request.args.get("hoy")) or datetime.date.today().isoformat()
    admin = bool(current_user.es_admin_org)
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            cur.execute("""
                SELECT u.id, u.nombre, u.relevo_por, u.relevo_desde, (u.token_solicitud IS NOT NULL) AS enlace,
                       COALESCE(NULLIF(ru.nombre, ''), ru.email::text) AS relevo_nombre,
                       skf_atiende_unidad(u.id) AS atiendo,
                       COALESCE((SELECT jsonb_agg(jsonb_build_object('id', e.user_id,
                                   'nombre', COALESCE(NULLIF(us.nombre, ''), us.email::text)) ORDER BY us.nombre)
                                 FROM unidad_encargados e JOIN users us ON us.id = e.user_id
                                 WHERE e.unidad_id = u.id), '[]'::jsonb) AS encargados
                  FROM unidades u LEFT JOIN users ru ON ru.id = u.relevo_por
                 WHERE u.org_id = %s AND u.activa AND u.tipo = 'sede'
                 ORDER BY u.nombre""", (current_user.org_id,))
            unidades = cur.fetchall()
            cur.execute("""
                SELECT unidad_id,
                       count(*) FILTER (WHERE estado = 'pendiente') AS pendientes,
                       count(*) FILTER (WHERE estado = 'pendiente' AND criticidad = 'critico') AS criticos_pendientes,
                       min(creado_en) FILTER (WHERE estado = 'pendiente' AND criticidad = 'critico') AS critico_desde,
                       count(*) FILTER (WHERE estado = 'autorizado' AND fecha = %s) AS en_curso,
                       count(*) FILTER (WHERE fecha = %s) AS hoy
                  FROM trabajos WHERE org_id = %s GROUP BY unidad_id""", (hoy, hoy, current_user.org_id))
            por_unidad = {str(f["unidad_id"]): f for f in cur.fetchall()}
            cur.execute("""
                SELECT tipo,
                       count(*) AS total,
                       count(*) FILTER (WHERE estado IN ('autorizado', 'cerrado')) AS autorizados,
                       count(*) FILTER (WHERE estado = 'rechazado') AS rechazados,
                       count(*) FILTER (WHERE estado = 'pendiente' AND fecha < %s) AS sin_atender
                  FROM trabajos WHERE org_id = %s AND creado_en > NOW() - INTERVAL '30 days'
                 GROUP BY tipo""", (hoy, current_user.org_id))
            por_tipo = cur.fetchall()
    except Exception as e:
        if _sin_017(e):
            return jsonify({"disponible": False, "edificios": []})
        raise
    edificios = []
    for u in unidades:
        if not admin and not u["atiendo"]:
            continue        # el encargado solo ve los edificios por los que responde
        n = por_unidad.get(str(u["id"]), {})
        edificios.append({
            "id": u["id"], "nombre": u["nombre"], "encargados": u["encargados"], "atiendo": u["atiendo"],
            "relevoPor": u["relevo_por"], "relevoNombre": u["relevo_nombre"], "relevoDesde": u["relevo_desde"],
            "relevoMio": str(u["relevo_por"]) == str(current_user.id), "tieneEnlace": u["enlace"],
            "pendientes": n.get("pendientes", 0), "criticosPendientes": n.get("criticos_pendientes", 0),
            "criticoDesde": n.get("critico_desde"), "enCurso": n.get("en_curso", 0), "hoy": n.get("hoy", 0)})
    return jsonify({"disponible": True, "soyAdmin": admin, "yo": {"id": current_user.id, "nombre": _yo()},
                    "edificios": edificios,
                    "porTipo": [{"tipo": f["tipo"], "total": f["total"], "autorizados": f["autorizados"],
                                 "rechazados": f["rechazados"], "sinAtender": f["sin_atender"]} for f in por_tipo]})


# ── Cola de un edificio y detalle ───────────────────────────────────────────
@bp.route("/trabajos")
@requiere_organizacion
def trabajos_lista():
    unidad = _uuid_valido(request.args.get("unidad"))
    hoy = _fecha(request.args.get("hoy")) or datetime.date.today().isoformat()
    if not unidad:
        return jsonify({"error": "Falta el edificio."}), 400
    try:
        with sesion_usuario(solo_lectura=True) as cur:
            # Lo pendiente sale siempre (aunque sea de otro día); lo demás, solo lo de hoy.
            cur.execute(f"""SELECT {_COLS} FROM trabajos
                             WHERE unidad_id = %s AND (estado = 'pendiente' OR fecha = %s)
                             ORDER BY creado_en LIMIT 300""", (unidad, hoy))
            filas = cur.fetchall()
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": _FALTA_017}), 503
        raise
    return jsonify({"trabajos": [_json(f) for f in filas]})


@bp.route("/trabajos/<trabajo_id>")
@requiere_organizacion
def trabajo_detalle(trabajo_id: str):
    tid = _uuid_valido(trabajo_id)
    if not tid:
        return jsonify({"error": "No encontrado."}), 404
    with sesion_usuario(solo_lectura=True) as cur:
        cur.execute(f"SELECT {_COLS}, fotos, skf_atiende_unidad(unidad_id) AS atiendo FROM trabajos WHERE id = %s", (tid,))
        f = cur.fetchone()
    if not f:
        return jsonify({"error": "No encontrado."}), 404
    d = _json(f, fotos=True)
    d["puedoDecidir"] = bool(f["atiendo"]) and current_user.puede_escribir
    return jsonify({"trabajo": d})


@bp.route("/trabajos", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def trabajo_crear():
    """El comité abre un trabajo a mano (personal propio, o alguien que llegó sin solicitud)."""
    d = request.get_json(silent=True) or {}
    unidad = _uuid_valido(d.get("unidadId"))
    datos, error = _datos_solicitud(d)
    if not unidad or error:
        return jsonify({"error": error or "Falta el edificio."}), 400
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_') AS t")
            token = cur.fetchone()["t"]
            try:
                cur.execute(f"""
                    INSERT INTO trabajos (org_id, unidad_id, token, titulo, tipo, criticidad, origen, quien, lugar,
                                          contacto, fecha, firma_ejecuta, firma_responsable, via, creado_por, registro)
                    VALUES (%(org)s, %(unidad)s, %(token)s, %(titulo)s, %(tipo)s, %(criticidad)s, %(origen)s,
                            %(quien)s, %(lugar)s, %(contacto)s, %(fecha)s, %(firma_ejecuta)s, %(firma_responsable)s,
                            'comite', %(por)s, %(registro)s)
                    RETURNING {_COLS}""",
                            {**datos, "org": current_user.org_id, "unidad": unidad, "token": token,
                             "por": current_user.id, "registro": _nota("Trabajo abierto por el comité")})
            except psycopg2.errors.InsufficientPrivilege:
                return jsonify({"error": "No respondes por este edificio. Si eres administrador, toma el relevo primero."}), 403
            f = cur.fetchone()
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": _FALTA_017}), 503
        raise
    auditar("trabajo_crear", entidad="trabajos", entidad_id=str(f["id"]), detalle={"tipo": f["tipo"]})
    return jsonify({"ok": True, "trabajo": _json(f)}), 201


def _cambiar(trabajo_id: str, accion: str):
    """Requisitos, autorizar, rechazar y cerrar comparten candado, permisos y registro."""
    tid = _uuid_valido(trabajo_id)
    d = request.get_json(silent=True) or {}
    if not tid:
        return jsonify({"error": "No encontrado."}), 404
    try:
        with sesion_usuario() as cur:
            cur.execute("""SELECT t.*, skf_atiende_unidad(t.unidad_id) AS atiendo,
                                  (u.relevo_por = skf_user_id()) AS relevo_mio
                             FROM trabajos t JOIN unidades u ON u.id = t.unidad_id
                            WHERE t.id = %s""", (tid,))
            t = cur.fetchone()
            if not t:
                return jsonify({"error": "No encontrado."}), 404
            if not t["atiendo"]:
                return jsonify({"error": "No respondes por este edificio. Si eres administrador, toma el relevo primero."}), 403
            relevo = bool(t["relevo_mio"])
            sufijo = " (en relevo del comité)" if relevo else ""

            if accion == "requisitos":
                if t["estado"] != "pendiente":
                    return jsonify({"error": "Este trabajo ya se decidió."}), 409
                validos = set(cat.ids_requisitos(t["tipo"]))
                marcados = d.get("requisitos") if isinstance(d.get("requisitos"), dict) else {}
                reqs = {k: True for k, v in marcados.items() if k in validos and v is True}
                fotos = dict(t["fotos"] or {})
                for k, v in (d.get("fotos") if isinstance(d.get("fotos"), dict) else {}).items():
                    if k not in validos:
                        continue
                    if v is None:
                        fotos.pop(k, None)
                    elif isinstance(v, str) and len(v) <= _MAX_FOTO and _RE_FOTO.match(v):
                        fotos[k] = v
                    else:
                        return jsonify({"error": "Una de las fotos no se pudo guardar. Tómala de nuevo."}), 400
                cur.execute(f"""UPDATE trabajos SET requisitos = %s, fotos = %s, verificado_en_sitio = %s
                                 WHERE id = %s AND estado = 'pendiente' RETURNING {_COLS}, fotos""",
                            (psycopg2.extras.Json(reqs), psycopg2.extras.Json(fotos), d.get("verificadoEnSitio") is True, tid))

            elif accion == "autorizar":
                if t["estado"] != "pendiente":
                    return jsonify({"error": "Este trabajo ya se decidió."}), 409
                falta = cat.faltantes(t["tipo"], t["requisitos"])
                if falta:
                    return jsonify({"error": "No se puede autorizar: faltan requisitos.", "faltan": falta}), 409
                if t["criticidad"] == "critico" and not t["verificado_en_sitio"]:
                    return jsonify({"error": "Un trabajo crítico se verifica en el sitio antes de autorizar."}), 409
                nota = ("Verificado en el sitio y autorizado" if t["criticidad"] == "critico" else "Autorizado") + sufijo
                cur.execute(f"""UPDATE trabajos SET estado = 'autorizado', decidido_por = %s, decidido_nombre = %s,
                                       decidido_en = NOW(), en_relevo = %s, motivo = NULL, registro = registro || %s
                                 WHERE id = %s AND estado = 'pendiente' RETURNING {_COLS}, fotos""",
                            (current_user.id, _yo(), relevo, _nota(nota), tid))

            elif accion == "rechazar":
                if t["estado"] != "pendiente":
                    return jsonify({"error": "Este trabajo ya se decidió."}), 409
                falta = cat.faltantes(t["tipo"], t["requisitos"])
                # Sin motivo escrito, el motivo es lo que falta: así quien solicitó sabe qué corregir.
                motivo = _texto(d.get("motivo"), 300) or (("Faltan: " + "; ".join(falta))[:300] if falta else None)
                if not motivo:
                    return jsonify({"error": "Escribe por qué no se autoriza."}), 400
                cur.execute(f"""UPDATE trabajos SET estado = 'rechazado', decidido_por = %s, decidido_nombre = %s,
                                       decidido_en = NOW(), en_relevo = %s, motivo = %s, registro = registro || %s
                                 WHERE id = %s AND estado = 'pendiente' RETURNING {_COLS}, fotos""",
                            (current_user.id, _yo(), relevo, motivo, _nota("No autorizado" + sufijo + ": " + motivo), tid))

            else:   # cerrar
                if t["estado"] != "autorizado":
                    return jsonify({"error": "Solo se cierra un trabajo autorizado."}), 409
                cur.execute(f"""UPDATE trabajos SET estado = 'cerrado', cerrado_en = NOW(), registro = registro || %s
                                 WHERE id = %s AND estado = 'autorizado' RETURNING {_COLS}, fotos""", (_nota("Trabajo cerrado" + sufijo), tid))
            f = cur.fetchone()
            # Los UPDATE exigen el estado del que parten (no hay candado de fila: con él, un
            # administrador sin relevo ni siquiera podría leer el trabajo para recibir su 403).
            if not f:
                return jsonify({"error": "Alguien más ya decidió este trabajo. Vuelve a abrirlo."}), 409
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": _FALTA_017}), 503
        raise
    if accion != "requisitos":
        auditar("trabajo_" + accion, entidad="trabajos", entidad_id=tid, detalle={"en_relevo": f["en_relevo"]})
    r = _json(f, fotos=True)
    r["puedoDecidir"] = True
    return jsonify({"ok": True, "trabajo": r})


@bp.route("/trabajos/<trabajo_id>/requisitos", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def trabajo_requisitos(trabajo_id: str):
    return _cambiar(trabajo_id, "requisitos")


@bp.route("/trabajos/<trabajo_id>/autorizar", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def trabajo_autorizar(trabajo_id: str):
    return _cambiar(trabajo_id, "autorizar")


@bp.route("/trabajos/<trabajo_id>/rechazar", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def trabajo_rechazar(trabajo_id: str):
    return _cambiar(trabajo_id, "rechazar")


@bp.route("/trabajos/<trabajo_id>/cerrar", methods=["POST"])
@requiere_organizacion
@requiere_escritura
def trabajo_cerrar(trabajo_id: str):
    return _cambiar(trabajo_id, "cerrar")


# ── Lo que solo hace el director: comité, relevo y enlace ───────────────────
def _url(pagina: str, parametro: str, token: str) -> str:
    from ..config import Config
    return f"{Config.URL_PUBLICA or request.host_url.rstrip('/')}/{pagina}?{parametro}={token}"


@bp.route("/unidades/<unidad_id>/encargados", methods=["POST"])
@requiere_organizacion
@requiere_admin_org
def unidad_encargados(unidad_id: str):
    uid = _uuid_valido(unidad_id)
    ids = (request.get_json(silent=True) or {}).get("userIds")
    if not uid or not isinstance(ids, list) or len(ids) > 30:
        return jsonify({"error": "Datos inválidos."}), 400
    ids = [x for x in (_uuid_valido(i) for i in ids) if x]
    try:
        with sesion_usuario() as cur:
            cur.execute("SELECT 1 FROM unidades WHERE id = %s AND org_id = %s", (uid, current_user.org_id))
            if not cur.fetchone():
                return jsonify({"error": "No encontrado."}), 404
            # Solo gente que de verdad pertenece a esta empresa.
            cur.execute("SELECT user_id FROM memberships WHERE org_id = %s AND user_id = ANY(%s::uuid[])",
                        (current_user.org_id, ids))
            validos = [str(f["user_id"]) for f in cur.fetchall()]
            cur.execute("DELETE FROM unidad_encargados WHERE unidad_id = %s", (uid,))
            for v in validos:
                cur.execute("INSERT INTO unidad_encargados (unidad_id, user_id, org_id) VALUES (%s, %s, %s)",
                            (uid, v, current_user.org_id))
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": _FALTA_017}), 503
        raise
    auditar("unidad_encargados", entidad="unidades", entidad_id=uid, detalle={"encargados": validos})
    return jsonify({"ok": True, "encargados": validos})


@bp.route("/unidades/<unidad_id>/relevo", methods=["POST"])
@requiere_organizacion
@requiere_admin_org
def unidad_relevo(unidad_id: str):
    """Tomar o devolver el relevo de un edificio. Tomarlo a otro administrador también vale."""
    uid = _uuid_valido(unidad_id)
    activo = (request.get_json(silent=True) or {}).get("activo")
    if not uid or not isinstance(activo, bool):
        return jsonify({"error": "Datos inválidos."}), 400
    try:
        with sesion_usuario() as cur:
            if activo:
                cur.execute("""UPDATE unidades SET relevo_por = %s, relevo_desde = NOW()
                                WHERE id = %s AND org_id = %s RETURNING id""", (current_user.id, uid, current_user.org_id))
            else:
                cur.execute("""UPDATE unidades SET relevo_por = NULL, relevo_desde = NULL
                                WHERE id = %s AND org_id = %s RETURNING id""", (uid, current_user.org_id))
            if not cur.fetchone():
                return jsonify({"error": "No encontrado."}), 404
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": _FALTA_017}), 503
        raise
    auditar("unidad_relevo", entidad="unidades", entidad_id=uid, detalle={"activo": activo})
    return jsonify({"ok": True, "activo": activo})


@bp.route("/unidades/<unidad_id>/enlace", methods=["POST"])
@requiere_organizacion
@requiere_admin_org
def unidad_enlace(unidad_id: str):
    """El enlace (y QR) por el que contratistas y locales solicitan trabajos en este edificio."""
    uid = _uuid_valido(unidad_id)
    renovar = (request.get_json(silent=True) or {}).get("renovar") is True
    if not uid:
        return jsonify({"error": "No encontrado."}), 404
    try:
        with sesion_usuario() as cur:
            cur.execute("""UPDATE unidades
                              SET token_solicitud = CASE WHEN token_solicitud IS NULL OR %s
                                    THEN translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_')
                                    ELSE token_solicitud END
                            WHERE id = %s AND org_id = %s RETURNING token_solicitud""", (renovar, uid, current_user.org_id))
            f = cur.fetchone()
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": _FALTA_017}), 503
        raise
    if not f:
        return jsonify({"error": "No encontrado."}), 404
    if renovar:
        auditar("unidad_enlace_renovar", entidad="unidades", entidad_id=uid)
    return jsonify({"ok": True, "url": _url("solicitud.html", "e", f["token_solicitud"])})


# ── Sin cuenta: solicitar un trabajo y consultar si puede iniciar ───────────
@bp.route("/publico/solicitud/<token>")
@limiter.limit("60 per minute")
def publico_solicitud_info(token: str):
    if not _RE_TOKEN.match(token or ""):
        return jsonify({"error": "Este enlace no es válido."}), 404
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT * FROM skf_solicitud_info(%s)", (token,))
            f = cur.fetchone()
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": "Este enlace no está disponible."}), 404
        raise
    if not f:
        return jsonify({"error": "Este enlace ya no está disponible. Pide uno nuevo en la administración del edificio."}), 404
    r = jsonify({"edificio": f["unidad"], "empresa": f["org"], **cat.catalogo()})
    r.headers["Cache-Control"] = "no-store"
    return r


@bp.route("/publico/solicitud", methods=["POST"])
@limiter.limit("12 per minute; 60 per hour")
def publico_solicitud_crear():
    d = request.get_json(silent=True) or {}
    token = str(d.get("enlace") or "")
    if not _RE_TOKEN.match(token):
        return jsonify({"error": "Este enlace no es válido."}), 404
    datos, error = _datos_solicitud(d)
    if error:
        return jsonify({"error": error}), 400
    if not datos["firma_ejecuta"] or not datos["firma_responsable"]:
        return jsonify({"error": "Faltan los nombres de quien ejecuta y de quien responde por el trabajo."}), 400
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT * FROM skf_solicitud_crear(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                        (token, datos["titulo"], datos["tipo"], datos["criticidad"], datos["origen"], datos["quien"],
                         datos["lugar"], datos["contacto"], datos["fecha"], datos["firma_ejecuta"], datos["firma_responsable"]))
            f = cur.fetchone()
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": "Este enlace no está disponible."}), 404
        raise
    if f["resultado"] == "demasiadas":
        return jsonify({"error": "Se recibieron muchas solicitudes seguidas. Intenta de nuevo en un rato."}), 429
    if f["resultado"] != "ok":
        return jsonify({"error": "Este enlace ya no está disponible."}), 404
    return jsonify({"ok": True, "numero": f["numero"], "edificio": f["unidad"],
                    "consulta": _url("porteria.html", "t", f["token"])}), 201


@bp.route("/publico/trabajo/<token>")
@limiter.limit("120 per minute")
def publico_trabajo(token: str):
    """La pantalla del vigilante: con el código del trabajo, si puede iniciar o no."""
    if not _RE_TOKEN.match(token or ""):
        return jsonify({"error": "Código no válido."}), 404
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT skf_trabajo_publico(%s) AS d", (token,))
            d = cur.fetchone()["d"]
    except Exception as e:
        if _sin_017(e):
            return jsonify({"error": "Código no válido."}), 404
        raise
    if not d:
        return jsonify({"error": "No hay ningún trabajo con este código."}), 404
    d["tipoNombre"] = cat.TIPOS.get(d.get("tipo"), {}).get("nombre")
    r = jsonify(d)
    r.headers["Cache-Control"] = "no-store"
    r.headers["X-Robots-Tag"] = "noindex"
    return r
