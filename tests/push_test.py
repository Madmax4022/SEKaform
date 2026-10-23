"""Web Push (app/push.py): cifrado RFC 8291 contra su vector oficial, ida y vuelta y JWT VAPID.

Ejecutar: python3 tests/push_test.py
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from cryptography.hazmat.primitives import hashes, hmac  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature  # noqa: E402
from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: E402

from app import push  # noqa: E402

# RFC 8291, Apéndice A
A = {
    "auth": "BTBZMqHH6r4Tts7J_aSIgg",
    "ua_pub": "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    "ua_priv": "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
    "as_priv": "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
    "sal": "DGv6ra1nlYgDCS1FRnbzlw",
    "texto": b"When I grow up, I want to be a watermelon",
    "cuerpo": "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
}


def _priv(b64):
    return ec.derive_private_key(int.from_bytes(push.de_b64u(b64), "big"), ec.SECP256R1())


def _h(k, d):
    h = hmac.HMAC(k, hashes.SHA256()); h.update(d); return h.finalize()


def descifrar(cuerpo: bytes, ua_priv, ua_pub: bytes, auth: bytes) -> bytes:
    """Lo que hace el navegador al recibir (implementación independiente)."""
    sal, idlen = cuerpo[:16], cuerpo[20]
    as_pub = cuerpo[21:21 + idlen]
    cifrado = cuerpo[21 + idlen:]
    compartido = ua_priv.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_pub))
    ikm = _h(_h(auth, compartido), b"WebPush: info\x00" + ua_pub + as_pub + b"\x01")
    prk = _h(sal, ikm)
    claro = AESGCM(_h(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]).decrypt(
        _h(prk, b"Content-Encoding: nonce\x00\x01")[:12], cifrado, None)
    return claro.rstrip(b"\x00")[:-1]


class Cifrado(unittest.TestCase):
    def test_vector_rfc8291(self):
        cuerpo = push.cifrar(A["texto"], A["ua_pub"], A["auth"], _efimera=_priv(A["as_priv"]), _sal=push.de_b64u(A["sal"]))
        self.assertEqual(push.b64u(cuerpo), A["cuerpo"])

    def test_ida_y_vuelta(self):
        ua = ec.generate_private_key(ec.SECP256R1())
        from cryptography.hazmat.primitives import serialization
        ua_pub = ua.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        auth = os.urandom(16)
        msg = json.dumps({"titulo": "🔴 Hallazgo crítico", "url": "/hallazgos.html"}, ensure_ascii=False).encode()
        cuerpo = push.cifrar(msg, push.b64u(ua_pub), push.b64u(auth))
        self.assertEqual(descifrar(cuerpo, ua, ua_pub, auth), msg)
        self.assertNotIn(b"Hallazgo", cuerpo, "el servicio de push solo ve bytes cifrados")


class Vapid(unittest.TestCase):
    def test_jwt_firmado(self):
        pub, priv = push.generar_claves()
        self.assertEqual(len(push.de_b64u(pub)), 65)
        jwt = push.jwt_vapid("https://fcm.googleapis.com/fcm/send/abc", _priv(priv), "mailto:a@b.co", ahora=1000)
        cab, cuerpo, firma = jwt.split(".")
        self.assertEqual(json.loads(push.de_b64u(cuerpo)), {"aud": "https://fcm.googleapis.com", "exp": 1000 + 43200, "sub": "mailto:a@b.co"})
        r, s = int.from_bytes(push.de_b64u(firma)[:32], "big"), int.from_bytes(push.de_b64u(firma)[32:], "big")
        clave = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), push.de_b64u(pub))
        clave.verify(encode_dss_signature(r, s), (cab + "." + cuerpo).encode(), ec.ECDSA(hashes.SHA256()))

    def test_sin_claves_apagado(self):
        os.environ.pop("VAPID_PRIVATE_KEY", None); os.environ.pop("VAPID_PUBLIC_KEY", None)
        self.assertFalse(push.disponible())
        self.assertEqual(push.enviar({"endpoint": "https://x", "p256dh": "a", "auth": "b"}, {}), 0)
        os.environ["VAPID_PUBLIC_KEY"], os.environ["VAPID_PRIVATE_KEY"] = "x", "no-es-una-clave"
        self.assertFalse(push.disponible(), "una clave mal copiada apaga los avisos, no tumba la app")
        pub, priv = push.generar_claves(); otra, _ = push.generar_claves()
        os.environ["VAPID_PUBLIC_KEY"], os.environ["VAPID_PRIVATE_KEY"] = otra, priv
        self.assertFalse(push.disponible(), "llaves que no son pareja: apagado")
        os.environ["VAPID_PUBLIC_KEY"] = pub
        self.assertTrue(push.disponible())
        os.environ.pop("VAPID_PRIVATE_KEY"); os.environ.pop("VAPID_PUBLIC_KEY")


if __name__ == "__main__":
    unittest.main(verbosity=1)
