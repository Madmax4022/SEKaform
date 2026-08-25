"""Autenticación: entrar, registrarse (solo si te autorizaron) y recuperar acceso.

Las decisiones de seguridad viven en el esquema (migrations/002_auth_functions.sql);
aquí solo se orquestan y se traducen a HTTP. En particular, ninguna respuesta de
este módulo revela si un correo existe en la plataforma.
"""

from __future__ import annotations

import hashlib
import logging
import secrets
from urllib.parse import urlparse

from flask import (Blueprint, flash, jsonify, redirect, render_template,
                   request, url_for)
from flask_login import current_user, login_required, login_user, logout_user

from .. import db
from ..config import Config
from ..security import Usuario, auditar, cargar_usuario

log = logging.getLogger(__name__)
bp = Blueprint("auth", __name__)

MIN_PASSWORD = 10


def _limiter():
    from .. import limiter
    return limiter


def _destino_seguro(destino: str | None, defecto: str) -> str:
    """Evita redirecciones abiertas: solo se aceptan rutas de este mismo sitio."""
    if not destino:
        return defecto
    partes = urlparse(destino)
    if partes.scheme or partes.netloc or not destino.startswith("/"):
        return defecto
    return destino


def _password_debil(pw: str) -> str | None:
    if len(pw) < MIN_PASSWORD:
        return f"La contraseña debe tener al menos {MIN_PASSWORD} caracteres."
    if pw.isdigit() or pw.isalpha():
        return "Combina letras, números y algún símbolo."
    return None


@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("frontend"))

    if request.method == "GET":
        return render_template("login.html", modo="login")

    email = (request.form.get("email") or "").strip().lower()
    password = request.form.get("password") or ""

    if not email or not password:
        flash("Escribe tu correo y tu contraseña.", "error")
        return render_template("login.html", modo="login"), 400

    with db.sesion_privilegiada() as cur:
        cur.execute(
            "SELECT * FROM skf_auth_login(%s, %s, %s, %s)",
            (email, password, Config.MAX_INTENTOS_LOGIN, Config.BLOQUEO_MINUTOS),
        )
        r = cur.fetchone()

    resultado = r["resultado"]

    if resultado == "bloqueado":
        auditar("login_bloqueado", entidad="user", detalle={"email": email})
        flash(
            f"Demasiados intentos fallidos. Vuelve a intentarlo en {Config.BLOQUEO_MINUTOS} minutos "
            "o restablece tu contraseña.",
            "error",
        )
        return render_template("login.html", modo="login"), 429

    if resultado == "inactivo":
        flash("Tu cuenta está desactivada. Contacta al administrador de Kanan Sentinel.", "error")
        return render_template("login.html", modo="login"), 403

    if resultado != "ok":
        auditar("login_fallido", entidad="user", detalle={"email": email})
        # Mensaje idéntico para "no existe" y "clave incorrecta".
        flash("Correo o contraseña incorrectos.", "error")
        return render_template("login.html", modo="login"), 401

    usuario = cargar_usuario(str(r["user_id"]))
    if usuario is None:
        flash("No se pudo iniciar la sesión. Inténtalo de nuevo.", "error")
        return render_template("login.html", modo="login"), 500

    login_user(usuario, remember=True)
    auditar("login", entidad="user", entidad_id=usuario.id)

    if usuario.debe_cambiar_password:
        return redirect(url_for("auth.cambiar_password"))

    return redirect(_destino_seguro(request.args.get("next"), url_for("frontend")))


@bp.route("/registro", methods=["GET", "POST"])
def registro():
    """Alta de cuenta, solo para correos que un super admin autorizó antes."""
    if current_user.is_authenticated:
        return redirect(url_for("frontend"))

    if request.method == "GET":
        return render_template("login.html", modo="registro")

    email = (request.form.get("email") or "").strip().lower()
    password = request.form.get("password") or ""
    nombre = (request.form.get("nombre") or "").strip()

    problema = _password_debil(password)
    if problema:
        flash(problema, "error")
        return render_template("login.html", modo="registro"), 400

    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT * FROM skf_auth_registrar(%s, %s, %s)", (email, password, nombre))
        r = cur.fetchone()

    if r["resultado"] != "ok":
        # No se distingue "no autorizado" de "ya existe": juntas permitirían
        # averiguar qué correos están dados de alta en la plataforma.
        auditar("registro_rechazado", detalle={"email": email, "motivo": r["resultado"]})
        flash(
            "Ese correo no está habilitado para crear una cuenta. "
            "El acceso a Kanan Sentinel lo autoriza un administrador.",
            "error",
        )
        return render_template("login.html", modo="registro"), 403

    usuario = cargar_usuario(str(r["user_id"]))
    login_user(usuario, remember=True)
    auditar("registro", entidad="user", entidad_id=usuario.id, org_id=str(r["org_id"] or "") or None)
    flash(f"Bienvenido a Kanan Sentinel, {usuario.nombre}.", "ok")
    return redirect(url_for("frontend"))


@bp.route("/logout", methods=["GET", "POST"])
@login_required
def logout():
    auditar("logout", entidad="user", entidad_id=current_user.id)
    logout_user()
    return redirect(url_for("auth.login"))


