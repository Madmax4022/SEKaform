"""Catálogo del control de trabajos: qué se exige para dejar trabajar.

Es «la partitura»: por cada tipo de trabajo, su criticidad y la lista de
requisitos que el comité del edificio debe ver cumplidos antes de autorizar.
Vive en el servidor y no en el navegador para que nadie pueda autorizar contra
una lista más corta que la oficial.

La criticidad la decide el riesgo del trabajo, no quién lo hace: el empleado de
un local que se sube a cambiar luminarias es tan crítico como un contratista
con andamio.

Las normas citadas son la REFERENCIA de cada requisito, no un dictamen legal:
la lista final de cada empresa la aprueba su profesional de salud ocupacional.
"""

from __future__ import annotations

from typing import Any

ORIGENES = {
    "propio": "Personal propio",
    "contratista": "Contratista nuestro",
    "contratista_local": "Contratista del local",
    "personal_local": "Personal del local",
}

# Quién firma como responsable junto a quien ejecuta, según el origen.
RESPONSABLES = {
    "propio": "Supervisor del equipo",
    "contratista": "Responsable del contratista",
    "contratista_local": "Arrendatario del local",
    "personal_local": "Arrendatario del local",
}

_SEGURO = ("seguro", "Seguro o afiliación a riesgos vigente", "Reglas del edificio", "doc", False)


def _grupo(nombre: str, *items: tuple) -> dict[str, Any]:
    return {"nombre": nombre,
            "items": [{"id": i, "texto": t, "norma": n, "evidencia": e, "critico": c} for i, t, n, e, c in items]}


