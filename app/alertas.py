"""Aviso por correo cuando una inspección sale con puntaje bajo.

Se evalúa en el servidor, con las reglas de `app.puntaje`, al recibir un envío NUEVO (un
reintento de la cola sin conexión no vuelve a avisar). Un lote de sincronización genera como
máximo UN correo por destinatario: quien vuelve de una jornada sin señal no recibe 30 correos.
El destinatario es el «Correo de notificación» del formulario. Sin ese correo, o sin
RESEND_API_KEY, no se envía nada y no se afecta el guardado.
"""

from __future__ import annotations

import logging
import re
from typing import Any, Optional

from markupsafe import escape

from . import db
from .config import Config
from .puntaje import UMBRAL_BAJO, puntaje

log = logging.getLogger(__name__)
_CORREO = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_MAX_FILAS = 10
MAX_AVISOS_PUBLICOS_POR_HORA = 3   # por formulario: un enlace abierto no puede inundar de correos


def evaluar(cur, envio: dict) -> Optional[dict]:
    """¿Este envío recién guardado merece aviso? Devuelve los datos del aviso o None."""
    try:
        if (envio.get("estado") or "enviado") != "enviado":
            return None
        pid = envio.get("plantilla_id")
        if not pid:
            return None
        cur.execute("SAVEPOINT alerta_puntaje")
        cur.execute("SELECT nombre, campos, correo_notificacion FROM plantillas WHERE id = %s", (pid,))
        fila = cur.fetchone()
        cur.execute("RELEASE SAVEPOINT alerta_puntaje")
        if not fila:
            return None
        correo = (fila["correo_notificacion"] or "").strip()
        if not _CORREO.match(correo):
            return None
        p = puntaje(fila["campos"], envio.get("datos") or {})
        if not p or p["pct"] >= UMBRAL_BAJO:
            return None
        return {"correo": correo, "formulario": fila["nombre"] or envio.get("plantilla_nombre") or "Formulario",
                "pct": p["pct"], "ok": p["ok"], "total": p["total"], "fallan": p["fallan"],
                "llenado_por": (envio.get("llenado_por") or "").strip()}
    except Exception:
        log.exception("No se pudo evaluar el aviso de puntaje")
        try:
            cur.execute("ROLLBACK TO SAVEPOINT alerta_puntaje")
        except Exception:
            pass
        return None


def _html(items: list) -> str:
    filas = []
    for a in items[:_MAX_FILAS]:
        quien = f" · {escape(a['llenado_por'])}" if a["llenado_por"] else ""
        quien += " · formulario público" if a.get("publico") else ""
        fallan = "; ".join(str(escape(x)) for x in a["fallan"][:5]) + ("…" if len(a["fallan"]) > 5 else "")
        filas.append(
            f'<p style="margin:14px 0 4px"><b>{escape(a["formulario"])}</b>{quien} — '
            f'<span style="color:#f87171;font-weight:700">{a["pct"]} %</span> '
            f'({a["ok"]} de {a["total"]} puntos cumplen)</p>'
            f'<p style="margin:0;font-size:13px;color:#8497a8">No cumple: {fallan or "—"}</p>')
    mas = f'<p style="color:#8497a8">…y {len(items) - _MAX_FILAS} más.</p>' if len(items) > _MAX_FILAS else ""
    enlace = (f'<p style="margin:24px 0"><a href="{escape(Config.URL_PUBLICA)}/dashboard.html" '
              'style="background:#3fd9d2;color:#070d14;padding:12px 26px;border-radius:8px;'
              'text-decoration:none;font-weight:700">Ver el panel</a></p>') if Config.URL_PUBLICA else ""
    return ('<div style="font-family:Barlow,Segoe UI,sans-serif;background:#070d14;color:#cdd9e3;'
            'padding:32px;border-radius:12px;max-width:560px">'
            '<h2 style="color:#3fd9d2;margin:0 0 8px">Inspección con cumplimiento bajo</h2>'
            f'<p>Se registró lo siguiente con menos de {UMBRAL_BAJO} % de cumplimiento:</p>'
            f'{"".join(filas)}{mas}{enlace}'
            '<p style="font-size:12px;color:#8497a8">Recibes este aviso porque tu correo está como '
            '«Correo de notificación» del formulario.</p></div>')


def enviar(avisos: list) -> int:
    """Manda un correo por destinatario. Nunca lanza: devuelve cuántos correos salieron."""
    if not avisos:
        return 0
    if not Config.RESEND_API_KEY:
        log.warning("RESEND_API_KEY sin configurar; no se enviaron %d aviso(s) de puntaje bajo.", len(avisos))
        return 0
    import requests
    por_correo: dict = {}
    for a in avisos:
        por_correo.setdefault(a["correo"].lower(), []).append(a)
    enviados = 0
    for correo, items in por_correo.items():
        try:
            peor = min(i["pct"] for i in items)
            asunto = (f"⚠️ Inspección con cumplimiento bajo ({peor} %) — {items[0]['formulario']}"
                      if len(items) == 1 else f"⚠️ {len(items)} inspecciones con cumplimiento bajo")
            r = requests.post(
                "https://api.resend.com/emails",
                headers={"Authorization": f"Bearer {Config.RESEND_API_KEY}", "Content-Type": "application/json"},
                json={"from": Config.CORREO_REMITENTE, "to": [correo], "subject": asunto, "html": _html(items)},
                timeout=8,
            )
            if r.status_code < 300:
                enviados += 1
            else:
                log.warning("Resend rechazó el aviso de puntaje (%s)", r.status_code)
        except Exception:
            log.exception("Fallo al enviar el aviso de puntaje bajo")
    return enviados


def avisar_publico(envio_id: str, token: str) -> int:
    """Aviso para un envío de un formulario PÚBLICO (quien lo llena no tiene sesión).

    Usa las funciones de la migración 007, que lo reservan una sola vez y limitan los correos
    por hora y por formulario. Nunca lanza: si la migración no se corrió o algo falla, el envío
    ya está guardado y simplemente no se avisa. Devuelve cuántos correos salieron.
    """
    try:
        with db.sesion_privilegiada() as cur:
            cur.execute("SELECT * FROM skf_publico_aviso_datos(%s, %s)", (envio_id, token))
            d = cur.fetchone()
            if not d or d["ya_avisado"]:
                return 0
            correo = (d["correo"] or "").strip()
            if not _CORREO.match(correo):
                return 0
            p = puntaje(d["campos"], d["datos"])
            if not p or p["pct"] >= UMBRAL_BAJO:
                return 0
            cur.execute("SELECT skf_publico_aviso_marcar(%s, %s, %s) AS enviar",
                        (envio_id, token, MAX_AVISOS_PUBLICOS_POR_HORA))
            if not cur.fetchone()["enviar"]:
                log.info("Aviso de puntaje bajo omitido (reintento o límite por hora) para el envío %s", envio_id)
                return 0
            aviso = {"correo": correo, "formulario": d["formulario"] or "Formulario", "pct": p["pct"],
                     "ok": p["ok"], "total": p["total"], "fallan": p["fallan"],
                     "llenado_por": (d["llenado_por"] or "").strip(), "publico": True}
        return enviar([aviso])
    except Exception:
        log.exception("No se pudo avisar del puntaje bajo de un envío público "
                      "(¿se corrió la migración 007?)")
        return 0
