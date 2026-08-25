"""Configuración de SEKaform, leída del entorno.

En Cloud Run los secretos se montan como variables de entorno desde Secret
Manager (lo cablea Terraform), así que aquí no hay ningún cliente de secretos:
menos dependencias, menos latencia en el arranque en frío y nada de
credenciales en el repositorio.

Cualquier valor sensible sin definir hace fallar el arranque en producción.
Es deliberado: es preferible que el despliegue no levante a que levante con
una clave de sesión por defecto y todos los usuarios queden suplantables.
"""

from __future__ import annotations

import os


class ConfigError(RuntimeError):
    """Falta configuración obligatoria o es inválida."""


def _bool(nombre: str, defecto: bool = False) -> bool:
    return os.environ.get(nombre, str(defecto)).strip().lower() in {"1", "true", "yes", "on"}


def _req(nombre: str) -> str:
    valor = os.environ.get(nombre, "").strip()
    if not valor:
        raise ConfigError(
            f"Falta la variable de entorno obligatoria {nombre}. "
            "En Cloud Run debe venir de Secret Manager (ver infra/main.tf)."
        )
    return valor


class Config:
    ENTORNO = os.environ.get("SKF_ENV", "local").strip().lower()

    # Endurecido en TODO lo que no sea la máquina de alguien.
    #
    # Antes esto dependía de que el entorno fuese "prod" o "staging", y era un
    # error: un proyecto llamado tz-dev-sekaform sigue sirviéndose por HTTPS a
    # personas reales desde Cloud Run. Con la regla anterior, ese despliegue se
    # quedaba sin cookie Secure y —peor— sin exigir SECRET_KEY, así que cada
    # instancia generaba una distinta y las sesiones se caían al escalar o al
    # reciclarse el contenedor.
    #
    # Ahora solo se relaja con SKF_ENV=local, que es lo que usa scripts/dev.sh.
    ENDURECIDO = ENTORNO != "local"

    # ── Sesión ───────────────────────────────────────────────────────────
    SECRET_KEY = os.environ.get("SECRET_KEY", "").strip()

    # Cookie de sesión: solo por HTTPS, inaccesible desde JS y sin viajar en
    # navegaciones de terceros. "Lax" en vez de "Strict" para que volver desde
    # el correo de restablecimiento no aparente sesión cerrada.
    SESSION_COOKIE_NAME = "skf_session"
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    SESSION_COOKIE_SECURE = ENDURECIDO
    PERMANENT_SESSION_LIFETIME = int(os.environ.get("SKF_SESSION_HORAS", "12")) * 3600

    # "Recuérdame" largo a propósito: un inspector puede pasar días sin señal y
    # su cola sin conexión debe poder vaciarse al volver sin re-autenticarse.
    REMEMBER_COOKIE_NAME = "skf_remember"
    REMEMBER_COOKIE_DURATION = int(os.environ.get("SKF_REMEMBER_DIAS", "30")) * 86400
    REMEMBER_COOKIE_HTTPONLY = True
    REMEMBER_COOKIE_SAMESITE = "Lax"
    REMEMBER_COOKIE_SECURE = ENDURECIDO

    WTF_CSRF_TIME_LIMIT = None  # el token vive lo que viva la sesión
    MAX_CONTENT_LENGTH = int(os.environ.get("SKF_MAX_MB", "25")) * 1024 * 1024

    # ── Base de datos ────────────────────────────────────────────────────
    # En Cloud Run se conecta por socket unix del Cloud SQL Auth Proxy
    # (/cloudsql/proyecto:region:instancia). No hace falta VPC connector, que
    # es coste fijo mensual aunque nadie use la aplicación.
    DATABASE_URL = os.environ.get("DATABASE_URL", "").strip()
    DB_POOL_MIN = int(os.environ.get("SKF_DB_POOL_MIN", "1"))
    DB_POOL_MAX = int(os.environ.get("SKF_DB_POOL_MAX", "8"))
    DB_STATEMENT_TIMEOUT_MS = int(os.environ.get("SKF_DB_TIMEOUT_MS", "15000"))

    # ── Almacenamiento de fotos y firmas ─────────────────────────────────
    GCS_BUCKET = os.environ.get("GCS_BUCKET", "").strip()
    GCS_URL_TTL = int(os.environ.get("SKF_GCS_URL_TTL", "900"))  # segundos

    # ── Correo saliente ──────────────────────────────────────────────────
    RESEND_API_KEY = os.environ.get("RESEND_API_KEY", "").strip()
    CORREO_REMITENTE = os.environ.get(
        "SKF_CORREO_REMITENTE", "Kanan Sentinel <no-reply@kanansentinel.com>"
    )
    URL_PUBLICA = os.environ.get("SKF_URL_PUBLICA", "").rstrip("/")

    # ── Límites de acceso ────────────────────────────────────────────────
    MAX_INTENTOS_LOGIN = int(os.environ.get("SKF_MAX_INTENTOS", "5"))
    BLOQUEO_MINUTOS = int(os.environ.get("SKF_BLOQUEO_MIN", "15"))
    RATELIMIT_STORAGE_URI = os.environ.get("SKF_RATELIMIT_URI", "memory://")

    @classmethod
    def validar(cls) -> None:
        """Se llama en la factoría. Falla temprano y con un mensaje accionable."""
        if not cls.DATABASE_URL:
            raise ConfigError("Falta DATABASE_URL.")

        if cls.ENDURECIDO:
            for nombre in ("SECRET_KEY", "GCS_BUCKET", "SKF_URL_PUBLICA"):
                _req(nombre)
            if len(cls.SECRET_KEY) < 32:
                raise ConfigError(
                    "SECRET_KEY debe tener al menos 32 caracteres aleatorios en producción."
                )
            # Un despliegue que resuelve la contraseña dentro de la URL es
            # normal; lo que no puede pasar es conectarse como dueño del
            # esquema. db.py lo verifica de verdad contra la base al arrancar.
            if "skf_owner" in cls.DATABASE_URL:
                raise ConfigError(
                    "DATABASE_URL apunta a skf_owner. La aplicación debe conectarse "
                    "como skf_app; el rol dueño se salta RLS y anula el aislamiento "
                    "entre clientes (ver migrations/000_roles.sql)."
                )
        elif not cls.SECRET_KEY:
            # En desarrollo se permite una clave efímera para no exigir setup,
            # pero cambia en cada arranque: las sesiones no sobreviven al reinicio.
            cls.SECRET_KEY = os.urandom(32).hex()
