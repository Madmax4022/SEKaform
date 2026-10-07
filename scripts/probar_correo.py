#!/usr/bin/env python3
"""Prueba del correo de «cumplimiento bajo» con el MISMO texto y remitente que usa la app.

Uso (desde la raíz del proyecto, con la misma clave que usa Cloud Run):

    RESEND_API_KEY=re_xxxxx python3 scripts/probar_correo.py tu@correo.com
    RESEND_API_KEY=re_xxxxx SKF_URL_PUBLICA=https://sekaform.kanansentinel.com \\
        python3 scripts/probar_correo.py tu@correo.com

Sin la clave (o con --simulacro) no envía nada: solo muestra qué enviaría.
A diferencia de la app —que registra un fallo y sigue—, aquí se imprime la respuesta COMPLETA
de Resend para saber por qué no llegó (dominio sin verificar, clave inválida, etc.).
Solo manda UN correo, al destinatario que indiques, con datos de ejemplo.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app import alertas                      # noqa: E402
from app.config import Config                # noqa: E402

DIAGNOSTICO = {
    401: "La clave no es válida o falta. Revisa RESEND_API_KEY (debe empezar por «re_»).",
    403: "Resend rechazó el envío. Casi siempre: el dominio del remitente no está verificado en Resend, "
         "o la clave es de solo lectura. Remitente usado: {remitente}",
    422: "Resend no aceptó el contenido: revisa el remitente ({remitente}) y el destinatario.",
    429: "Límite de envíos de Resend alcanzado. Espera un momento y reintenta.",
}


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    simulacro = "--simulacro" in argv
    if len(args) != 1 or not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", args[0]):
        print(__doc__)
        return 2
    destino = args[0]

    aviso = {"umbral": 70, "correo": destino, "formulario": "Prueba — Lista de Verificación SST",
             "pct": 50, "ok": 2, "total": 4, "fallan": ["Extintores vigentes", "Salidas despejadas"],
             "llenado_por": "Prueba de correo"}
    asunto = f"⚠️ [PRUEBA] Inspección con cumplimiento bajo ({aviso['pct']} %) — {aviso['formulario']}"
    print(f"Remitente : {Config.CORREO_REMITENTE}")
    print(f"Destino   : {destino}")
    print(f"Asunto    : {asunto}")
    print(f"Botón al Panel: {'sí (' + Config.URL_PUBLICA + ')' if Config.URL_PUBLICA else 'NO — falta SKF_URL_PUBLICA'}")

    if simulacro or not Config.RESEND_API_KEY:
        print("\nNo se envió nada:", "modo --simulacro." if simulacro else
              "no hay RESEND_API_KEY en el entorno. Ejecútalo con la clave de Cloud Run.")
        return 0 if simulacro else 1

    import requests
    try:
        r = requests.post(
            "https://api.resend.com/emails",
            headers={"Authorization": f"Bearer {Config.RESEND_API_KEY}", "Content-Type": "application/json"},
            json={"from": Config.CORREO_REMITENTE, "to": [destino], "subject": asunto, "html": alertas._html([aviso])},
            timeout=15,
        )
    except requests.RequestException as e:
        print(f"\n✗ No se pudo contactar a api.resend.com ({type(e).__name__}). Revisa tu conexión "
              "o el proxy de salida; el correo no se envió.")
        return 1
    print(f"\nRespuesta de Resend: HTTP {r.status_code}\n{r.text}")
    if r.status_code < 300:
        print("\n✓ Resend aceptó el correo. Revisa tu bandeja (y la carpeta de spam) en 1–2 minutos.")
        return 0
    print("\n✗", DIAGNOSTICO.get(r.status_code, "Error no previsto: revisa la respuesta de arriba.")
          .format(remitente=Config.CORREO_REMITENTE))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
