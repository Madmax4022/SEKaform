"""Módulo de administración de la plataforma — exclusivo de super administradores.

Es el panel desde el que Kanan Sentinel concede y retira acceso:

  · a la PLATAFORMA  → autorizando un correo para que pueda crear su cuenta
  · a una ORGANIZACIÓN → creándola y asignándole personas con un rol
  · a un FORMULARIO  → otorgando o revocando plantillas del catálogo

Tres reglas que se respetan en todas las rutas:

1. Toda ruta lleva @requiere_super_admin, y a quien no lo sea se le responde
   404 (no 403): el panel ni siquiera confirma que existe.
2. Toda acción que cambie un acceso deja huella en audit_log, con quién, qué,
   cuándo y desde dónde.
3. Conceder acceso NO es poder mirar los datos del cliente. Para eso está el
   modo soporte, explícito, temporal y auditado.
"""

from __future__ import annotations

import logging
import uuid

from flask import Blueprint, jsonify, render_template, request
from flask_login import current_user

from .. import db
from ..security import auditar, requiere_super_admin

log = logging.getLogger(__name__)
bp = Blueprint("admin", __name__, url_prefix="/admin")

ROLES = {"dueno", "admin", "editor", "lector"}


def _super():
    """Transacción con poderes de super admin, SIN modo soporte.

    Alcanza para administrar organizaciones, usuarios, invitaciones y
    concesiones. No alcanza —por diseño— para leer envíos ni hallazgos.
    """
    return db.sesion(user_id=current_user.id, es_super=True)


def _json_error(msg: str, codigo: int = 400):
    return jsonify({"error": msg}), codigo


# ── Panel ──────────────────────────────────────────────────────────────────

@bp.route("/")
@requiere_super_admin
def panel():
    return render_template("admin.html", usuario=current_user)


@bp.route("/api/resumen")
@requiere_super_admin
def resumen():
    with _super() as cur:
        cur.execute("""
            SELECT o.id, o.nombre, o.pais, o.plan, o.activa, o.creado_en,
                   (SELECT count(*) FROM memberships m WHERE m.org_id = o.id)        AS miembros,
                   (SELECT count(*) FROM form_access_grants g
                     WHERE g.org_id = o.id AND g.revocado_en IS NULL)                AS formularios
              FROM organizations o
             ORDER BY o.creado_en DESC
        """)
        organizaciones = cur.fetchall()

        cur.execute("""
            SELECT u.id, u.email, u.nombre, u.is_super_admin, u.is_active,
                   u.last_login_at, u.creado_en, u.locked_until,
                   m.org_id, m.rol, o.nombre AS org_nombre
              FROM users u
              LEFT JOIN memberships m   ON m.user_id = u.id
              LEFT JOIN organizations o ON o.id = m.org_id
             ORDER BY u.creado_en DESC
             LIMIT 500
        """)
        usuarios = cur.fetchall()

        cur.execute("""
            SELECT a.id, a.email, a.rol_inicial, a.is_active, a.autorizado_en,
                   a.usado_en, a.expira_en, o.nombre AS org_nombre
              FROM authorized_emails a
              LEFT JOIN organizations o ON o.id = a.org_id
             WHERE a.usado_en IS NULL
             ORDER BY a.autorizado_en DESC
             LIMIT 200
        """)
        invitaciones = cur.fetchall()

    return jsonify({
        "organizaciones": organizaciones,
        "usuarios": usuarios,
        "invitacionesPendientes": invitaciones,
    })


# ── Acceso a la plataforma: autorizar correos ──────────────────────────────

