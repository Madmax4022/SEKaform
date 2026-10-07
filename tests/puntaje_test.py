"""Puntaje de cumplimiento y aviso por correo (app/puntaje.py, app/alertas.py).

1. Paridad: las MISMAS reglas existen en JavaScript (field-types.js, lo que ve el usuario) y en
   Python (lo que decide si se avisa). Aquí corren con los mismos casos y deben coincidir.
2. El aviso: cuándo se evalúa, a quién va y que un lote produce un solo correo por destinatario.

Ejecutar:  python3 tests/puntaje_test.py     (requiere node)
"""
import json
import os
import subprocess
import sys
import unittest
from unittest import mock

RAIZ = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, RAIZ)
from app import alertas  # noqa: E402
from app.puntaje import puntaje  # noqa: E402

SI = [{"id": f"s{i}", "tipo": "si_no", "etiqueta": f"P{i}"} for i in range(4)]
CASOS = [
    (SI, {"s0": "Sí", "s1": "Sí", "s2": "Sí", "s3": "No"}),
    (SI, {"s0": "Sí", "s1": "N/A", "s2": "", "s3": "No"}),
    (SI, {"s0": "No", "s1": "No", "s2": "No", "s3": "No"}),
    (SI, {}),
    ([{"id": "e", "tipo": "escala_1_5", "opciones": ["1", "2", "3", "4", "5"]}], {"e": "2"}),
    ([{"id": "e", "tipo": "escala_1_5"}], {"e": "4 - Bueno"}),
    ([{"id": "q", "tipo": "numero", "rangoMin": 10, "rangoMax": 20}], {"q": "15"}),
    ([{"id": "q", "tipo": "numero", "rangoMin": 10, "rangoMax": 20}], {"q": "99,5"}),
    ([{"id": "q", "tipo": "numero", "rangoMin": 10}], {"q": "9"}),
    ([{"id": "q", "tipo": "numero"}], {"q": "999"}),
    ([{"id": "r", "tipo": "radio", "opciones": ["Bueno", "Deficiente"], "severidad": "menor"}], {"r": "Deficiente"}),
    ([{"id": "r", "tipo": "radio", "opciones": ["Bueno", "Deficiente"]}], {"r": "Deficiente"}),
    ([{"id": "m", "tipo": "checkbox_multi", "severidad": "mayor"}], {"m": ["Ok", "Vencido"]}),
    ([{"id": "m", "tipo": "checkbox_multi", "severidad": "mayor"}], {"m": ["Ok"]}),
    ([{"id": "n", "tipo": "texto"}], {"n": "x"}),
    # condicional: el campo oculto no cuenta
    ([{"id": "a", "tipo": "si_no"}, {"id": "b", "tipo": "si_no", "mostrarSi": {"campoId": "a", "valores": ["No"]}}],
     {"a": "Sí", "b": "No"}),
    ([{"id": "a", "tipo": "si_no"}, {"id": "b", "tipo": "si_no", "mostrarSi": {"campoId": "a", "valores": ["No"]}}],
     {"a": "No", "b": "No"}),
    # dependencia rota: el campo se muestra y cuenta
    ([{"id": "b", "tipo": "si_no", "mostrarSi": {"campoId": "nada", "valores": ["No"]}}], {"b": "No"}),
    # 1/3 = 33,33 y 5/8 = 62,5 (redondeo .5 hacia arriba, como Math.round)
    ([{"id": f"s{i}", "tipo": "si_no"} for i in range(8)],
     {f"s{i}": ("Sí" if i < 5 else "No") for i in range(8)}),
]

for _campos, _ in CASOS:
    for _c in _campos:
        _c.setdefault("etiqueta", "Campo " + _c["id"])

JS = r"""
const fs=require('fs'),vm=require('vm');const ctx={};vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[1],'utf8')+'\nthis.pun=skfPuntaje;',ctx);
const casos=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
console.log(JSON.stringify(casos.map(([c,d])=>{const r=ctx.pun(c,d);return r&&{total:r.total,ok:r.ok,pct:r.pct,fallan:r.fallan};})));
"""


