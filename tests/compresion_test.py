"""Compresión gzip (app/compresion.py): qué se comprime y, sobre todo, qué NO.

Usa un Flask mínimo (no la app completa, que necesita base de datos) con el
mismo middleware. Ejecutar:  python tests/compresion_test.py
"""
import gzip
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from flask import Flask, jsonify, make_response, send_from_directory  # noqa: E402
from app.compresion import registrar_compresion, _acepta_gzip  # noqa: E402

GRANDE = "<p>" + ("hola mundo SST " * 300) + "</p>"          # ~4,5 KB, muy comprimible
TMP = tempfile.mkdtemp()
with open(os.path.join(TMP, "grande.js"), "w") as f:
    f.write("var x = '" + "abc" * 2000 + "';")
with open(os.path.join(TMP, "chico.css"), "w") as f:
    f.write("a{}")


def crear():
    app = Flask(__name__)
    registrar_compresion(app)

    @app.route("/pagina")
    def pagina():
        return GRANDE

    @app.route("/chica")
    def chica():
        return "<p>hola</p>"

    @app.route("/api/datos")
    def datos():
        return jsonify({"filas": [{"nombre": "Formulario " + str(i)} for i in range(200)]})

    @app.route("/api/csrf")
    def csrf():
        return jsonify({"csrf_token": "secreto" * 100})

    @app.route("/login")
    def login():
        return "<form>" + ("campo " * 300) + "<input type=hidden name=csrf_token value=SECRETO></form>"

    @app.route("/con-cookie")
    def con_cookie():
        r = make_response(GRANDE)
        r.set_cookie("sesion", "abc")
        return r

    @app.route("/imagen")
    def imagen():
        r = make_response(b"\x89PNG" + b"\x00" * 5000)
        r.mimetype = "image/png"
        return r

    @app.route("/estatico/<path:n>")
    def estatico(n):
        return send_from_directory(TMP, n)

    @app.route("/ya", methods=["GET"])
    def ya():
        r = make_response(gzip.compress(GRANDE.encode()))
        r.headers["Content-Encoding"] = "gzip"
        r.mimetype = "text/html"
        return r

    @app.route("/error")
    def error():
        return GRANDE, 404

    @app.route("/post", methods=["GET", "POST"])
    def post():
        return GRANDE

    return app


GZ = {"Accept-Encoding": "gzip, deflate, br"}


class Compresion(unittest.TestCase):
    def setUp(self):
        self.c = crear().test_client()

    def test_html_grande_se_comprime_y_se_puede_leer(self):
        r = self.c.get("/pagina", headers=GZ)
        self.assertEqual(r.headers["Content-Encoding"], "gzip")
        self.assertEqual(gzip.decompress(r.data).decode(), GRANDE)
        self.assertLess(len(r.data), len(GRANDE) // 5)
        self.assertEqual(int(r.headers["Content-Length"]), len(r.data))
        self.assertIn("Accept-Encoding", r.headers["Vary"])

    def test_json_de_la_api_se_comprime(self):
        r = self.c.get("/api/datos", headers=GZ)
        self.assertEqual(r.headers["Content-Encoding"], "gzip")
        self.assertIn("Formulario 199", gzip.decompress(r.data).decode())

    def test_sin_accept_encoding_no_se_comprime_pero_avisa_a_las_caches(self):
        r = self.c.get("/pagina")
        self.assertNotIn("Content-Encoding", r.headers)
        self.assertEqual(r.data.decode(), GRANDE)
        self.assertIn("Accept-Encoding", r.headers["Vary"])

    def test_gzip_q0_significa_que_no_lo_acepta(self):
        for h in ("gzip;q=0", "gzip; q=0.0", "identity, gzip;q=0"):
            self.assertNotIn("Content-Encoding", self.c.get("/pagina", headers={"Accept-Encoding": h}).headers, h)
        self.assertIn("Content-Encoding", self.c.get("/pagina", headers={"Accept-Encoding": "gzip;q=0.5"}).headers)
        self.assertTrue(_acepta_gzip("br, gzip"))
        self.assertFalse(_acepta_gzip("br, deflate"))
        self.assertFalse(_acepta_gzip(""))

    def test_respuesta_pequena_no_se_comprime(self):
        self.assertNotIn("Content-Encoding", self.c.get("/chica", headers=GZ).headers)

    # ── lo que NO debe comprimirse (seguridad / correctitud) ──
    def test_el_token_csrf_nunca_se_comprime(self):
        self.assertNotIn("Content-Encoding", self.c.get("/api/csrf", headers=GZ).headers)

    def test_pantallas_de_acceso_no_se_comprimen(self):
        r = self.c.get("/login", headers=GZ)
        self.assertNotIn("Content-Encoding", r.headers)
        self.assertIn("SECRETO", r.data.decode())

    def test_respuesta_que_pone_cookie_no_se_comprime(self):
        self.assertNotIn("Content-Encoding", self.c.get("/con-cookie", headers=GZ).headers)

    def test_imagenes_no_se_tocan(self):
        r = self.c.get("/imagen", headers=GZ)
        self.assertNotIn("Content-Encoding", r.headers)
        self.assertEqual(len(r.data), 5004)

    def test_no_se_comprime_dos_veces(self):
        r = self.c.get("/ya", headers=GZ)
        self.assertEqual(gzip.decompress(r.data).decode(), GRANDE)   # un solo gzip, no doble

    def test_errores_y_escrituras_no_se_comprimen(self):
        self.assertNotIn("Content-Encoding", self.c.get("/error", headers=GZ).headers)
        self.assertNotIn("Content-Encoding", self.c.post("/post", headers=GZ).headers)

    # ── archivos estáticos (send_from_directory) ──
    def test_archivo_estatico_grande_se_comprime_y_conserva_la_cache(self):
        r = self.c.get("/estatico/grande.js", headers=GZ)
        self.assertEqual(r.headers["Content-Encoding"], "gzip")
        self.assertTrue(gzip.decompress(r.data).decode().startswith("var x = 'abc"))
        etag = r.headers["ETag"]
        self.assertTrue(etag.startswith("W/"), "el ETag debe pasar a débil: el cuerpo ya no es el original")
        self.assertIn("Last-Modified", r.headers)

    def test_revalidacion_devuelve_304_sin_cuerpo(self):
        r1 = self.c.get("/estatico/grande.js", headers=GZ)
        r2 = self.c.get("/estatico/grande.js", headers={**GZ, "If-None-Match": r1.headers["ETag"]})
        self.assertEqual(r2.status_code, 304)
        self.assertEqual(r2.data, b"")

    def test_archivo_estatico_chico_no_se_comprime(self):
        self.assertNotIn("Content-Encoding", self.c.get("/estatico/chico.css", headers=GZ).headers)

    def test_la_misma_respuesta_comprimida_se_reutiliza_de_la_cache(self):
        with self.c.get("/estatico/grande.js", headers=GZ) as r1, self.c.get("/estatico/grande.js", headers=GZ) as r2:
            self.assertEqual(r1.data, r2.data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