@bp.route("/api/invitaciones", methods=["POST"])
@requiere_super_admin
def crear_invitacion():
    d = request.get_json(silent=True) or {}
    email = (d.get("email") or "").strip().lower()
    org_id = d.get("orgId")
    rol = (d.get("rol") or "editor").strip()
    dias = int(d.get("diasVigencia") or 14)

    if "@" not in email or len(email) < 5:
        return _json_error("Correo inválido.")
    if rol not in ROLES:
        return _json_error(f"Rol inválido. Debe ser uno de: {', '.join(sorted(ROLES))}.")

    with _super() as cur:
        cur.execute("SELECT 1 FROM users WHERE email = %s", (email,))
        if cur.fetchone():
            return _json_error("Ese correo ya tiene una cuenta.", 409)

        cur.execute(
            """
            INSERT INTO authorized_emails
              (email, org_id, rol_inicial, autorizado_por, expira_en, notas)
            VALUES (%s, %s, %s, %s, NOW() + (%s || ' days')::INTERVAL, %s)
            ON CONFLICT (email) DO UPDATE
               SET org_id = EXCLUDED.org_id, rol_inicial = EXCLUDED.rol_inicial,
                   is_active = true, usado_en = NULL,
                   expira_en = EXCLUDED.expira_en,
                   autorizado_por = EXCLUDED.autorizado_por,
                   autorizado_en = NOW()
            RETURNING id
            """,
            (email, org_id, rol, current_user.id, dias, (d.get("notas") or "").strip() or None),
        )
        inv = cur.fetchone()

    auditar(
        "invitacion_creada", entidad="authorized_email", entidad_id=inv["id"],
        detalle={"email": email, "rol": rol, "orgId": org_id, "diasVigencia": dias},
        org_id=org_id,
    )
    return jsonify({"ok": True, "id": inv["id"]}), 201


@bp.route("/api/invitaciones/<uuid:inv_id>", methods=["DELETE"])
@requiere_super_admin
def revocar_invitacion(inv_id: uuid.UUID):
    with _super() as cur:
        cur.execute(
            "UPDATE authorized_emails SET is_active = false WHERE id = %s RETURNING email",
            (str(inv_id),),
        )
        fila = cur.fetchone()
    if not fila:
        return _json_error("No encontrada.", 404)

    auditar("invitacion_revocada", entidad="authorized_email", entidad_id=str(inv_id),
            detalle={"email": fila["email"]})
    return jsonify({"ok": True})


# ── Organizaciones ─────────────────────────────────────────────────────────

@bp.route("/api/organizaciones", methods=["POST"])
@requiere_super_admin
def crear_organizacion():
    d = request.get_json(silent=True) or {}
    nombre = (d.get("nombre") or "").strip()
    if len(nombre) < 2:
        return _json_error("El nombre de la organización es obligatorio.")

    with _super() as cur:
        cur.execute(
            "INSERT INTO organizations (nombre, pais, plan) VALUES (%s, %s, %s) RETURNING id",
            (nombre, (d.get("pais") or "").strip() or None, (d.get("plan") or "emprende")),
        )
        org = cur.fetchone()

    auditar("organizacion_creada", entidad="organization", entidad_id=org["id"],
            detalle={"nombre": nombre}, org_id=str(org["id"]))
    return jsonify({"ok": True, "id": org["id"]}), 201


@bp.route("/api/organizaciones/<uuid:org_id>/estado", methods=["POST"])
@requiere_super_admin
def alternar_organizacion(org_id: uuid.UUID):
    with _super() as cur:
        cur.execute(
            "UPDATE organizations SET activa = NOT activa WHERE id = %s RETURNING nombre, activa",
            (str(org_id),),
        )
        org = cur.fetchone()
    if not org:
        return _json_error("No encontrada.", 404)

    auditar("organizacion_estado", entidad="organization", entidad_id=str(org_id),
            detalle={"nombre": org["nombre"], "activa": org["activa"]}, org_id=str(org_id))
    return jsonify({"ok": True, "activa": org["activa"]})


# ── Usuarios ───────────────────────────────────────────────────────────────