TIPOS: dict[str, dict[str, Any]] = {
    "alturas": {
        "nombre": "Trabajo en alturas", "criticidad": "critico",
        "ejemplo": "Escaleras, andamios, mezanines, techos, cambio de luminarias",
        "base": "Res. 4272 de 2021 (Colombia) · OSHA 1926 subpartes L, M y X",
        "grupos": [
            _grupo("Personas",
                   ("apto", "Trabajador apto y con capacitación en alturas vigente", "Res. 4272 art. 9", "doc", True),
                   ("seguro", "Seguro o afiliación a riesgos vigente", "Res. 4272 art. 15", "doc", False)),
            _grupo("Equipo",
                   ("acceso", "Escalera o andamio inspeccionado antes de usar", "Res. 4272 arts. 17 y 18 · OSHA 1926.1053", "foto", True),
                   ("anclaje", "Arnés, eslinga y punto de anclaje verificados (desde 1.8 m)", "Res. 4272 art. 15 · OSHA 1926.502", "foto", True)),
            _grupo("Entorno",
                   ("electrico", "Distancia segura a líneas o equipos energizados", "Res. 4272 art. 15", "foto", True),
                   ("zona", "Zona de abajo delimitada contra caída de objetos", "Res. 4272 art. 25", "foto", False)),
            _grupo("Emergencia",
                   ("rescate", "Plan de rescate y persona de apoyo en el sitio", "Res. 4272 art. 26", "firma", True)),
        ],
    },
    "caliente": {
        "nombre": "Trabajo en caliente", "criticidad": "critico",
        "ejemplo": "Soldadura, corte con disco o soplete, esmerilado",
        "base": "NFPA 51B · OSHA 1910.252",
        "grupos": [
            _grupo("Entorno",
                   ("despeje", "Combustibles retirados o protegidos en 11 m a la redonda", "NFPA 51B · OSHA 1910.252(a)", "foto", True),
                   ("aberturas", "Aberturas de piso y pared cubiertas", "OSHA 1910.252(a)", "foto", False),
                   ("rociadores", "Rociadores y alarma en servicio en la zona", "NFPA 51B", "doc", True)),
            _grupo("Equipo",
                   ("extintor", "Extintor cargado al alcance de la mano", "OSHA 1910.252(a)", "foto", True),
                   ("equipo", "Equipo de soldadura o corte en buen estado", "NFPA 51B", "foto", False)),
            _grupo("Personas",
                   ("vigia", "Vigía de incendio durante el trabajo y hasta 60 min después", "NFPA 51B", "firma", True),
                   _SEGURO),
        ],
    },
    "electrico": {
        "nombre": "Trabajo eléctrico", "criticidad": "critico",
        "ejemplo": "Tableros, acometidas, aires acondicionados, equipos con energía",
        "base": "NFPA 70E art. 120 · OSHA 1910.147 y 1910.333",
        "grupos": [
            _grupo("Energía",
                   ("desenergizado", "Circuito identificado y desenergizado", "NFPA 70E art. 120", "foto", True),
                   ("bloqueo", "Candado y etiqueta puestos por quien trabaja", "OSHA 1910.147", "foto", True),
                   ("tension", "Ausencia de tensión comprobada con instrumento", "NFPA 70E art. 120", "foto", True)),
            _grupo("Personas",
                   ("calificado", "Persona calificada para trabajo eléctrico", "NFPA 70E art. 110", "doc", True),
                   _SEGURO),
            _grupo("Entorno",
                   ("area", "Área delimitada y equipo de protección dieléctrico", "NFPA 70E art. 130", "foto", False)),
        ],
    },
    "incendio": {
        "nombre": "Intervención de sistema contra incendio", "criticidad": "critico",
        "ejemplo": "Rociadores, alarma, detectores, bombas, gabinetes",
        "base": "NFPA 25 cap. 15 (sistemas fuera de servicio)",
        "grupos": [
            _grupo("Control",
                   ("responsable", "Responsable de la interrupción nombrado", "NFPA 25 cap. 15", "firma", True),
                   ("zona", "Zona y duración definidas, con etiqueta colocada", "NFPA 25 cap. 15", "foto", True),
                   ("aviso", "Aviso a bomberos, aseguradora y central de alarmas", "NFPA 25 cap. 15", "doc", False)),
            _grupo("Compensación",
                   ("vigilancia", "Vigilancia de incendio si supera 10 h en un día", "NFPA 25 cap. 15", "firma", True),
                   ("sin_caliente", "Sin trabajos en caliente en la zona afectada", "NFPA 25 cap. 15", "firma", True)),
            _grupo("Cierre",
                   ("prueba", "Prueba de restablecimiento prevista al terminar", "NFPA 25 cap. 15", "doc", False),
                   _SEGURO),
        ],
    },
    "general": {
        "nombre": "Adecuación o mantenimiento general", "criticidad": "medio",
        "ejemplo": "Tablayeso a nivel de piso, pintura, herramienta eléctrica, montaje",
        "base": "Reglas del edificio",
        "grupos": [
            _grupo("Solicitud",
                   ("alcance", "Qué se hará, horario y responsable definidos", "Reglas del edificio", "doc", False),
                   ("reglas", "Reglas del edificio aceptadas", "Reglas del edificio", "firma", False)),
            _grupo("Entorno",
                   ("senal", "Área de trabajo señalizada", "Reglas del edificio", "foto", False),
                   _SEGURO),
        ],
    },
    "rutinario": {
        "nombre": "Trabajo rutinario de bajo riesgo", "criticidad": "bajo",
        "ejemplo": "Limpieza habitual, decoración a nivel de piso, entregas",
        "base": "Reglas del edificio",
        "grupos": [
            _grupo("Solicitud",
                   ("alcance", "Qué se hará y en qué horario", "Reglas del edificio", "doc", False),
                   ("reglas", "Reglas del edificio aceptadas", "Reglas del edificio", "firma", False)),
        ],
    },
}


def requisitos_de(tipo: str) -> list[dict[str, Any]]:
    return [i for g in TIPOS[tipo]["grupos"] for i in g["items"]]


def ids_requisitos(tipo: str) -> list[str]:
    return [i["id"] for i in requisitos_de(tipo)]


def faltantes(tipo: str, cumplidos: Any) -> list[str]:
    """Textos de los requisitos que aún no están marcados como cumplidos."""
    c = cumplidos if isinstance(cumplidos, dict) else {}
    return [i["texto"] for i in requisitos_de(tipo) if c.get(i["id"]) is not True]


def catalogo() -> dict[str, Any]:
    """Lo que el navegador necesita para pintar formularios y listas."""
    return {"tipos": [{"id": k, **v} for k, v in TIPOS.items()],
            "origenes": ORIGENES, "responsables": RESPONSABLES}