class Paridad(unittest.TestCase):
    def test_python_y_javascript_dan_lo_mismo(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "casos.json")
            with open(f, "w") as fh:
                json.dump(CASOS, fh)
            out = subprocess.run(["node", "-e", JS, os.path.join(RAIZ, "field-types.js"), f],
                                 capture_output=True, text=True, check=True).stdout
        js = json.loads(out)
        for i, (campos, datos) in enumerate(CASOS):
            p = puntaje(campos, datos)
            py = p and {"total": p["total"], "ok": p["ok"], "pct": p["pct"], "fallan": p["fallan"]}
            self.assertEqual(py, js[i], f"caso {i}: Python {py} ≠ JavaScript {js[i]}")


class Datos(unittest.TestCase):
    def test_entradas_raras_no_lanzan(self):
        for campos, datos in [(None, {}), ([], None), ("x", "y"), ([None, 3, {}], {"a": 1}), ([{"id": "a"}], {})]:
            self.assertIsNone(puntaje(campos, datos))


class FakeCur:
    def __init__(self, fila):
        self.fila, self.sql = fila, []

    def execute(self, q, *a):
        self.sql.append(q)

    def fetchone(self):
        return self.fila


def fila(correo="jefe@empresa.com", campos=SI):
    return {"nombre": "Lista SST", "campos": campos, "correo_notificacion": correo}


MALO = {"estado": "enviado", "plantilla_id": "p", "llenado_por": "Ana",
        "datos": {"s0": "No", "s1": "No", "s2": "Sí", "s3": "Sí"}}   # 50 %
BUENO = {**MALO, "datos": {"s0": "Sí", "s1": "Sí", "s2": "Sí", "s3": "Sí"}}      # 100 %
LIMITE = {**MALO, "datos": {"s0": "Sí", "s1": "Sí", "s2": "Sí", "s3": "No"}}     # 75 %


class Aviso(unittest.TestCase):
    def test_puntaje_bajo_avisa_al_correo_del_formulario(self):
        a = alertas.evaluar(FakeCur(fila()), MALO)
        self.assertEqual(a["correo"], "jefe@empresa.com")
        self.assertEqual((a["pct"], a["llenado_por"]), (50, "Ana"))
        self.assertEqual(a["fallan"], ["P0", "P1"])

    def test_no_avisa_si_no_es_bajo(self):
        self.assertIsNone(alertas.evaluar(FakeCur(fila()), BUENO))
        self.assertIsNone(alertas.evaluar(FakeCur(fila()), LIMITE))
        # justo en el umbral (70 %) ya no es bajo
        ocho = [{"id": f"s{i}", "tipo": "si_no", "etiqueta": f"P{i}"} for i in range(10)]
        d = {f"s{i}": ("Sí" if i < 7 else "No") for i in range(10)}
        self.assertIsNone(alertas.evaluar(FakeCur(fila(campos=ocho)), {**MALO, "datos": d}))

    def test_sin_correo_o_correo_invalido_no_avisa(self):
        self.assertIsNone(alertas.evaluar(FakeCur(fila(correo="")), MALO))
        self.assertIsNone(alertas.evaluar(FakeCur(fila(correo=None)), MALO))
        self.assertIsNone(alertas.evaluar(FakeCur(fila(correo="no es correo")), MALO))

    def test_borrador_formulario_inexistente_o_sin_puntos(self):
        self.assertIsNone(alertas.evaluar(FakeCur(fila()), {**MALO, "estado": "borrador"}))
        self.assertIsNone(alertas.evaluar(FakeCur(None), MALO))
        self.assertIsNone(alertas.evaluar(FakeCur(fila()), {**MALO, "plantilla_id": None}))
        self.assertIsNone(alertas.evaluar(FakeCur(fila(campos=[{"id": "n", "tipo": "texto"}])), {**MALO, "datos": {"n": "x"}}))

    def test_un_error_de_base_no_se_propaga(self):
        class Rota(FakeCur):
            def execute(self, q, *a):
                if q.startswith("SELECT"):
                    raise RuntimeError("boom")
        self.assertIsNone(alertas.evaluar(Rota(fila()), MALO))


