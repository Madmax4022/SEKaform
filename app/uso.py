"""Qué se usa de la app (recorte del 50 %, paso 1: ocultar y medir).

Cuenta pantallas abiertas y funciones usadas por día, empresa y persona
(migración 015). Contar nunca debe costarle nada al usuario: si la base tarda,
falta la migración o algo falla, no se cuenta y ya.
"""
from __future__ import annotations

import logging
import re

from flask_login import current_user

from . import db

log = logging.getLogger(__name__)
RE_QUE = re.compile(r"^[a-z_]{2,30}(:[a-z0-9_.\-]{1,40})?$")


def contar(que: str) -> None:
    if not RE_QUE.match(que or ""):
        return
    try:
        if not current_user.is_authenticated or not current_user.org_id:
            return
        with db.sesion(user_id=current_user.id, org_id=current_user.org_id, timeout_ms=300) as cur:
            cur.execute("SELECT skf_uso_contar(%s)", (que,))
    except Exception as e:  # sin la 015, base ocupada…: no se cuenta
        log.debug("Uso no contado (%s): %s", que, e)
