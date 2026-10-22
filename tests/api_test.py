"""La API de verdad: Flask + Postgres + RLS, recorriendo las rutas como lo hace la app.

Existe porque un fallo se escapó: una ruta llamada alertas() tapaba al módulo del mismo
nombre y TODO envío nuevo fallaba al sincronizar. Las pruebas de cada pieza pasaban; lo
que fallaba era la unión. Aquí se prueba la unión.

Necesita una base con las migraciones aplicadas:
  SKF_TEST_DB_APP   = postgresql://skf_app:...@host/base     (la que usa la app)
  SKF_TEST_DB_OWNER = postgresql://skf_owner:...@host/base   (solo para preparar datos)
Sin esas variables se omite (en el CI siempre se corre).

Ejecutar:  python3 tests/api_test.py
"""
import logging
import os
import sys
import unittest
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
APP_DB, OWNER_DB = os.environ.get("SKF_TEST_DB_APP"), os.environ.get("SKF_TEST_DB_OWNER")

ORG = str(uuid.uuid4())
DUENO, EDITOR, ASESOR = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
SUF = uuid.uuid4().hex[:8]
MAIL_D, MAIL_E, MAIL_A = f"dueno-{SUF}@api-test.co", f"editor-{SUF}@api-test.co", f"asesor-{SUF}@api-test.co"
CLAVE = "Clave12345a"


def preparar():
    import psycopg2
    with psycopg2.connect(OWNER_DB) as con, con.cursor() as cur:
        cur.execute("INSERT INTO organizations (id, nombre, pais) VALUES (%s, 'API test', 'CO')", (ORG,))
        cur.execute("INSERT INTO users (id, email, password_hash, nombre) VALUES "
                    "(%s, %s, crypt(%s, gen_salt('bf', 4)), 'Diana'), (%s, %s, crypt(%s, gen_salt('bf', 4)), 'Edgar')",
                    (DUENO, MAIL_D, CLAVE, EDITOR, MAIL_E, CLAVE))
        cur.execute("INSERT INTO memberships (org_id, user_id, rol) VALUES (%s, %s, 'dueno'), (%s, %s, 'editor')",
                    (ORG, DUENO, ORG, EDITOR))
        cur.execute("INSERT INTO users (id, email, password_hash, nombre, es_asesor) VALUES (%s, %s, crypt(%s, gen_salt('bf', 4)), 'Asesora', true)",
                    (ASESOR, MAIL_A, CLAVE))


def limpiar():
    import psycopg2
    with psycopg2.connect(OWNER_DB) as con, con.cursor() as cur:
        cur.execute("DELETE FROM authorized_emails WHERE org_id IN (SELECT org_id FROM memberships WHERE user_id = %s) OR org_id = %s", (ASESOR, ORG))
        cur.execute("DELETE FROM organizations WHERE id = %s OR id IN (SELECT org_id FROM memberships WHERE user_id = %s)", (ORG, ASESOR))
        cur.execute("DELETE FROM users WHERE id IN (%s, %s, %s)", (DUENO, EDITOR, ASESOR))


APP = None


def setUpModule():
    """Una sola app y un solo juego de datos para todas las clases; se limpia al final."""
    global APP
    if not (APP_DB and OWNER_DB):
        return
    os.environ.update(DATABASE_URL=APP_DB, SECRET_KEY="x" * 40, SKF_ENV="local", RESEND_API_KEY="")
    logging.disable(logging.CRITICAL)
    from app import crear_app
    APP = crear_app()
    APP.config.update(WTF_CSRF_ENABLED=False, TESTING=True)
    preparar()


def tearDownModule():
    if APP is not None:
        limpiar()