class PorFormulario(unittest.TestCase):
    """El umbral y el tope por hora se eligen por formulario."""
    def _eval(self, umbral, envio=None):
        f = fila(); f["aviso_umbral"] = umbral
        return alertas.evaluar(FakeCur(f), envio or LIMITE)      # LIMITE = 75 %

    def test_umbral_propio_cambia_cuando_avisa(self):
        self.assertIsNone(self._eval(None))            # predeterminado 70: 75 % no avisa
        self.assertIsNotNone(self._eval(80))           # con 80: 75 % sí avisa
        self.assertEqual(self._eval(80)["umbral"], 80)
        self.assertIsNone(self._eval(75))              # justo en el umbral no es «bajo»
        self.assertIsNotNone(self._eval(76))

    def test_cero_desactiva_los_avisos(self):
        self.assertIsNone(self._eval(0, MALO))         # 50 % pero el formulario no avisa

    def test_umbral_mas_estricto_deja_pasar_lo_que_antes_avisaba(self):
        self.assertIsNone(self._eval(40, MALO))        # 50 % con mínimo 40: cumple lo exigido
        self.assertIsNotNone(self._eval(None, MALO))

    def test_el_correo_dice_el_minimo_del_formulario(self):
        html = alertas._html([self._eval(80)])
        self.assertIn("mínimo 80 %", html)

    def test_publico_usa_umbral_y_tope_del_formulario(self):
        d = datos_pub(datos={"s0": "Sí", "s1": "Sí", "s2": "Sí", "s3": "No"}, aviso_umbral=80, aviso_max_hora=7)   # 75 %
        cur = PublicoCur(d)
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", "k"), \
             mock.patch.object(alertas.db, "sesion_privilegiada", sesion(cur)), \
             mock.patch("requests.post") as post:
            post.return_value.status_code = 200
            self.assertEqual(alertas.avisar_publico("e", "tok"), 1)
        self.assertEqual(cur.args_marcar[2], 7)           # el tope propio llega a la base

    def test_publico_sin_ajustes_usa_los_predeterminados(self):
        cur = PublicoCur(datos_pub())                     # sin aviso_umbral/aviso_max_hora (migración 008 sin correr)
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", "k"), \
             mock.patch.object(alertas.db, "sesion_privilegiada", sesion(cur)), \
             mock.patch("requests.post") as post:
            post.return_value.status_code = 200
            alertas.avisar_publico("e", "tok")
        self.assertEqual(cur.args_marcar[2], alertas.MAX_AVISOS_PUBLICOS_POR_HORA)

    def test_publico_cero_no_reserva_ni_envia(self):
        cur = PublicoCur(datos_pub(aviso_umbral=0))
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", "k"), \
             mock.patch.object(alertas.db, "sesion_privilegiada", sesion(cur)), \
             mock.patch("requests.post") as post:
            self.assertEqual(alertas.avisar_publico("e", "tok"), 0)
        post.assert_not_called()
        self.assertNotIn("skf_publico_aviso_marcar", cur.llamadas)


class Envio(unittest.TestCase):
    def _aviso(self, correo, pct=50, nombre="Lista SST"):
        return {"correo": correo, "formulario": nombre, "pct": pct, "ok": 1, "total": 2,
                "fallan": ["P0"], "llenado_por": "Ana <b>"}

    def test_un_correo_por_destinatario_aunque_haya_muchos_avisos(self):
        avisos = [self._aviso("a@x.com"), self._aviso("A@x.com", 40), self._aviso("b@x.com")]
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", "k"), \
             mock.patch("requests.post") as post:
            post.return_value.status_code = 200
            n = alertas.enviar(avisos)
        self.assertEqual(n, 2)
        self.assertEqual(post.call_count, 2)
        cuerpos = {c.kwargs["json"]["to"][0]: c.kwargs["json"] for c in post.call_args_list}
        self.assertIn("2 inspecciones", cuerpos["a@x.com"]["subject"])
        self.assertIn("(50 %)", cuerpos["b@x.com"]["subject"])

    def test_el_html_escapa_lo_que_escribe_el_usuario(self):
        html = alertas._html([self._aviso("a@x.com", nombre="<script>x</script>")])
        self.assertNotIn("<script>", html)
        self.assertNotIn("<b>", html.split("Ana")[1][:10])

    def test_sin_clave_no_envia_ni_falla(self):
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", ""), mock.patch("requests.post") as post:
            self.assertEqual(alertas.enviar([self._aviso("a@x.com")]), 0)
        post.assert_not_called()

    def test_un_fallo_de_red_no_se_propaga(self):
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", "k"), \
             mock.patch("requests.post", side_effect=OSError("sin red")):
            self.assertEqual(alertas.enviar([self._aviso("a@x.com")]), 0)

    def test_rechazo_del_proveedor_no_cuenta_como_enviado(self):
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", "k"), mock.patch("requests.post") as post:
            post.return_value.status_code = 403
            self.assertEqual(alertas.enviar([self._aviso("a@x.com")]), 0)


