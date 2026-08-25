"""Acceso a PostgreSQL con contexto de seguridad por transacción.

La idea central: **ninguna consulta se ejecuta sin contexto**. Cada transacción
declara quién la pide (`app.user_id`), en nombre de qué organización
(`app.org_id`) y con qué poderes (`app.is_super_admin`, `app.support_mode`), y
las policies de RLS del esquema deciden qué filas existen para esa transacción.

Eso convierte el aislamiento entre clientes en una propiedad de la base de
datos y no en una disciplina de programación. Si mañana alguien escribe
`SELECT * FROM envios` sin filtrar, Postgres devuelve únicamente los envíos de
la organización activa. El error se vuelve una consulta corta, no una fuga.
"""

from __future__ import annotations

import contextlib
import logging
import threading
from typing import Any, Iterator, Optional

import psycopg2
import psycopg2.extras
import psycopg2.pool

log = logging.getLogger(__name__)

_pool: Optional[psycopg2.pool.ThreadedConnectionPool] = None
_pool_lock = threading.Lock()


class AislamientoInseguro(RuntimeError):
    """La conexión puede saltarse RLS. Es un fallo de despliegue, no de datos."""


def init_pool(dsn: str, minimo: int = 1, maximo: int = 8) -> None:
    global _pool
    with _pool_lock:
        if _pool is not None:
            return
        _pool = psycopg2.pool.ThreadedConnectionPool(minimo, maximo, dsn)
    verificar_aislamiento()


def cerrar_pool() -> None:
    global _pool
    with _pool_lock:
        if _pool is not None:
            _pool.closeall()
            _pool = None


@contextlib.contextmanager
def _conexion() -> Iterator[Any]:
    if _pool is None:
        raise RuntimeError("El pool no está inicializado; llama a init_pool() primero.")
    conn = _pool.getconn()
    try:
        yield conn
    finally:
        _pool.putconn(conn)


def verificar_aislamiento() -> None:
    """Comprueba contra la base que esta conexión NO puede saltarse RLS.

    Es la contraparte de haber dejado las tablas en ENABLE y no en FORCE (ver
    la sección 17 de migrations/001_core.sql). Con ENABLE, el dueño de la tabla
    ignora las policies; por eso la aplicación debe conectarse con un rol que
    no sea dueño de nada, no sea superusuario y no tenga BYPASSRLS.

    Se ejecuta una vez al arrancar. Si algo de eso falla, el proceso no
    levanta: es preferible un despliegue caído a uno que sirve datos cruzados
    entre clientes sin que nadie se entere.
    """
    with _conexion() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT current_user, rolsuper, rolbypassrls "
                "FROM pg_roles WHERE rolname = current_user"
            )
            usuario, es_super, bypass = cur.fetchone()

            if es_super:
                raise AislamientoInseguro(
                    f"La aplicación se conectó como superusuario ({usuario}). "
                    "Un superusuario ignora RLS y ve los datos de todos los clientes."
                )
            if bypass:
                raise AislamientoInseguro(
                    f"El rol {usuario} tiene BYPASSRLS. Quítalo: "
                    f"ALTER ROLE {usuario} NOBYPASSRLS;"
                )

            # Ser dueño de una tabla también evita las policies mientras no
            # esté en FORCE, que es exactamente nuestro caso.
            cur.execute(
                "SELECT string_agg(tablename, ', ') FROM pg_tables "
                "WHERE schemaname = 'public' AND tableowner = current_user"
            )
            (propias,) = cur.fetchone()
            if propias:
                raise AislamientoInseguro(
                    f"El rol {usuario} es dueño de tablas ({propias}). "
                    "El dueño ignora RLS; conecta la aplicación como skf_app y "
                    "corre las migraciones como skf_owner."
                )
        conn.rollback()
    log.info("Aislamiento verificado: la conexión de la aplicación está sujeta a RLS.")


@contextlib.contextmanager
def sesion(
    *,
    user_id: Optional[str] = None,
    org_id: Optional[str] = None,
    es_super: bool = False,
    modo_soporte: bool = False,
    solo_lectura: bool = False,
    timeout_ms: Optional[int] = None,
) -> Iterator[psycopg2.extras.RealDictCursor]:
    """Abre una transacción con el contexto de seguridad ya fijado.

        with db.sesion(user_id=u, org_id=o) as cur:
            cur.execute("SELECT * FROM envios ORDER BY enviado_en DESC")

    `modo_soporte` solo tiene efecto si `es_super`, y en el esquema es lo único
    que deja a un super admin leer datos operativos de un cliente. Quien lo
    active debe además dejar rastro en audit_log — administrar accesos no
    autoriza por sí solo a leer las inspecciones de nadie.
    """
    with _conexion() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        try:
            if timeout_ms:
                cur.execute("SET LOCAL statement_timeout = %s", (timeout_ms,))
            if solo_lectura:
                cur.execute("SET LOCAL transaction_read_only = on")

            # set_config(..., true) es el equivalente parametrizable de
            # SET LOCAL: el valor viaja como parámetro y no por concatenación,
            # así que no hay forma de inyectar SQL a través del contexto.
            cur.execute(
                """
                SELECT set_config('app.user_id',        %s, true),
                       set_config('app.org_id',         %s, true),
                       set_config('app.is_super_admin', %s, true),
                       set_config('app.support_mode',   %s, true)
                """,
                (
                    str(user_id) if user_id else "",
                    str(org_id) if org_id else "",
                    "on" if es_super else "off",
                    "on" if (es_super and modo_soporte) else "off",
                ),
            )
            yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            cur.close()


@contextlib.contextmanager
def sesion_privilegiada(timeout_ms: Optional[int] = None) -> Iterator[Any]:
    """Transacción sin usuario, para los pocos flujos previos a la sesión.

    Login, registro y restablecimiento de contraseña ocurren cuando todavía no
    hay identidad, así que no pueden apoyarse en RLS. Las tablas que tocan
    (`users`, `authorized_emails`, `password_reset_tokens`) están cerradas a la
    app por policy, de modo que estos caminos usan funciones SECURITY DEFINER
    del esquema, acotadas a lo justo. Nada de datos operativos pasa por aquí.
    """
    with _conexion() as conn:
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        try:
            if timeout_ms:
                cur.execute("SET LOCAL statement_timeout = %s", (timeout_ms,))
            yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            cur.close()


def salud() -> bool:
    """Sonda para /healthz. Barata: no toca tablas de negocio."""
    try:
        with _conexion() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
            conn.rollback()
        return True
    except Exception:
        log.exception("Fallo la sonda de salud de la base de datos")
        return False
