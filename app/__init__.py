"""Factoría de la aplicación Kanan Sentinel · SEKaform."""

from __future__ import annotations

import logging
import os
from pathlib import Path

from flask import (Flask, Response, jsonify, redirect, request,
                   send_from_directory, url_for)
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_login import LoginManager, current_user
from flask_wtf.csrf import CSRFProtect

from . import db, security
from .config import Config

RAIZ = Path(__file__).resolve().parent.parent

csrf = CSRFProtect()
login_manager = LoginManager()
limiter = Limiter(key_func=get_remote_address, storage_uri=Config.RATELIMIT_STORAGE_URI)

# Lista blanca del frontend.
#
# La PWA todavía vive en la raíz del repositorio (herencia de cuando se
# publicaba en GitHub Pages). Servir ese directorio entero expondría
# migrations/, infra/ y requirements.txt, así que se enumeran los archivos que
# son públicos y nada más. Cuando el frontend se mueva a app/static/ esto se
# reduce a un send_from_directory normal.
PAGINAS = {
    "": "index.html",
    "index.html": "index.html",
    "plantillas.html": "plantillas.html",
    "digitalizador.html": "digitalizador.html",
    "llenar.html": "llenar.html",
    "asignaciones.html": "asignaciones.html",
    "programadas.html": "programadas.html",
    "unidades.html": "unidades.html",
    "hallazgos.html": "hallazgos.html",
    "dashboard.html": "dashboard.html",
    "organizacion.html": "organizacion.html",
}

ESTATICOS = {
    "styles.css", "field-types.js", "form-library.js", "sidebar.js",
    "chart.min.js", "sw.js", "manifest.json", "skf-api.js",
}


def crear_app(config: type[Config] = Config) -> Flask:
    Config.validar()

    app = Flask(__name__, static_folder=None, template_folder="templates")
    app.config.from_object(config)

    _configurar_logs(app)

    db.init_pool(config.DATABASE_URL, config.DB_POOL_MIN, config.DB_POOL_MAX)

    csrf.init_app(app)
    limiter.init_app(app)

    login_manager.init_app(app)
    login_manager.login_view = "auth.login"
    login_manager.session_protection = "strong"
    login_manager.user_loader(security.cargar_usuario)

    @login_manager.unauthorized_handler
    def _no_autorizado():
        if request.path.startswith("/api/"):
            return jsonify({"error": "Necesitas iniciar sesión.", "codigo": "sin_sesion"}), 401
        from flask import redirect, url_for
        return redirect(url_for("auth.login", next=request.path))

    from .auth.routes import bp as auth_bp
    from .admin.routes import bp as admin_bp
    from .api import registrar_api

    app.register_blueprint(auth_bp)
    app.register_blueprint(admin_bp)
    registrar_api(app, csrf)

    _registrar_frontend(app)
    _registrar_cabeceras(app)
    _registrar_errores(app)

    # Dos rutas para la misma sonda, y no por gusto:
    #
    #   /healthz  · la usan las sondas de Cloud Run, que van directas al
    #               contenedor. Funciona ahí, pero NO es alcanzable desde
    #               fuera: el frontend de Google intercepta esa ruta exacta y
    #               devuelve su propio 404 sin llegar a la aplicación.
    #   /_salud   · la equivalente para monitoreo externo (uptime checks,
    #               balanceadores, Pingdom…), que sí atraviesa el frontend.
    #
    # Comprobado en tz-dev-sekaform: /healthz devuelve la página de error de
    # Google, mientras que /healthz/, /health o /_salud sí llegan a Flask.
    @app.route("/healthz")
    @app.route("/_salud")
    @csrf.exempt
    def healthz():
        # Comprueba la base porque un contenedor que responde pero no llega a
        # Cloud SQL no está sano, solo vivo.
        if not db.salud():
            return jsonify({"estado": "degradado"}), 503
        return jsonify({"estado": "ok"}), 200

    return app


