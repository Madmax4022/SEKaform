"""Identidad, permisos y bitácora de auditoría.

Tres piezas:

* `Usuario` — lo que Flask-Login guarda en la sesión. Incluye la organización
  activa y el rol, porque cada consulta necesita ese contexto para RLS.
* Decoradores de ruta — `@requiere_sesion`, `@requiere_escritura`,
  `@requiere_super_admin`. Son la primera puerta; la segunda (y definitiva) son
  las policies de la base de datos.
* `auditar()` — deja rastro de todo lo que cambia accesos o toca datos ajenos.

Nota de diseño: los decoradores nunca son la *única* defensa. Si alguien
publica una ruta sin decorador, RLS sigue devolviendo cero filas porque el
contexto de sesión no autoriza nada. Autorización en capas, a propósito.
"""

from __future__ import annotations

import functools
import json
import logging
from typing import Any, Callable, Optional

from flask import abort, g, jsonify, request
from flask_login import UserMixin, current_user

from . import db

log = logging.getLogger(__name__)

ROLES_ESCRITURA = {"dueno", "admin", "editor"}
ROLES_ADMIN_ORG = {"dueno", "admin"}


class Usuario(UserMixin):
    def __init__(
        self,
        user_id: str,
        email: str,
        nombre: Optional[str] = None,
        org_id: Optional[str] = None,
        rol: Optional[str] = None,
        org_nombre: Optional[str] = None,
        es_super: bool = False,
        debe_cambiar_password: bool = False,
    ) -> None:
        self.id = str(user_id)
        self.email = email
        self.nombre = nombre or email
        self.org_id = str(org_id) if org_id else None
        self.rol = rol
        self.org_nombre = org_nombre
        self.es_super = bool(es_super)
        self.debe_cambiar_password = bool(debe_cambiar_password)

    @property
    def puede_escribir(self) -> bool:
        return self.rol in ROLES_ESCRITURA

    @property
    def es_admin_org(self) -> bool:
        return self.rol in ROLES_ADMIN_ORG

    def to_dict(self) -> dict[str, Any]:
        """Lo que el frontend necesita saber. Nunca incluye nada sensible."""
        return {
            "id": self.id,
            "email": self.email,
            "nombre": self.nombre,
            "orgId": self.org_id,
            "orgNombre": self.org_nombre,
            "rol": self.rol,
            "esSuper": self.es_super,
            "puedeEscribir": self.puede_escribir,
        }


def cargar_usuario(user_id: str) -> Optional[Usuario]:
    """Callback de Flask-Login: reconstruye el usuario en cada petición.

    Se relee la organización y el rol en vez de confiar en la cookie. Así,
    revocar a alguien o bajarle el rol surte efecto en la siguiente petición y
    no cuando expire su sesión.
    """
    try:
        # Vía skf_auth_perfil (SECURITY DEFINER) y no con un SELECT sobre
        # `users`: esa tabla está cerrada a la app, y su policy exige el
        # app.user_id que justamente estamos resolviendo aquí. Consultarla
        # directamente devolvería cero filas y nadie podría iniciar sesión.
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT * FROM skf_auth_perfil(%s)", (user_id,))
            u = cur.fetchone()

        if not u or not u["is_active"]:
            return None

        return Usuario(
            user_id=u["id"],
            email=u["email"],
            nombre=u["nombre"],
            org_id=u["org_id"],
            rol=u["rol"],
            org_nombre=u["org_nombre"],
            es_super=u["es_super"],
            debe_cambiar_password=u["debe_cambiar"],
        )
    except Exception:
        log.exception("No se pudo cargar el usuario %s", user_id)
        return None


# ── Sesión de base de datos ligada al usuario actual ───────────────────────

def sesion_usuario(*, modo_soporte: bool = False, solo_lectura: bool = False):
    """Abre una transacción con el contexto del usuario autenticado.

    Es el único camino que deberían usar las rutas para tocar datos. Evita
    tener que acordarse de pasar user_id/org_id a mano en cada consulta.
    """
    if not current_user.is_authenticated:
        abort(401)
    return db.sesion(
        user_id=current_user.id,
        org_id=current_user.org_id,
        es_super=current_user.es_super,
        modo_soporte=modo_soporte,
        solo_lectura=solo_lectura,
    )


# ── Decoradores ────────────────────────────────────────────────────────────

def _es_api() -> bool:
    return request.path.startswith("/api/") or request.accept_mimetypes.best == "application/json"


