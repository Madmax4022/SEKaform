# SEKaform — Documento de Análisis Completo

## 1. QUÉ ES

SEKaform es una plataforma SaaS de digitalización inteligente de formularios para empresas latinoamericanas (foco inicial: Colombia). Su propuesta central: **tomar cualquier formulario existente en cualquier formato — papel físico, PDF, imagen JPG/PNG, página web o HTML — y convertirlo automáticamente en un formulario digital inteligente con automatización, base de datos y dashboard de inteligencia de negocios.**

No es un constructor de formularios desde cero. Es un **digitalizador con IA** que preserva los campos del formulario original y los enriquece con automatización.

---

## 2. FUNCIONES PRINCIPALES

### 2.1 Digitalizador (5 fuentes de entrada)

| Fuente | Cómo funciona |
|--------|---------------|
| 📸 Imagen / Scan | OCR con Tesseract.js v4 — fotografía de papel, captura de pantalla |
| 📄 PDF | PDF.js extrae texto; si es PDF escaneado (imagen), hace OCR sobre canvas |
| 🌐 URL web | CORS proxy fetcha la página, parsea campos HTML del formulario original |
| 🗂️ HTML paste | El usuario pega el código HTML de un formulario web existente |
| ✍️ Manual | Lista de nombres de campos, uno por línea |

### 2.2 Detección inteligente de tipos de campo (20+ patrones en español)

El sistema analiza cada etiqueta detectada y sugiere automáticamente el tipo más adecuado:

- **Fecha automática** (`fecha_auto`): campos que contienen "fecha", "date", "periodo", "vencimiento"
- **Hora automática** (`hora_auto`): "hora de inicio", "hora de finalización", "horario"
- **GPS / Ubicación** (`ubicacion`): "ubicación", "localización", "GPS", "coordenadas"
- **Firma digital** (`firma`): "firma", "rúbrica", "huella", "sello", "autoriza"
- **Sí / No / N/A** (`si_no`): "cumple", "aplica", "existe", "¿Completó?", "¿Asistió?", labels con "Sí / No"
- **Escala 1–5** (`radio`): "calificación", "puntaje", "evaluación", "nivel de servicio"
- **Desplegable** (`select`): ciudad, cargo, área, tipo de, género, jornada, escolaridad
- **Foto / evidencia** (`foto`): "fotografía", "evidencia", "imagen"
- **Texto largo** (`textarea`): observaciones, descripción, comentario, hallazgo
- **Número** (`numero`): NIT, cédula, cantidad, total, consecutivo
- **Email, teléfono, fecha manual**, etc.

### 2.3 Opciones pre-pobladas automáticamente

Cuando se detecta un campo de selección, el sistema sugiere opciones predefinidas contextuales:
- Cargo → desplegable con opciones de cargo típicas de empresa colombiana
- Género → Masculino / Femenino / Otro
- Tipo de mantenimiento → Correctivo / Preventivo / Predictivo / Instalación
- Escala 1-5 → "1 - Deficiente" a "5 - Excelente"
- Escala cualitativa → Deficiente / Regular / Bueno / Muy Bueno / Excelente
- Resultado de inspección → Conforme / No Conforme / Observación / N/A
- Turno → Mañana / Tarde / Noche / Mixto

### 2.4 Catálogo de 57 plantillas por vertical

El sistema compara los campos detectados contra un catálogo predefinido (`form-library.js`, compartido entre `digitalizador.html` y el índice navegable `plantillas.html`) y sugiere coincidencias con campos faltantes. Las plantillas están organizadas por vertical, siguiendo el orden de priorización de `ESTRATEGIA.md`:

