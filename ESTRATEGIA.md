# SEKaform — Estrategia: De Producto Genérico a Plataforma Vertical

## ESTRATEGIA: DE PRODUCTO GENÉRICO A PLATAFORMA VERTICAL

**Hoy:** SEKaform = digitalizador genérico de cualquier formulario.

**Mañana:** SEKaform = **marketplace de templates verticales** donde cada repositorio es un mini-SaaS dentro de la plataforma.

### Por qué funciona:

1. **Penetración más rápida:** En lugar de vender "un digitalizador", vendes "tu solución SST regulatoria lista en 60 segundos"
2. **Cumplimiento automático:** El formulario ya tiene los campos que la ley exige (Ley 1562 SST, INVIMA, ISO 9001, etc.)
3. **PLG (Product-Led Growth):** El usuario entra buscando "formulario de inspección sanitaria" y descubre que puede digitalizar cualquier cosa
4. **Defensible:** Cada repositorio vertical es expertise + templates = barrera de entrada para competidores
5. **Monetización multi-capa:** Free templates + pro templates + integración vertical + consultoría

---

## REPOSITORIOS VERTICALES PROPUESTOS

### TIER 1 — Lanzamiento inmediato (ROI máximo, 3 meses)

| Vertical | TAM colombiano | Regulación driver | ARPU | Prioridad |
|----------|---|---|---|---|
| **🏥 Salud Ocupacional (SST)** | 500k empresas | Ley 1562/2012 | USD 400/año | **1** |
| **🏗️ Construcción** | 80k empresas | RUC + seguridad obra | USD 350/año | **2** |
| **🍔 Alimentos & Restaurantes** | 120k empresas | INVIMA + HACCP | USD 300/año | **3** |
| **🚑 Salud (Clínicas/Laboratorios)** | 25k establecimientos | Resolución 2674/2013 | USD 500/año | **4** |

**Ingresos potenciales año 1 (solo tier 1):** 500 clientes × USD 337 promedio = **USD 168,500**

---

### TIER 2 — 6–12 meses

| Vertical | TAM colombiano | Regulación | ARPU | Contexto |
|----------|---|---|---|---|
| **🚗 Transporte & Logística** | 85k empresas | RUNT + inspección vehicular | USD 380/año | Manifiestos, entregas, mantenimiento |
| **🏫 Educación (Colegios)** | 40k instituciones | MEN + evaluaciones | USD 250/año | Asistencia, evaluaciones, reportes padres |
| **🎓 Educación Superior** | 300 instituciones | MEN + acreditación | USD 600/año | Evaluación docente, investigación, seguimiento egresados |
| **⚙️ Manufactura & Mantenimiento** | 60k empresas | ISO 9001 + preventivo | USD 450/año | Órdenes de trabajo, checklists mantenimiento |
| **🏢 Inmuebles & Facilidades** | 50k propiedades | Seguridad + mantenimiento | USD 320/año | Inspecciones, mantenimiento preventivo |

---

### TIER 3 — 12–18 meses (expansión regional)

| Vertical | Notas |
|----------|-------|
| **📱 Telecom/ISP** | Órdenes de instalación, visitas técnicas |
| **💳 Finanzas & Seguros** | Compliance, auditoría, solicitudes de crédito |
| **🌾 Agricultura** | Inspección de cultivos, trazabilidad |
| **✈️ Aeronáutica** | Checklists pre-vuelo, mantenimiento |
| **👮 Policía & Justicia** | Partes, denuncias, investigación |

---

## ESTRUCTURA DE CADA REPOSITORIO VERTICAL

### Ejemplo: SEKaform SST (Salud Ocupacional)