@unittest.skipUnless(APP_DB and OWNER_DB, "sin base de pruebas (SKF_TEST_DB_APP / SKF_TEST_DB_OWNER)")
class Api(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = APP

    def entrar(self, c, email):
        r = c.post("/login", data={"email": email, "password": CLAVE})
        self.assertEqual(r.status_code, 302, "el inicio de sesión debe redirigir")

    def test_1_envio_nuevo_se_guarda_y_publico_responde(self):
        pid, tok = str(uuid.uuid4()), "tok-" + SUF
        with self.app.test_client() as c:
            self.entrar(c, MAIL_D)
            r = c.post("/api/sync", json={"operaciones": [{"opId": "p", "tipo": "plantilla", "datos": {
                "id": pid, "nombre": "Lista", "publica": True, "share_token": tok, "correo_notificacion": "jefe@api-test.co",
                "campos": [{"id": "a", "tipo": "si_no", "etiqueta": "¿Orden?"}]}}]})
            self.assertTrue(r.get_json()["resultados"][0]["ok"])
            eid = str(uuid.uuid4())
            env = {"opId": "e", "tipo": "envio", "datos": {"id": eid, "plantilla_id": pid, "plantilla_nombre": "Lista",
                                                         "datos": {"a": "No"}, "estado": "enviado"}}
            r = c.post("/api/sync", json={"operaciones": [env]}).get_json()["resultados"][0]
            self.assertTrue(r["ok"], f"un envío nuevo (con puntaje bajo, que evalúa el aviso) debe guardarse: {r}")
            r = c.post("/api/sync", json={"operaciones": [env]}).get_json()["resultados"][0]
            self.assertTrue(r["ok"], "reintentar el mismo envío no debe fallar")
            envios = c.get("/api/envios").get_json()
            self.assertIn(eid, [e["id"] for e in envios.get("envios", envios if isinstance(envios, list) else [])])
            c.post("/logout")
            r = c.post("/api/publico/envio", json={"id": str(uuid.uuid4()), "token": tok, "datos": {"a": "No"}, "llenadoPor": "Visita"})
            self.assertEqual(r.status_code, 201, f"envío público: {r.get_json()}")

    def test_2_equipo_reglas(self):
        with self.app.test_client() as c:
            self.entrar(c, MAIL_D)
            j = c.get("/api/equipo").get_json()
            self.assertTrue(j["disponible"])
            self.assertEqual(sorted(m["rol"] for m in j["miembros"]), ["dueno", "editor"])
            r = c.post("/api/equipo/invitar", json={"email": f"nueva-{SUF}@api-test.co", "rol": "lector"})
            self.assertEqual(r.status_code, 200, r.get_json())
            self.assertIn("/registro?email=", r.get_json()["enlace"])
            self.assertEqual(c.post("/api/equipo/invitar", json={"email": MAIL_E, "rol": "lector"}).status_code, 409)
            self.assertEqual(c.post("/api/equipo/invitar", json={"email": "x@api-test.co", "rol": "dueno"}).status_code, 400)
            self.assertEqual(c.post(f"/api/equipo/{DUENO}/rol", json={"rol": "lector"}).status_code, 400, "a sí mismo")
            c.post("/logout")
            self.entrar(c, MAIL_E)
            self.assertEqual(c.post("/api/equipo/invitar", json={"email": f"otra-{SUF}@api-test.co", "rol": "editor"}).status_code, 403)
            self.assertEqual(c.delete(f"/api/equipo/{DUENO}").status_code, 403)
            self.assertEqual(c.get("/api/equipo").get_json()["invitaciones"], [], "un editor no ve invitaciones")
            c.post("/logout")
            self.assertEqual(c.get("/api/equipo").status_code, 401)

    def test_3_registro_precarga_el_correo_invitado(self):
        with self.app.test_client() as c:
            html = c.get("/registro?email=alguien%40api-test.co").get_data(as_text=True)
            self.assertIn('value="alguien@api-test.co"', html)
            html = c.get('/registro?email="><script>x</script>').get_data(as_text=True)
            self.assertNotIn("<script>x</script>", html, "el correo de la URL se escapa")


@unittest.skipUnless(APP_DB and OWNER_DB, "sin base de pruebas (SKF_TEST_DB_APP / SKF_TEST_DB_OWNER)")
class Asesor(unittest.TestCase):
    """Un asesor con varias empresas: crea clientes, cambia de empresa y los datos no se cruzan."""
    @classmethod
    def setUpClass(cls):
        cls.app = APP

    def entrar(self, c, email):
        self.assertEqual(c.post("/login", data={"email": email, "password": CLAVE}).status_code, 302)

    def test_4_asesor_cambia_de_empresa_sin_cruzar_datos(self):
        with self.app.test_client() as c:
            self.entrar(c, MAIL_A)
            self.assertTrue(c.get("/api/yo").get_json()["usuario"]["esAsesor"])
            ids = []
            for nombre in ("Cliente Uno", "Cliente Dos"):
                r = c.post("/api/asesor/empresas", json={"nombre": nombre, "pais": "CO"})
                self.assertEqual(r.status_code, 201, r.get_json())
                ids.append(r.get_json()["id"])
            emp = c.get("/api/empresas").get_json()
            self.assertEqual(sorted(e["nombre"] for e in emp["empresas"]), ["Cliente Dos", "Cliente Uno"])
            # entrar a «Cliente Uno» y registrar un formulario allí
            self.assertEqual(c.post("/api/empresas/activa", json={"orgId": ids[0]}).status_code, 200)
            self.assertEqual(c.get("/api/yo").get_json()["usuario"]["orgId"], ids[0])
            pid = str(uuid.uuid4())
            r = c.post("/api/sync", json={"operaciones": [{"opId": "p", "tipo": "plantilla", "datos": {
                "id": pid, "nombre": "Inspección Uno", "campos": [{"id": "a", "tipo": "si_no", "etiqueta": "P"}]}}]})
            self.assertTrue(r.get_json()["resultados"][0]["ok"])
            # en «Cliente Dos» ese formulario NO existe
            self.assertEqual(c.post("/api/empresas/activa", json={"orgId": ids[1]}).status_code, 200)
            boot = c.get("/api/bootstrap").get_json()
            self.assertEqual(boot["organizacion"]["nombre"], "Cliente Dos")
            self.assertNotIn(pid, [p["id"] for p in boot["plantillas"]])
            # y de vuelta en «Cliente Uno» sí
            c.post("/api/empresas/activa", json={"orgId": ids[0]})
            self.assertIn(pid, [p["id"] for p in c.get("/api/bootstrap").get_json()["plantillas"]])
            # el resumen trae las dos, con su evidencia
            res = c.get("/api/asesor/resumen").get_json()
            self.assertEqual(len(res["empresas"]), 2)
            self.assertFalse(any(e["tieneDueno"] for e in res["empresas"]))
            # elegir una empresa ajena: rechazado, y la activa no cambia
            self.assertEqual(c.post("/api/empresas/activa", json={"orgId": ORG}).status_code, 403)
            self.assertEqual(c.get("/api/yo").get_json()["usuario"]["orgId"], ids[0])
            # invita al cliente como dueño de SU cuenta
            r = c.post("/api/equipo/invitar", json={"email": f"gerente-{SUF}@api-test.co", "rol": "dueno"})
            self.assertEqual(r.status_code, 200, r.get_json())

    def test_5_no_asesor_no_crea_empresas(self):
        with self.app.test_client() as c:
            self.entrar(c, MAIL_E)
            r = c.post("/api/asesor/empresas", json={"nombre": "Colada", "pais": "CO"})
            self.assertEqual(r.status_code, 403)
            self.assertFalse(c.get("/api/yo").get_json()["usuario"]["esAsesor"])


class Nombres(unittest.TestCase):
    """Sin base: el módulo de avisos no puede quedar tapado por otra definición."""
    def test_modulo_de_avisos_es_un_modulo(self):
        import types
        os.environ.setdefault("SECRET_KEY", "x" * 40)
        import app.api as api
        self.assertIsInstance(api.correo_avisos, types.ModuleType)
        for f in ("evaluar", "enviar", "avisar_publico", "enviar_invitacion"):
            self.assertTrue(callable(getattr(api.correo_avisos, f)), f)


if __name__ == "__main__":
    unittest.main(verbosity=1)