- **SST (10)**: Registro de Asistencia a Capacitación, Lista de Verificación SST, Permiso de Trabajo, Reporte de Incidente/Accidente, Matriz de Peligros (GTC-45), Acta COPASST, Entrega de EPP, Investigación de Accidente de Trabajo (Res. 1401/2007), Inspección de Botiquín y Brigada, Examen Médico Ocupacional
- **Construcción (8)**: Control de Ingreso a Obra, Permiso de Trabajo en Alturas, Inspección de Andamios, Preoperacional de Maquinaria Pesada, Bitácora Diaria de Obra, Inspección de Seguridad en Obra, Acta de Entrega de Avance, Reporte de No Conformidad
- **Alimentos (8)**: Inspección Sanitaria/Higiene, Control de Temperatura HACCP, Limpieza y Desinfección, Control de Plagas (MIP), Recepción de Materia Prima, Trazabilidad de Lote, Capacitación en Manipulación de Alimentos, No Conformidad INVIMA
- **Salud — clínicas y laboratorios (8)**: Triage de Urgencias, Consentimiento Informado, Historia Clínica de Ingreso, Esterilización de Equipos, Manejo de Residuos Hospitalarios (PGIRASA), Control de Medicamentos de Control Especial, Lista de Verificación de Habilitación, Reporte de Evento Adverso
- **Inmuebles & Facilidades (14)**: Inspección de Cuarto Eléctrico y Tableros (NFPA 70E), Inspección de Extintores (NFPA 10), Sistema de Detección y Alarma de Incendio (NFPA 72), Chimeneas y Campanas de Cocina Industrial (NFPA 96), Bomba Contra Incendio (NFPA 20/25), Gabinetes y Mangueras Contra Incendio (NFPA 14), Sistema de Rociadores Automáticos (NFPA 13), Bomba de Agua / Sistema Hidroneumático, Planta Eléctrica de Emergencia, Inspección de Ascensores, Ronda de Vigilancia y Seguridad Física, Mantenimiento Preventivo de HVAC, Inspección de Tanques de Almacenamiento de Agua, Aseo y Limpieza de Áreas Comunes
- **General (9)**: Acta de Reunión, Orden de Trabajo/Servicio, Evaluación de Desempeño, Visita Comercial/CRM, Solicitud de Compra, Entrega/Recibo de Bienes, Hoja de Vida, Encuesta de Satisfacción, Registro de Calibración de Equipos

Próximo vertical en el roadmap: Transporte & Logística (Tier 2).

### 2.5 Control de calidad OCR

Para formularios digitalizados desde imagen/PDF, el sistema analiza cada etiqueta detectada y la clasifica:
- `ok`: etiqueta legible y coherente
- `review`: posiblemente ilegible (muestra ⚠️ con botones "✓ Aprobar" / "✏️ Editar")
- `garbage`: etiqueta descartada automáticamente

### 2.6 Wizard de 3 pasos

1. **Fuente** — seleccionar origen y subir/pegar el documento
2. **Campos** — revisar, ajustar tipos, agregar/eliminar campos, aprobar etiquetas ilegibles
3. **Vista previa** — ver el formulario exactamente como lo verá el usuario final, luego guardar

### 2.7 Llenar formularios (llenar.html)

- Interfaz tipo app móvil, dark mode
- Cada tipo de campo tiene tarjeta visual diferenciada con color de acento
- Fecha automática: muestra hoy en teal, solo lectura
- Hora automática: muestra la hora actual actualizándose en tiempo real
- GPS: botón que obtiene coordenadas y enlace a Google Maps
- Firma digital: canvas táctil + mouse, exporta como PNG
- Foto: cámara del dispositivo o galería
- Sí/No: botones tipo píldora (Sí / No / N/A)
- Escala radio: botones visuales seleccionables
- Progreso de llenado en barra superior
- Borrador automático

### 2.8 Compartir vía QR

Cada formulario puede compartirse vía código QR sin servidor. El template completo se codifica como JSON compactado en base64 dentro de la URL (`?shared=...`). Quien escanea el QR recibe el formulario completo en su dispositivo y puede llenarlo offline.

### 2.9 Base de datos e Inteligencia de Negocios (dashboard.html)

- KPIs: formularios creados, envíos totales, este mes, últimos 7 días
- Gráfico de línea: envíos por día (últimos 30 días) — Chart.js
- Gráfico de dona: distribución por formulario
- Tabla de registros con drill-down por fila
- Filtro por formulario
- Exportar CSV con BOM UTF-8 (compatible Excel/Google Sheets)
- Thumbnails de fotos inline

### 2.10 Sincronización Cloud (Supabase)

- Offline-first: localStorage como almacenamiento primario siempre
- Supabase como capa cloud no-bloqueante
- Merge inteligente: cloud + local, deduplicado por ID
- RLS (Row Level Security): cada usuario solo ve sus propios datos
- Login/registro vía email (login.html)

---

## 3. BENEFICIOS

