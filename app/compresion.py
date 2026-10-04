"""Compresión gzip de las respuestas de texto.

Medido (4G lenta, CPU 4× más lenta): comprimir baja el peso de cada pantalla
cerca de un 65 % y el tiempo hasta ver el contenido de 1,2 s a 0,7 s. Sin
esto, `chart.min.js` viaja con sus 200 KB completos y `dashboard.html` con 112.

No usa dependencias nuevas: es un `after_request` sobre `gzip` de la
biblioteca estándar.

Qué NO se comprime, a propósito:
  · Respuestas que ponen cookies (sesión, token CSRF de formularios).
  · Las pantallas de acceso y administración (llevan tokens CSRF incrustados).
  · `/api/csrf`, que entrega un token secreto.
  Mezclar secretos con contenido que un atacante puede influir y comprimirlo es
  la base del ataque BREACH; estas rutas son pocas y pequeñas, así que no
  vale la pena el riesgo.
"""
from __future__ import annotations

import gzip
from collections import OrderedDict

from flask import Flask, Response, request

# Solo texto. Imágenes (png), fuentes y demás ya vienen comprimidas.
COMPRIMIBLES = {
    "text/html", "text/css", "text/plain", "text/javascript",
    "application/javascript", "application/json", "application/manifest+json",
    "image/svg+xml",
}
MINIMO_BYTES = 600          # por debajo, la cabecera de gzip cuesta más de lo que ahorra
NIVEL_ESTATICO = 6          # se comprime una vez y se guarda
NIVEL_DINAMICO = 5          # respuestas de la API: más rápido, se comprimen en cada petición
EXCLUIDAS = ("/api/csrf", "/login", "/logout", "/registro", "/recuperar",
             "/restablecer", "/cambiar", "/admin")
MAX_EN_CACHE = 64

# Archivos estáticos ya comprimidos, por (ETag): se ahorra CPU en un servidor de
# un solo proceso. El ETag cambia cuando cambia el archivo.
_cache: "OrderedDict[str, bytes]" = OrderedDict()


def _acepta_gzip(cabecera: str) -> bool:
    """¿Acepta el cliente gzip? Respeta q=0 («gzip;q=0» significa que NO lo acepta)."""
    for parte in cabecera.lower().split(","):
        nombre, _, params = parte.strip().partition(";")
        if nombre.strip() not in ("gzip", "x-gzip", "*"):
            continue
        q = 1.0
        params = params.strip()
        if params.startswith("q="):
            try:
                q = float(params[2:])
            except ValueError:
                q = 0.0
        return q > 0
    return False


def _comprimir(datos: bytes, etag: str | None) -> bytes:
    if etag:
        if etag in _cache:
            _cache.move_to_end(etag)
            return _cache[etag]
        comprimido = gzip.compress(datos, NIVEL_ESTATICO, mtime=0)
        _cache[etag] = comprimido
        while len(_cache) > MAX_EN_CACHE:
            _cache.popitem(last=False)
        return comprimido
    return gzip.compress(datos, NIVEL_DINAMICO, mtime=0)


def registrar_compresion(app: Flask) -> None:
    @app.after_request
    def comprimir(resp: Response) -> Response:
        if resp.mimetype not in COMPRIMIBLES:
            return resp
        # Siempre se avisa a las cachés intermedias que la respuesta varía según
        # Accept-Encoding, también cuando este cliente concreto no acepta gzip.
        resp.vary.add("Accept-Encoding")

        if (request.method != "GET" or resp.status_code != 200
                or resp.headers.get("Content-Encoding")
                or resp.headers.get("Set-Cookie")
                or request.path.startswith(EXCLUIDAS)
                or not _acepta_gzip(request.headers.get("Accept-Encoding", ""))):
            return resp

        resp.direct_passthrough = False          # send_file entrega un flujo: se lee entero
        datos = resp.get_data()
        if len(datos) < MINIMO_BYTES:
            return resp

        etag = resp.headers.get("ETag")
        resp.set_data(_comprimir(datos, etag))   # fija Content-Length
        resp.headers["Content-Encoding"] = "gzip"
        if etag:
            # El cuerpo cambió de bytes: el ETag fuerte ya no describe lo que se
            # envía. Como débil, el navegador sigue revalidando con If-None-Match.
            resp.set_etag(resp.get_etag()[0], weak=True)
        return resp