```
sekaform.com/sst/
├── landing page (SEO: "formularios SST digital", "SG-SST colombiano")
├── templates públicos (gratis)
│   ├── Matriz de peligros (Ley 1562)
│   ├── Acta de reunión COPASOS
│   ├── Reporte de incidente
│   ├── Inspección de áreas
│   ├── Registro capacitación SST
│   └── Evaluación desempeño coordinador SST
├── templates pro (plan SST Pro: USD 39/mes)
│   ├── Todo lo anterior
│   ├── Integración con plataforma de riesgos (KANAN Sentinel)
│   ├── Dashboard KPI SST (tasa incidencia, cumplimiento inspecciones)
│   ├── Alertas: vencimiento de capacitaciones, revisión anual SG-SST
│   └── Reportes automáticos para auditoría
├── canal: Consultores SST (comisión 25% primer año)
└── moat: Cada template contiene:
    ├── Campos precisos según ley colombiana
    ├── Validaciones automáticas
    ├── Opciones prerellenadas (cargos típicos, tipos de peligro, etc.)
    └── Instrucciones incrustadas
```

### Ejemplo: SEKaform Alimentos (INVIMA)

```
sekaform.com/alimentos/
├── landing: "Lista de chequeo INVIMA en 60 segundos"
├── templates públicos (gratis)
│   ├── Inspección temperatura diaria (HACCP)
│   ├── Limpieza y sanitización
│   ├── Calibración de equipos
│   ├── Control de plagas
│   └── Trazabilidad de ingredientes
├── templates pro (plan Alimentos Pro: USD 35/mes)
│   ├── Integración INVIMA reporting
│   ├── Dashboard de no-conformidades
│   ├── Evidencia de foto (timestamps + GPS)
│   └── Exportar para auditoría INVIMA
├── canal: Auditores INVIMA, consultores calidad
└── integración: Pull data desde SIAUPA (INVIMA)
```

---

## MODELO DE NEGOCIO — CAPAS

### Capa 1: Freemium por vertical
- 3 templates públicos por repositorio
- 100 envíos/mes
- No BI, solo CSV export
- **Objetivo:** Virality, SEO, conversión a pagos

### Capa 2: Plan vertical especializado
- Nombre: "SEKaform [SST|Alimentos|Construcción] Pro"
- Precio: USD 35–60/mes (según TAM del vertical)
- Incluye:
  - Todos los templates del repositorio
  - BI nativo para KPIs del vertical
  - Integraciones específicas (INVIMA, SIAUPA, etc.)
  - Soporte por email
  - 3 usuarios

### Capa 3: Plan Platform (todos los verticales)
- Nombre: "SEKaform Enterprise"
- Precio: USD 150/mes
- Incluye: Todos los verticales + usuarios ilimitados + API + SSO + SLA

### Capa 4: Integraciones + Consultoría
- KANAN Sentinel para SST
- ERP colombianos (Siigo, World Office, Helisa)
- Power BI / Tableau reporting
- **Margen:** 40–60% en servicios profesionales

---

## ROADMAP ACELERADO

| Mes | Hito | Verticales | Métricas |
|-----|------|-----------|----------|
| **M1–2** | MVP SEKaform genérico + SST | 1 (SST) | 50 clientes, USD 12k MRR |
| **M3–4** | Lanzar Alimentos + Construcción | 3 | 250 clientes, USD 45k MRR |
| **M5–6** | Lanzar Salud + Manufactura | 5 | 800 clientes, USD 120k MRR |
| **M7–12** | Tier 2 (Transporte, Educación) | 10 | 2,500 clientes, USD 450k MRR |
| **Año 2** | Tier 3 + API + integraciones | 15+ | 8,000 clientes, USD 1.8M MRR |

---

## GO-TO-MARKET POR VERTICAL

### SST (Salud Ocupacional) — Canal de consultores
- Partner: 15,000 consultores SGSST certificados
- Propuesta: "Vende nuestro SaaS, gana 25% comisión"
- Landing: `sekaform.com/sst/consultor` (partner portal)
- Plazo: Día 1

### Alimentos — Canal regulatorio
- Partner: Auditores INVIMA, laboratorios de análisis
- Propuesta: "Tu cliente pasa inspección INVIMA más rápido"
- Integración: Pull automático de resultados SIAUPA
- Plazo: M3

### Construcción — Integradores + gremios
- Partner: ANDI, Cámara de Comercio
- Propuesta: "Template de RUC + inspecciones de obra"
- Landing: Demo video de digitalización en obra (60 seg)
- Plazo: M4