def _rechazar(codigo: int, mensaje: str):
    """Responde en JSON si la petición es de la API, en HTML si es del navegador.

    Un 401 en el navegador se convierte en redirección a la pantalla de acceso
    (conservando el destino), que es lo que espera una persona; devolverle un
    401 pelado parecería que la aplicación está rota.
    """
    if _es_api():
        return jsonify({"error": mensaje}), codigo

    if codigo == 401:
        from flask import redirect, url_for
        return redirect(url_for("auth.login", next=request.full_path.rstrip("?")))

    abort(codigo, description=mensaje)


def requiere_sesion(f: Callable) -> Callable:
    @functools.wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return _rechazar(401, "Necesitas iniciar sesión.")
        return f(*a, **kw)
    return wrapper


def requiere_organizacion(f: Callable) -> Callable:
    """Para rutas de datos: sin organización activa no hay nada que consultar."""
    @functools.wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return _rechazar(401, "Necesitas iniciar sesión.")
        if not current_user.org_id:
            return _rechazar(
                403,
                "Tu cuenta todavía no pertenece a ninguna organización. "
                "Pídele a un administrador de Kanan Sentinel que te asigne una.",
            )
        return f(*a, **kw)
    return wrapper


def requiere_escritura(f: Callable) -> Callable:
    @functools.wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return _rechazar(401, "Necesitas iniciar sesión.")
        if not current_user.puede_escribir:
            return _rechazar(403, "Tu rol es de solo lectura.")
        return f(*a, **kw)
    return wrapper


def requiere_admin_org(f: Callable) -> Callable:
    @functools.wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return _rechazar(401, "Necesitas iniciar sesión.")
        if not (current_user.es_admin_org or current_user.es_super):
            return _rechazar(403, "Necesitas ser administrador de tu organización.")
        return f(*a, **kw)
    return wrapper


def requiere_super_admin(f: Callable) -> Callable:
    """Puerta del módulo de administración de la plataforma.

    Deliberadamente escueto: o el usuario tiene is_super_admin en la base, o no
    entra. No hay lista de correos en el código ni variable de entorno que
    conceda el privilegio — eso convertiría una fuga de configuración en una
    escalada de privilegios.
    """
    @functools.wraps(f)
    def wrapper(*a, **kw):
        if not current_user.is_authenticated:
            return _rechazar(401, "Necesitas iniciar sesión.")
        if not current_user.es_super:
            log.warning(
                "Acceso denegado al módulo de administración: %s intentó %s",
                current_user.email, request.path,
            )
            auditar(
                "acceso_denegado",
                entidad="admin",
                detalle={"ruta": request.path},
                forzar=True,
            )
            return _rechazar(404, "No encontrado.")  # no confirmamos que exista
        return f(*a, **kw)
    return wrapper


# ── Auditoría ──────────────────────────────────────────────────────────────

def auditar(
    accion: str,
    *,
    entidad: Optional[str] = None,
    entidad_id: Optional[str] = None,
    detalle: Optional[dict] = None,
    org_id: Optional[str] = None,
    forzar: bool = False,
) -> None:
    """Escribe una entrada en audit_log.

    Nunca lanza: una bitácora rota no puede tumbar la operación que registra.
    Pero sí deja un error en el log de la aplicación, para que la pérdida de
    trazabilidad sea visible en vez de silenciosa.
    """
    try:
        actor_id = current_user.id if current_user.is_authenticated else None
        actor_email = current_user.email if current_user.is_authenticated else None
        destino_org = org_id or (current_user.org_id if current_user.is_authenticated else None)

        ip = (request.headers.get("X-Forwarded-For", "") or request.remote_addr or "").split(",")[0].strip()

        with db.sesion_privilegiada() as cur:
            cur.execute(
                """
                INSERT INTO audit_log
                  (actor_id, actor_email, org_id, accion, entidad, entidad_id, detalle, ip, user_agent)
                VALUES (%s, %s, %s, %s, %s, %s, %s, NULLIF(%s,'')::inet, %s)
                """,
                (
                    actor_id, actor_email, destino_org, accion, entidad,
                    str(entidad_id) if entidad_id else None,
                    json.dumps(detalle or {}, ensure_ascii=False),
                    ip, request.headers.get("User-Agent", "")[:500],
                ),
            )
    except Exception:
        log.exception("No se pudo escribir en audit_log: accion=%s entidad=%s", accion, entidad)