class PublicoCur:
    """Cursor falso que responde a las dos funciones de la migración 007."""
    def __init__(self, datos, enviar=True):
        self.datos, self.enviar, self.llamadas, self._ultima = datos, enviar, [], None

    def execute(self, q, args=None):
        self.llamadas.append(q.split("(")[0].replace("SELECT * FROM ", "").replace("SELECT ", "").strip())
        self._ultima = q
        if "skf_publico_aviso_marcar" in q:
            self.args_marcar = args

    def fetchone(self):
        if "skf_publico_aviso_marcar" in self._ultima:
            return {"enviar": self.enviar}
        return self.datos


def sesion(cur):
    import contextlib

    @contextlib.contextmanager
    def _s(*a, **k):
        yield cur
    return _s


def datos_pub(**k):
    base = {"formulario": "Lista SST", "campos": SI, "correo": "jefe@empresa.com",
            "datos": {"s0": "No", "s1": "No", "s2": "Sí", "s3": "Sí"}, "llenado_por": "Visitante", "ya_avisado": False}
    base.update(k)
    return base


class Publico(unittest.TestCase):
    def _correr(self, cur, key="k"):
        with mock.patch.object(alertas.Config, "RESEND_API_KEY", key), \
             mock.patch.object(alertas.db, "sesion_privilegiada", sesion(cur)), \
             mock.patch("requests.post") as post:
            post.return_value.status_code = 200
            return alertas.avisar_publico("e", "tok"), post

    def test_puntaje_bajo_avisa_y_dice_que_es_publico(self):
        n, post = self._correr(PublicoCur(datos_pub()))
        self.assertEqual(n, 1)
        self.assertIn("formulario público", post.call_args.kwargs["json"]["html"])

    def test_no_avisa_si_cumple_ya_se_aviso_o_no_hay_correo(self):
        for d in (datos_pub(datos={"s0": "Sí", "s1": "Sí", "s2": "Sí", "s3": "Sí"}),
                  datos_pub(ya_avisado=True), datos_pub(correo=""), datos_pub(correo="x"), None):
            n, post = self._correr(PublicoCur(d))
            self.assertEqual(n, 0)
            post.assert_not_called()

    def test_no_reserva_cupo_si_el_puntaje_no_es_bajo(self):
        # Un envío bueno no debe gastar el límite por hora del formulario.
        cur = PublicoCur(datos_pub(datos={"s0": "Sí", "s1": "Sí", "s2": "Sí", "s3": "Sí"}))
        self._correr(cur)
        self.assertNotIn("skf_publico_aviso_marcar", cur.llamadas)

    def test_si_la_base_dice_que_no_se_envia_no_sale_correo(self):
        n, post = self._correr(PublicoCur(datos_pub(), enviar=False))
        self.assertEqual(n, 0)
        post.assert_not_called()

    def test_migracion_sin_correr_no_rompe_el_envio(self):
        class Rota(PublicoCur):
            def execute(self, q, args=None):
                raise RuntimeError("function skf_publico_aviso_datos does not exist")
        n, post = self._correr(Rota(datos_pub()))
        self.assertEqual(n, 0)
        post.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=1)