### Para el negocio
- **Tiempo cero de implementación**: subir el formulario en papel y en 30 segundos está digitalizado
- **Sin rediseño**: preserva la estructura lógica del formulario existente
- **Cumplimiento normativo**: SST, ISO 9001, HACCP — todos los procesos de calidad ya documentados en papel se digitalizan directamente
- **Eliminación de reproceso**: no más "pasar de papel a Excel a mano"
- **Trazabilidad**: cada envío queda en base de datos con timestamp, usuario, ubicación GPS

### Para el usuario de campo
- **Sin entrenamiento**: el formulario digital luce igual al papel que ya conoce
- **Automatización invisible**: la fecha, hora y GPS se llenan solos — el inspector no tiene que escribirlos
- **Funciona offline**: puede llenar el formulario sin internet y sincroniza cuando hay señal
- **Firma desde el celular**: no necesita imprimir para firmar

### Técnicos / Diferenciales
- **Multi-formato real**: imagen, PDF escaneado (OCR), PDF digital, URL, HTML, manual
- **Sin backend propio**: Supabase como backend as a service
- **Costo de operación casi cero**: GitHub Pages (hosting gratis) + Supabase free tier
- **Sin app que instalar**: funciona en cualquier navegador móvil o de escritorio
- **Exportable**: CSV para cualquier herramienta de análisis

---

## 4. COMPETENCIA

### Competidores directos

| Plataforma | Origen | Fortaleza | Debilidad vs SEKaform |
|-----------|--------|-----------|----------------------|
| Google Forms | EEUU | Gratuito, familiar | No digitaliza formularios existentes, sin OCR, sin GPS auto, sin firma, sin BI nativo |
| Microsoft Forms + Power Automate | EEUU | Integración Office 365 | Requiere licencia M365, complejo de configurar, no digitaliza papel |
| JotForm | EEUU | Constructor potente | Sin digitalización desde papel/imagen, precio en USD, no enfocado en LATAM |
| Typeform | España/EEUU | UX premium | Precio alto, sin OCR, sin GPS, orientado a encuestas no a operaciones |
| KoBoToolbox | ONG | Offline, campo | Curva de aprendizaje alta, sin digitalización inteligente, UI anticuada |
| 123FormBuilder | Rumanía | Precio bajo | Sin OCR/PDF, sin automatización de campos |
| Fulcrum | EEUU | Inspecciones campo | Precio enterprise, sin digitalización de formularios existentes |
| Device Magic | EEUU | Móvil campo | Precio alto, no digitaliza papel existente |

### Competidores indirectos

- **Adobe Acrobat Forms**: digitaliza PDFs pero no sugiere tipos, no tiene BI, no comparte vía QR, requiere licencia cara
- **Excel con macros**: lo que hace la mayoría de empresas colombianas hoy — sin GPS, sin firma, sin BI automático
- **WhatsApp / papel**: el 70% del mercado objetivo sigue aquí

### Ventaja competitiva clave

Ninguna plataforma existente combina: **OCR de papel → sugerencia de tipos inteligente → formulario móvil con automatización (GPS, fecha, firma) → base de datos → BI** en un flujo de menos de 2 minutos.

---

## 5. MERCADO

### Mercado objetivo primario (Colombia)

**Sectores con mayor densidad de formularios en papel:**
- Salud y Seguridad en el Trabajo (SST): obligatorio por Ley 1562/2012 — toda empresa debe llevar registros de inspecciones, capacitaciones, incidentes
- Construcción e infraestructura: órdenes de trabajo, entregas, permisos
- Alimentos y restaurantes: registros sanitarios INVIMA, listas de chequeo temperatura
- Logística y transporte: manifiestos, guías, entregas
- Mantenimiento industrial: órdenes de trabajo preventivo/correctivo
- Sector público / inspecciones: visitas de campo, actas

**Tamaño estimado:**
- Colombia: ~500,000 empresas formales con obligación SST
- ~1,200,000 mipymes con procesos documentados en papel
- Penetración digital de formularios en mipymes: <15%

**Cliente ideal (ICP):**
- Empresa de 20–500 empleados
- Tiene inspector, supervisor o coordinador de calidad/SST
- Usa actualmente Excel o papel para registros
- Tiene acceso a smartphone en campo
- Paga COP 50,000–300,000/mes por herramientas de gestión