def _configurar_logs(app: Flask) -> None:
    if Config.ENDURECIDO:
        try:
            import google.cloud.logging  # type: ignore
            google.cloud.logging.Client().setup_logging(log_level=logging.INFO)
        except Exception:
            logging.basicConfig(level=logging.INFO)
            app.logger.warning("Cloud Logging no disponible; se usa logging estándar.")
    else:
        logging.basicConfig(
            level=logging.DEBUG,
            format="%(asctime)s %(levelname)s %(name)s — %(message)s",
        )


def _registrar_frontend(app: Flask) -> None:
    @app.route("/")
    @app.route("/<path:ruta>")
    def frontend(ruta: str = ""):
        if ruta in PAGINAS:
            # Las páginas de la aplicación exigen sesión. El acceso a SEKaform
            # lo concede un super administrador, así que un visitante anónimo
            # no debe siquiera ver la interfaz: se le manda a identificarse.
            # Los estáticos (sw.js, manifest, marca) quedan abiertos porque el
            # service worker debe poder registrarse antes de haber sesión.
            if not current_user.is_authenticated:
                return redirect(url_for("auth.login", next="/" + ruta))
            return _enviar(PAGINAS[ruta], cache=False)
        if ruta in ESTATICOS:
            return _enviar(ruta, cache=True)
        if ruta.startswith("icons/") and ruta.count("/") == 1:
            return _enviar(ruta, cache=True)
        if ruta.startswith("brand/") and ruta.count("/") == 1:
            return send_from_directory(RAIZ / "app" / "static" / "brand", ruta[6:], max_age=86400)
        return jsonify({"error": "No encontrado"}), 404

    def _enviar(nombre: str, *, cache: bool) -> Response:
        # El HTML nunca se cachea en el CDN: si no, un despliegue nuevo convive
        # con páginas viejas que llaman endpoints que ya cambiaron. Los assets
        # sí, porque el service worker los versiona por su cuenta.
        resp = send_from_directory(RAIZ, nombre, max_age=86400 if cache else 0)
        if not cache:
            resp.headers["Cache-Control"] = "no-cache, must-revalidate"
        return resp


def _registrar_cabeceras(app: Flask) -> None:
    @app.after_request
    def cabeceras(resp: Response) -> Response:
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")
        resp.headers.setdefault("X-Frame-Options", "DENY")
        resp.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        resp.headers.setdefault(
            "Permissions-Policy",
            # La app sí necesita cámara y GPS (fotos de evidencia, ubicación de
            # la inspección); todo lo demás se apaga.
            "geolocation=(self), camera=(self), microphone=(), payment=(), usb=()",
        )
        if Config.ENDURECIDO:
            resp.headers.setdefault(
                "Strict-Transport-Security", "max-age=31536000; includeSubDomains"
            )
        # 'unsafe-inline' sigue siendo necesario mientras las páginas lleven su
        # <script> incrustado. Es la deuda que cierra el paso 2 del plan: al
        # externalizar esos scripts, esta política pasa a ser estricta.
        resp.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'self'; "
            "script-src 'self' 'unsafe-inline' https://unpkg.com https://cdnjs.cloudflare.com; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src 'self' https://fonts.gstatic.com; "
            "img-src 'self' data: blob: https://storage.googleapis.com; "
            "connect-src 'self' https://storage.googleapis.com; "
            "frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
        )
        return resp


def _registrar_errores(app: Flask) -> None:
    @app.errorhandler(400)
    @app.errorhandler(403)
    @app.errorhandler(404)
    @app.errorhandler(413)
    @app.errorhandler(429)
    def _error_cliente(e):
        codigo = getattr(e, "code", 400)
        if request.path.startswith("/api/"):
            return jsonify({"error": getattr(e, "description", "Solicitud inválida")}), codigo
        return jsonify({"error": getattr(e, "description", "Solicitud inválida")}), codigo

    @app.errorhandler(500)
    def _error_servidor(e):
        app.logger.exception("Error no controlado en %s", request.path)
        # Nunca se devuelve la traza: describe el esquema y las rutas internas.
        return jsonify({"error": "Error interno. El equipo ya fue notificado."}), 500


# Punto de entrada de gunicorn: `gunicorn 'app:crear_app()'`
if os.environ.get("SKF_EAGER_APP") == "1":
    application = crear_app()