@bp.route("/api/usuarios/<uuid:user_id>/estado", methods=["POST"])
@requiere_super_admin
def alternar_usuario(user_id: uuid.UUID):
    if str(user_id) == current_user.id:
        return _json_error("No puedes desactivar tu propia cuenta.", 409)

    with _super() as cur:
        cur.execute(
            "UPDATE users SET is_active = NOT is_active WHERE id = %s RETURNING email, is_active",
            (str(user_id),),
        )
        u = cur.fetchone()
    if not u:
        return _json_error("No encontrado.", 404)

    auditar("usuario_estado", entidad="user", entidad_id=str(user_id),
            detalle={"email": u["email"], "activo": u["is_active"]})
    return jsonify({"ok": True, "activo": u["is_active"]})


@bp.route("/api/usuarios/<uuid:user_id>/super", methods=["POST"])
@requiere_super_admin
def alternar_super(user_id: uuid.UUID):
    """Concede o retira el privilegio de super administrador.

    Con dos salvaguardas: nadie puede quitarse el privilegio a sí mismo (evita
    quedarse sin panel por accidente) y nunca puede quedar la plataforma sin
    ningún super admin activo.
    """
    if str(user_id) == current_user.id:
        return _json_error("No puedes cambiar tu propio privilegio de super administrador.", 409)

    with _super() as cur:
        cur.execute("SELECT email, is_super_admin FROM users WHERE id = %s", (str(user_id),))
        u = cur.fetchone()
        if not u:
            return _json_error("No encontrado.", 404)

        if u["is_super_admin"]:
            cur.execute(
                "SELECT count(*) AS n FROM users WHERE is_super_admin AND is_active AND id <> %s",
                (str(user_id),),
            )
            if cur.fetchone()["n"] == 0:
                return _json_error(
                    "No puedes retirar al último super administrador activo.", 409
                )

        cur.execute(
            "UPDATE users SET is_super_admin = NOT is_super_admin WHERE id = %s "
            "RETURNING is_super_admin",
            (str(user_id),),
        )
        nuevo = cur.fetchone()["is_super_admin"]

    auditar("privilegio_super_admin", entidad="user", entidad_id=str(user_id),
            detalle={"email": u["email"], "esSuper": nuevo})
    return jsonify({"ok": True, "esSuper": nuevo})


@bp.route("/api/usuarios/<uuid:user_id>/membresia", methods=["POST"])
@requiere_super_admin
def asignar_membresia(user_id: uuid.UUID):
    d = request.get_json(silent=True) or {}
    org_id = d.get("orgId")
    rol = (d.get("rol") or "editor").strip()
    if rol not in ROLES:
        return _json_error("Rol inválido.")
    if not org_id:
        return _json_error("Falta la organización.")

    with _super() as cur:
        cur.execute(
            """
            INSERT INTO memberships (org_id, user_id, rol) VALUES (%s, %s, %s)
            ON CONFLICT (org_id, user_id) DO UPDATE SET rol = EXCLUDED.rol
            """,
            (org_id, str(user_id), rol),
        )

    auditar("membresia_asignada", entidad="user", entidad_id=str(user_id),
            detalle={"orgId": org_id, "rol": rol}, org_id=org_id)
    return jsonify({"ok": True})


# ── Acceso a formularios del catálogo ──────────────────────────────────────

@bp.route("/api/formularios")
@requiere_super_admin
def listar_formularios():
    """Catálogo con, para cada plantilla, qué organizaciones la tienen concedida."""
    with _super() as cur:
        cur.execute("""
            SELECT p.id, p.nombre, p.vertical, p.norma, p.codigo,
                   COALESCE(
                     json_agg(json_build_object('orgId', g.org_id, 'orgNombre', o.nombre,
                                                'otorgadoEn', g.otorgado_en))
                     FILTER (WHERE g.id IS NOT NULL), '[]'
                   ) AS concedido_a
              FROM plantillas p
              LEFT JOIN form_access_grants g ON g.plantilla_id = p.id AND g.revocado_en IS NULL
              LEFT JOIN organizations o      ON o.id = g.org_id
             WHERE p.es_catalogo
             GROUP BY p.id
             ORDER BY p.vertical, p.nombre
        """)
        return jsonify({"formularios": cur.fetchall()})


