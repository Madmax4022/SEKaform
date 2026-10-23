"""Notificaciones push al celular (Web Push), sin dependencias que compilar.

Web Push son dos piezas estándar:
  · VAPID (RFC 8292): el servidor se identifica ante el servicio de push del
    navegador (Google, Apple, Mozilla) con un JWT firmado con ES256.
  · Cifrado del mensaje (RFC 8291 + RFC 8188, «aes128gcm»): solo el celular
    suscrito puede leer el aviso; el servicio de push ve bytes cifrados.

Se implementan con `cryptography` en vez de `pywebpush`: esa librería arrastra
`http-ece`, que hay que compilar y que falla en imágenes slim.

Configuración (Cloud Run): VAPID_PUBLIC_KEY y VAPID_PRIVATE_KEY (Secret Manager),
generadas con scripts/generar_vapid.py. Sin ellas, los avisos quedan apagados
y la app funciona igual.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import struct
import time
from typing import Iterable, Optional
from urllib.parse import urlparse

import requests
from cryptography.hazmat.primitives import hashes, hmac, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

log = logging.getLogger(__name__)


def b64u(datos: bytes) -> str:
    return base64.urlsafe_b64encode(datos).rstrip(b"=").decode()


def de_b64u(texto: str) -> bytes:
    return base64.urlsafe_b64decode(texto + "=" * (-len(texto) % 4))


def _hmac(clave: bytes, datos: bytes) -> bytes:
    h = hmac.HMAC(clave, hashes.SHA256())
    h.update(datos)
    return h.finalize()


def clave_publica() -> str:
    return os.environ.get("VAPID_PUBLIC_KEY", "").strip()


def _clave_privada() -> Optional[ec.EllipticCurvePrivateKey]:
    raw = os.environ.get("VAPID_PRIVATE_KEY", "").strip()
    if not raw:
        return None
    try:
        crudo = de_b64u(raw)
        if len(crudo) != 32:
            raise ValueError("debe medir 32 bytes")
        return ec.derive_private_key(int.from_bytes(crudo, "big"), ec.SECP256R1())
    except Exception:  # clave mal copiada: se apaga en vez de tumbar la app
        log.error("VAPID_PRIVATE_KEY no es válida: los avisos push quedan apagados.")
        return None


def disponible() -> bool:
    """Hay llaves y son pareja (una pública que no corresponde haría fallar cada envío)."""
    k = _clave_privada()
    if not clave_publica() or k is None:
        return False
    pub = k.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    if b64u(pub) != clave_publica():
        log.error("VAPID_PUBLIC_KEY no corresponde a VAPID_PRIVATE_KEY: los avisos push quedan apagados.")
        return False
    return True


def generar_claves() -> tuple[str, str]:
    """(pública, privada) en base64url, como las pide el navegador."""
    k = ec.generate_private_key(ec.SECP256R1())
    pub = k.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return b64u(pub), b64u(k.private_numbers().private_value.to_bytes(32, "big"))


def jwt_vapid(endpoint: str, privada: ec.EllipticCurvePrivateKey, sujeto: str, ahora: Optional[int] = None) -> str:
    """JWT ES256 para el origen del servicio de push, válido 12 horas."""
    u = urlparse(endpoint)
    cuerpo = {"aud": f"{u.scheme}://{u.netloc}", "exp": int(ahora or time.time()) + 12 * 3600, "sub": sujeto}
    firmado = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode()) + "." + \
        b64u(json.dumps(cuerpo, separators=(",", ":")).encode())
    r, s = decode_dss_signature(privada.sign(firmado.encode(), ec.ECDSA(hashes.SHA256())))
    return firmado + "." + b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def cifrar(mensaje: bytes, p256dh: str, auth: str, *, _efimera=None, _sal: Optional[bytes] = None) -> bytes:
    """Cuerpo «aes128gcm» (RFC 8291 §3.4, un solo registro)."""
    ua_pub = de_b64u(p256dh)
    secreto_auth = de_b64u(auth)
    efimera = _efimera or ec.generate_private_key(ec.SECP256R1())
    as_pub = efimera.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    compartido = efimera.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_pub))
    prk_clave = _hmac(secreto_auth, compartido)
    ikm = _hmac(prk_clave, b"WebPush: info\x00" + ua_pub + as_pub + b"\x01")
    sal = _sal or os.urandom(16)
    prk = _hmac(sal, ikm)
    cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
    nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]
    cifrado = AESGCM(cek).encrypt(nonce, mensaje + b"\x02", None)   # \x02: último registro
    return sal + struct.pack("!IB", 4096, len(as_pub)) + as_pub + cifrado


def enviar(sub: dict, aviso: dict, *, sujeto: Optional[str] = None, timeout: float = 5.0) -> int:
    """Envía un aviso a una suscripción. Devuelve el código HTTP (0 si no salió)."""
    if not disponible():
        return 0
    privada = _clave_privada()
    from .config import Config
    sujeto = sujeto or Config.URL_PUBLICA or "mailto:soporte@kanansentinel.com"
    cuerpo = cifrar(json.dumps(aviso, ensure_ascii=False).encode(), sub["p256dh"], sub["auth"])
    try:
        r = requests.post(sub["endpoint"], data=cuerpo, timeout=timeout, headers={
            "Authorization": f"vapid t={jwt_vapid(sub['endpoint'], privada, sujeto)}, k={clave_publica()}",
            "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
            "TTL": "86400", "Urgency": "high",
        })
        return r.status_code
    except requests.RequestException as e:
        log.warning("Push no enviado: %s", e)
        return 0


def enviar_a(subs: Iterable[dict], aviso: dict) -> int:
    """Envía a varias y anota el resultado (borra las que el navegador dio de baja)."""
    from . import db
    n = 0
    for s in subs:
        codigo = enviar(s, aviso)
        ok = 200 <= codigo < 300
        n += ok
        try:
            with db.sesion_privilegiada() as cur:
                cur.execute("SELECT skf_push_resultado(%s, %s, %s)", (s["endpoint"], ok, codigo in (404, 410)))
        except Exception as e:  # anotar es secundario: nunca debe romper la petición
            log.warning("No se anotó el resultado del push: %s", e)
    return n