### Educación — Direct sales a instituciones
- Pitch: "Evaluaciones digitales + trazabilidad MEN"
- Freemium hook: "Prueba gratis con 200 estudiantes"
- ARPU: USD 250–600/año (según tamaño institución)
- Plazo: M6

### Salud — Direct + consultoras de calidad
- Pitch: "Cumple Resolución 2674/2013 automáticamente"
- Integración: Sincroniza con Historia Clínica Electrónica (HCE)
- ARPU: USD 500+/año
- Plazo: M4

---

## VENTAJA COMPETITIVA POR VERTICAL

| Vertical | Moat |
|----------|------|
| **SST** | Ley 1562 + templates de matriz de peligros + integración KANAN Sentinel |
| **Alimentos** | INVIMA compliance + trazabilidad GPS + caducidad automática |
| **Construcción** | RUC formulario + checklist seguridad obra + fotos geolocalizadas |
| **Salud** | Resolución 2674 + HCE integration + evidencia foto con timestamp |
| **Educación** | Seguimiento MEN + evaluación docente + reportes para padres |

---

## PROYECCIÓN DE INGRESOS — MULTI-VERTICAL

| Vertical | Clientes Y1 | ARPU | Ingreso Y1 |
|----------|---------|------|-----------|
| SST | 300 | USD 360 | USD 108,000 |
| Alimentos | 150 | USD 300 | USD 45,000 |
| Construcción | 100 | USD 320 | USD 32,000 |
| Salud | 50 | USD 480 | USD 24,000 |
| **TOTAL Y1** | **600** | **USD 360** | **USD 209,000** |

| Vertical | Clientes Y2 | ARPU | Ingreso Y2 |
|----------|---------|------|-----------|
| SST | 1,200 | USD 360 | USD 432,000 |
| Alimentos | 600 | USD 300 | USD 180,000 |
| Construcción | 400 | USD 320 | USD 128,000 |
| Salud | 200 | USD 480 | USD 96,000 |
| Educación | 300 | USD 250 | USD 75,000 |
| Manufactura | 200 | USD 400 | USD 80,000 |
| **TOTAL Y2** | **2,900** | **USD 350** | **USD 991,000** |

**Año 3 (con Tier 3 + integraciones):** **USD 3.2M ARR**

---

## 3 COSAS QUE HACER AHORA

### 1. Validar demanda por vertical
- 10 conversaciones con coordinadores SST (LinkedIn + ACOPI)
- 5 conversaciones con auditores INVIMA
- 3 conversaciones con gerentes de construcción
- **Pregunta clave:** "¿Qué formulario digitalizarías primero?"
- **Métrica:** Si >60% dice SST, lanzar SST primero

### 2. Priorizar el repositorio SST
- Es el vertical con mayor TAM + regulación + canal claro
- Conectar directamente con KANAN Sentinel (matriz de peligros)
- El consultor SST ya conoce KANAN
- **Entrada:** "Integración KANAN Sentinel + templates SST"

### 3. Documentar templates por vertical
- Para SST: lista exacta de formularios que exige Ley 1562
- Para Alimentos: checklist INVIMA vs HACCP vs ISO 22000
- Para Construcción: RUC + inspecciones de seguridad + entregas
- **Entrega:** 50+ campos por vertical, mapeados a ley

---

## DECISIÓN DE MODELO

**Opción elegida: A — SaaS vertical dentro de sekaform.com**

Verticales como secciones de la misma plataforma, con landing pages dedicadas por vertical pero marca unificada SEKaform. Es la opción que escala más rápido sin fragmentar brand ni duplicar operación.

Estructura URL:
- `sekaform.com/sst/` — vertical SST
- `sekaform.com/alimentos/` — vertical Alimentos
- `sekaform.com/construccion/` — vertical Construcción

Cada vertical tiene:
- Landing page propia (SEO independiente)
- Templates preinstalados al registrarse
- Pricing diferenciado
- Canal de adquisición propio

---

*Documento estratégico — 16 junio 2026*