### Mercado objetivo secundario
- Ecuador, Perú, México: mismo perfil normativo similar (Ley SST análoga)
- Empresas colombianas con operaciones regionales

### TAM / SAM / SOM (estimado)

- **TAM**: Mercado global de form builders — USD 6.2B (2024)
- **SAM**: LATAM mipymes con necesidad de digitalización de campo — USD 180M
- **SOM** (3 años): 2,000 empresas × USD 50/mes = USD 1.2M ARR

---

## 6. COMERCIALIZACIÓN

### Modelo de precios (sugerido)

| Plan | Precio | Incluye |
|------|--------|---------|
| Free | COP 0 | 3 formularios, 100 envíos/mes, 1 usuario |
| Starter | COP 79,000/mes | 10 formularios, 1,000 envíos/mes, 3 usuarios, exportar CSV |
| Pro | COP 199,000/mes | Ilimitado, usuarios ilimitados, BI avanzado, soporte prioritario |
| Enterprise | Negociado | On-premise, integración ERP, capacitación, SLA |

### Estrategia de adquisición

**Canal 1 — Consultores SST (canal indirecto de mayor palanca)**
- Colombia tiene ~15,000 profesionales SST certificados (SGSST)
- Cada consultor atiende 5–30 empresas cliente
- Propuesta: comisión 20% del primer año por empresa referida
- El consultor usa SEKaform para digitalizar los formatos del cliente como parte de su servicio de implementación del SG-SST

**Canal 2 — Contenido orgánico (SEO + LinkedIn)**
- Publicar artículos: "Cómo digitalizar tu matriz de peligros", "Formato de inspección SST digital gratis"
- YouTube: demos de digitalización de formularios en 60 segundos
- LinkedIn: enfoque en coordinadores HSE, gerentes de operaciones

**Canal 3 — Producto freemium con viral loop**
- QR de formulario gratis → el destinatario ve "Formulario creado con SEKaform" → conversión
- Shared templates: formularios públicos de la biblioteca que atrapan búsquedas orgánicas

**Canal 4 — Alianzas con gremios**
- ACOPI (Asociación Colombiana de Pequeñas Industrias)
- Fenalco (Federación Nacional de Comerciantes)
- Cámaras de Comercio regionales

### Métricas clave (KPIs de negocio)

- **CAC** (Costo de Adquisición por Cliente): target < COP 150,000
- **LTV** (Valor de Vida del Cliente): COP 800,000 promedio (12 meses plan Starter)
- **LTV/CAC**: target > 5x
- **Churn mensual**: target < 5%
- **Activación**: % de cuentas que crean ≥1 formulario en primeras 48h
- **NPS**: target > 40

### Roadmap de comercialización

**Mes 1–3 (MVP + validación)**
- 10 clientes piloto gratuitos en sector SST
- Iterar en base a feedback de uso real
- Documentar casos de éxito

**Mes 4–6 (early revenue)**
- Lanzar plan Starter con cobro
- Primer canal de consultores SST
- Landing page con demo video

**Mes 7–12 (crecimiento)**
- Integración con sistemas de nómina/ERP colombianos (Siigo, World Office, Helisa)
- App móvil PWA (Progressive Web App) — instalar en pantalla inicio
- Módulo de firma electrónica con validez legal (Ley 527/1999 Colombia)

---

## 7. STACK TÉCNICO ACTUAL

- **Frontend**: HTML5 / CSS3 / JS vanilla (sin frameworks, carga instantánea)
- **OCR**: Tesseract.js v4 (lazy-loaded, sin costo de servidor)
- **PDF**: PDF.js v3.11.174 + canvas OCR fallback
- **Backend**: Supabase (PostgreSQL + PostgREST + Auth + RLS)
- **Hosting**: GitHub Pages (costo cero)
- **Charts**: Chart.js v4.4.6 (bundled)
- **QR**: api.qrserver.com (externo, gratuito)
- **CORS proxy**: allorigins.win + corsproxy.io (para tab URL)

**Costo de operación actual: ~USD 0/mes** (free tiers)  
**Costo proyectado a 1,000 usuarios activos: ~USD 25/mes** (Supabase Pro)

---

*Documento generado: 16 junio 2026 — SEKaform v1.0*