@bp.route("/api/formularios/acceso", methods=["POST"])
@requiere_super_admin
def conceder_acceso():
    """Concede o revoca una plantilla del catálogo a una organización.

    Revocar no borra la fila: la sella con revocado_en, para que quede el
    histórico de quién tuvo acceso a qué y entre qué fechas. En un producto de
    cumplimiento, esa pregunta se hace en cada auditoría.
    """
    d = request.get_json(silent=True) or {}
    plantilla_id = d.get("plantillaId")
    org_id = d.get("orgId")
    conceder = bool(d.get("conceder", True))

    if not plantilla_id or not org_id:
        return _json_error("Faltan plantillaId u orgId.")

    with _super() as cur:
        cur.execute(
            "SELECT nombre FROM plantillas WHERE id = %s AND es_catalogo", (plantilla_id,)
        )
        p = cur.fetchone()
        if not p:
            return _json_error("Esa plantilla no existe en el catálogo.", 404)

        if conceder:
            cur.execute(
                """
                INSERT INTO form_access_grants (plantilla_id, org_id, otorgado_por, notas)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (plantilla_id, org_id) WHERE revocado_en IS NULL DO NOTHING
                """,
                (plantilla_id, org_id, current_user.id, (d.get("notas") or "").strip() or None),
            )
        else:
            cur.execute(
                """
                UPDATE form_access_grants
                   SET revocado_en = NOW(), revocado_por = %s
                 WHERE plantilla_id = %s AND org_id = %s AND revocado_en IS NULL
                """,
                (current_user.id, plantilla_id, org_id),
            )

    auditar(
        "acceso_formulario_concedido" if conceder else "acceso_formulario_revocado",
        entidad="plantilla", entidad_id=plantilla_id,
        detalle={"plantilla": p["nombre"], "orgId": org_id}, org_id=org_id,
    )
    return jsonify({"ok": True})


# ── Bitácora y modo soporte ────────────────────────────────────────────────

@bp.route("/api/auditoria")
@requiere_super_admin
def auditoria():
    limite = min(int(request.args.get("limite", 200)), 1000)
    with _super() as cur:
        cur.execute(
            """
            SELECT id, ocurrido_en, actor_email, org_id, accion, entidad, entidad_id, detalle, ip
              FROM audit_log ORDER BY ocurrido_en DESC LIMIT %s
            """,
            (limite,),
        )
        return jsonify({"entradas": cur.fetchall()})


@bp.route("/api/soporte/<uuid:org_id>", methods=["POST"])
@requiere_super_admin
def modo_soporte(org_id: uuid.UUID):
    """Lectura puntual de datos operativos de un cliente, para dar soporte.

    Es la única vía por la que un super admin ve envíos o hallazgos ajenos, y
    queda registrada antes de devolver nada. El acceso no persiste: vale solo
    para esta petición, porque app.support_mode se fija con SET LOCAL y muere
    al terminar la transacción.
    """
    motivo = (request.get_json(silent=True) or {}).get("motivo", "").strip()
    if len(motivo) < 10:
        return _json_error("Describe el motivo del acceso de soporte (mínimo 10 caracteres).")

    auditar("soporte_acceso", entidad="organization", entidad_id=str(org_id),
            detalle={"motivo": motivo}, org_id=str(org_id))

    with db.sesion(user_id=current_user.id, org_id=str(org_id),
                   es_super=True, modo_soporte=True, solo_lectura=True) as cur:
        cur.execute(
            "SELECT count(*) AS envios FROM envios WHERE org_id = %s", (str(org_id),)
        )
        envios = cur.fetchone()["envios"]
        cur.execute(
            "SELECT count(*) AS abiertos FROM hallazgos "
            "WHERE org_id = %s AND estado <> 'cerrado'", (str(org_id),)
        )
        abiertos = cur.fetchone()["abiertos"]

    return jsonify({"ok": True, "envios": envios, "hallazgosAbiertos": abiertos})
