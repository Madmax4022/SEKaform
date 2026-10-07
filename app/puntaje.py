"""Puntaje de cumplimiento de una inspección.

Es la MISMA regla que `skfPuntaje` en field-types.js (la pantalla la usa para mostrar el
porcentaje); aquí el servidor la repite para decidir si avisa por correo, porque no debe
fiarse de un porcentaje que mande el navegador. `tests/puntaje_test.py` corre las dos
implementaciones con los mismos casos y falla si alguna se desvía.

Cuenta solo los «puntos de control»: preguntas Sí/No (N/A no cuenta), escalas 1–5, números con
rango y selecciones con criticidad. Un punto cumple si su respuesta NO sería un hallazgo.
Lo oculto por una condición («mostrar solo si…») no cuenta.
"""

from __future__ import annotations

import re
from typing import Any, Optional

UMBRAL_BAJO = 70   # por debajo de esto el cumplimiento es «bajo» (igual que en la pantalla)

_MALA = re.compile(r"no conforme|no cumple|incumple|deficiente|rechazad|inadecuad|insuficiente|"
                   r"vencid|da[ñn]ad|fuera de servicio", re.I)
_UNO_O_DOS = re.compile(r"^[12]\b", re.A)
_NUM = re.compile(r"^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?")
_COND_TIPOS = ("si_no", "radio", "select", "escala_1_5")


def _vacio(v: Any) -> bool:
    return v is None or v == "" or (isinstance(v, list) and not v)


def _parse_float(v: Any) -> Optional[float]:
    m = _NUM.match(str(v).replace(",", "."))
    return float(m.group(0)) if m else None


def _limite(v: Any) -> Optional[float]:
    return None if v is None or v == "" else _parse_float(v)


def respuesta_es_hallazgo(c: dict, valor: Any) -> bool:
    tipo = c.get("tipo")
    if _vacio(valor):
        return False
    if tipo == "si_no":
        return valor == "No"
    if tipo == "escala_1_5":
        return bool(_UNO_O_DOS.match(str(valor).strip()))
    if tipo == "numero":
        n = _parse_float(valor)
        if n is None:
            return False
        mn, mx = _limite(c.get("rangoMin")), _limite(c.get("rangoMax"))
        if mn is None and mx is None:
            return False
        return (mn is not None and n < mn) or (mx is not None and n > mx)
    if tipo == "checkbox_multi":
        return isinstance(valor, list) and any(_MALA.search(str(x)) for x in valor)
    if tipo in ("select", "radio"):
        return bool(_MALA.search(str(valor)))
    return False


def _opciones_condicion(c: dict) -> list:
    if c.get("tipo") == "si_no":
        return ["Sí", "No", "N/A"]
    if c.get("tipo") not in _COND_TIPOS:
        return []
    return [o for o in (c.get("opciones") or []) if o != ""]


def es_visible(c: dict, campos: list, datos: dict, prof: int = 0) -> bool:
    m = c.get("mostrarSi")
    if not isinstance(m, dict) or not m.get("campoId"):
        return True
    valores = m.get("valores")
    if not isinstance(valores, list) or not valores or prof > 8:
        return True
    ci = ii = -1
    for k, x in enumerate(campos):
        if x.get("id") == m["campoId"]:
            ci = k
        if x.get("id") == c.get("id"):
            ii = k
    if ci < 0 or ii < 0 or ci >= ii:
        return True
    ctl = campos[ci]
    opts = _opciones_condicion(ctl)
    if not any(v in opts for v in valores):
        return True
    if not es_visible(ctl, campos, datos, prof + 1):
        return False
    v = datos.get(ctl.get("id"))
    if isinstance(v, list):
        v = ",".join(str(x) for x in v)
    return ("" if v is None else str(v)) in valores


def _cuenta(c: dict) -> bool:
    tipo = c.get("tipo")
    if tipo == "si_no":
        return True   # el valor (Sí/No) se filtra aparte: N/A no cuenta
    if tipo == "escala_1_5":
        return True
    if tipo == "numero":
        return any(c.get(k) not in (None, "") for k in ("rangoMin", "rangoMax"))
    if tipo in ("select", "radio", "checkbox_multi"):
        return bool(c.get("severidad"))
    return False


def puntaje(campos: Any, datos: Any) -> Optional[dict]:
    """{'total','ok','pct','nivel','fallan'} o None si no hay puntos de control respondidos."""
    if not isinstance(campos, list) or not isinstance(datos, dict):
        return None
    items = []
    for c in campos:
        if not isinstance(c, dict):
            continue
        v = datos.get(c.get("id"))
        if _vacio(v) or not es_visible(c, campos, datos) or not _cuenta(c):
            continue
        if c.get("tipo") == "si_no" and v not in ("Sí", "No"):
            continue
        items.append((c.get("etiqueta") or "", not respuesta_es_hallazgo(c, v)))
    if not items:
        return None
    ok = sum(1 for _, bien in items if bien)
    pct = int(ok / len(items) * 100 + 0.5)   # redondeo «hacia arriba en .5», como Math.round
    return {"total": len(items), "ok": ok, "pct": pct,
            "nivel": "alto" if pct >= 90 else "medio" if pct >= 70 else "bajo",
            "fallan": [e for e, bien in items if not bien]}