@bp.route("/recuperar", methods=["GET", "POST"])
def recuperar():
    if request.method == "GET":
        return render_template("login.html", modo="recuperar")

    email = (request.form.get("email") or "").strip().lower()
    token = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(token.encode()).hexdigest()

    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT skf_auth_crear_token(%s, %s, %s) AS ok", (email, token_hash, 60))
        creado = cur.fetchone()["ok"]

    if creado:
        enlace = f"{Config.URL_PUBLICA}{url_for('auth.restablecer', token=token)}"
        _enviar_correo_recuperacion(email, enlace)
        auditar("recuperacion_solicitada", detalle={"email": email})

    # Respuesta idéntica exista o no la cuenta.
    flash(
        "Si ese correo tiene una cuenta activa, le enviamos un enlace para "
        "restablecer la contraseña. El enlace vence en una hora.",
        "ok",
    )
    return render_template("login.html", modo="recuperar")


@bp.route("/restablecer/<token>", methods=["GET", "POST"])
def restablecer(token: str):
    if request.method == "GET":
        return render_template("login.html", modo="restablecer", token=token)

    password = request.form.get("password") or ""
    problema = _password_debil(password)
    if problema:
        flash(problema, "error")
        return render_template("login.html", modo="restablecer", token=token), 400

    token_hash = hashlib.sha256(token.encode()).hexdigest()
    with db.sesion_privilegiada() as cur:
        cur.execute("SELECT skf_auth_consumir_token(%s, %s) AS r", (token_hash, password))
        resultado = cur.fetchone()["r"]

    if resultado != "ok":
        mensajes = {
            "expirado": "El enlace venció. Solicita uno nuevo.",
            "usado": "Ese enlace ya se usó. Solicita uno nuevo.",
            "invalido": "El enlace no es válido.",
        }
        flash(mensajes.get(resultado, "No se pudo restablecer la contraseña."), "error")
        return render_template("login.html", modo="recuperar"), 400

    auditar("password_restablecida")
    flash("Contraseña actualizada. Ya puedes iniciar sesión.", "ok")
    return redirect(url_for("auth.login"))


@bp.route("/cambiar-password", methods=["GET", "POST"])
@login_required
def cambiar_password():
    if request.method == "GET":
        return render_template("login.html", modo="cambiar")

    actual = request.form.get("actual") or ""
    nueva = request.form.get("password") or ""

    problema = _password_debil(nueva)
    if problema:
        flash(problema, "error")
        return render_template("login.html", modo="cambiar"), 400

    with db.sesion_privilegiada() as cur:
        cur.execute(
            "SELECT skf_auth_cambiar_password(%s, %s, %s) AS r",
            (current_user.id, actual, nueva),
        )
        resultado = cur.fetchone()["r"]

    if resultado != "ok":
        flash("La contraseña actual no es correcta.", "error")
        return render_template("login.html", modo="cambiar"), 400

    auditar("password_cambiada", entidad="user", entidad_id=current_user.id)
    flash("Contraseña actualizada.", "ok")
    return redirect(url_for("frontend"))


@bp.route("/api/yo")
def yo():
    """Identidad y permisos del usuario actual — lo consume la PWA al arrancar."""
    if not current_user.is_authenticated:
        return jsonify({"autenticado": False}), 200
    return jsonify({"autenticado": True, "usuario": current_user.to_dict()})


def _enviar_correo_recuperacion(email: str, enlace: str) -> None:
    """Envía el enlace por Resend. Si falla, se registra pero no se propaga:
    el usuario ya recibió una respuesta neutra y no debe deducir nada del error."""
    if not Config.RESEND_API_KEY:
        log.warning("RESEND_API_KEY sin configurar; no se envió el correo de recuperación.")
        return
    try:
        import requests
        from markupsafe import escape

        requests.post(
            "https://api.resend.com/emails",
            headers={
                "Authorization": f"Bearer {Config.RESEND_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "from": Config.CORREO_REMITENTE,
                "to": [email],
                "subject": "Restablece tu contraseña — Kanan Sentinel",
                "html": (
                    '<div style="font-family:Barlow,Segoe UI,sans-serif;background:#070d14;'
                    'color:#cdd9e3;padding:32px;border-radius:12px;max-width:520px">'
                    '<h2 style="color:#3fd9d2;font-family:Cinzel,serif;margin:0 0 16px">'
                    "Kanan Sentinel</h2>"
                    "<p>Recibimos una solicitud para restablecer tu contraseña de SEKaform.</p>"
                    f'<p style="margin:24px 0"><a href="{escape(enlace)}" '
                    'style="background:#3fd9d2;color:#070d14;padding:12px 26px;border-radius:8px;'
                    'text-decoration:none;font-weight:700">Restablecer contraseña</a></p>'
                    "<p style=\"font-size:13px;color:#8497a8\">El enlace vence en una hora. "
                    "Si no fuiste tú, ignora este mensaje: tu contraseña no cambia.</p></div>"
                ),
            },
            timeout=10,
        )
    except Exception:
        log.exception("Fallo al enviar el correo de recuperación")
