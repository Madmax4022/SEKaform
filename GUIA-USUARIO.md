# Guía de uso — SEKaform

SEKaform digitaliza formularios en papel, PDF, imagen o página web, y los convierte en formularios digitales listos para llenar — ya sea por ti mismo o por tu equipo. Una misma cuenta sirve a la vez como **repositorio personal** (tus propios formularios y su analítica) y como **panel de administrador** (asignar formularios a tu equipo y hacer seguimiento de quién los llenó).

No hay un "modo administrador" separado: cualquier cuenta puede digitalizar, llenar formularios para sí misma, *y* asignarlos a otras personas — todo desde el mismo menú.

---

## 1. Primeros pasos

1. Entra a la app (`index.html`). Si conectaste Supabase (ver `supabase-config.js`), puedes crear una cuenta o iniciar sesión desde **Iniciar sesión ☁** en la esquina superior derecha — esto sincroniza tus formularios y envíos en la nube, entre dispositivos y con tu equipo.
2. Sin cuenta, la app funciona igual pero los datos quedan **solo en este dispositivo** (verás un aviso "💾 Datos locales" en el Dashboard y en Asignaciones recordándotelo).
3. El menú superior tiene cinco secciones: **Plantillas · Digitalizar · Mis formularios · Asignaciones · Dashboard**.

---

## 2. Digitalizar un documento (`Digitalizar`)

El digitalizador convierte cualquier formulario existente en una plantilla digital, en 3 pasos:

**Paso 1 — Fuente.** Elige el origen del documento:
- 📸 **Imagen / Scan** — sube una foto o escaneo del formulario en papel.
- 🌐 **URL web** — pega el link de una página que contenga el formulario.
- 📄 **PDF** — sube un PDF (con texto o escaneado).
- ✍️ **Manual** — pega o escribe el texto del formulario directamente.
- 🗂️ **HTML** — pega el código HTML de un formulario existente.

Haz clic en **⚡ Analizar y digitalizar →**.

**Paso 2 — Campos.** El sistema detecta automáticamente cada campo del documento y sugiere el tipo más adecuado (texto, número, fecha automática, hora automática, ubicación GPS, firma, selección única/múltiple, etc.). Revisa la lista, ajusta lo que haga falta y ponle un nombre al formulario.

**Paso 3 — Vista previa.** Verás cómo quedará el formulario terminado. Desde aquí:
- **💾 Guardar plantilla** — la agrega a tu catálogo en "Mis formularios".
- **Ir a llenar →** — te lleva directo a llenarlo.

> 💡 Si no quieres digitalizar nada propio, puedes partir de una plantilla ya lista — ver siguiente sección.

---

## 3. Catálogo de plantillas (`Plantillas`)

Repositorio de plantillas preconfiguradas por sector (SST, Construcción, Alimentos, Salud, Inmuebles, y generales), alineadas con normativa colombiana (Ley 1562/2012, Decreto 1072/2015, Res. 1401/2007, INVIMA/HACCP, NFPA, etc.).

Para cada plantilla del catálogo tienes tres opciones:
- **Usar esta plantilla →** — la copia a tu repositorio y la abre para llenarla de inmediato.
- **📥 Agregar a mi repositorio** — la guarda sin llenarla, para usarla o asignarla después.
- **✎ Personalizar** — abre el wizard de digitalización con sus campos precargados, por si quieres ajustar algo antes de guardarla.

---

## 4. Llenar formularios (`Mis formularios`)

Aquí ves tu catálogo de plantillas guardadas. Para cada una puedes:

| Botón | Qué hace |
|---|---|
| ★ / ☆ | Marca/desmarca como favorita (aparece primero en la lista) |
| ▶ Llenar | Abre el formulario para llenarlo tú mismo |
| 📱 QR | Genera un código QR y un link para compartir el formulario — por correo o WhatsApp |
| Historial | Muestra todos los envíos anteriores de esa plantilla |
| ✕ | Elimina el formulario de tu repositorio |

Al llenar un formulario:
- Si quedó a medias, puedes guardarlo como **borrador** y continuarlo después.
- Los campos de **fecha/hora automática**, **ubicación GPS** y **firma** se completan solos o con un toque, sin que tengas que escribirlos a mano.
- Al enviar, el formulario queda guardado en tu historial y disponible en el Dashboard.

### Compartir un formulario en blanco
Desde **📱 QR** puedes activar un **link público**: cualquiera que lo abra (sin necesitar cuenta en SEKaform) puede llenarlo y enviarlo — el envío llega directo a tu repositorio. Este es el mecanismo que usa también la sección de Asignaciones (siguiente punto).

---

## 5. Asignar a tu equipo y dar seguimiento (`Asignaciones`)

Esta sección es para cuando **tú no vas a llenar el formulario, sino que necesitas que otras personas lo hagan** — por ejemplo, una inspección semanal que debe hacer cada supervisor de planta.

**Cómo crear una asignación:**
1. Elige la plantilla a asignar.
2. Escribe una lista de nombres, uno por línea. Opcionalmente agrega el correo: `Nombre, correo@ejemplo.com`.
3. Haz clic en **Crear asignación y generar link →**.

Esto activa automáticamente el link público de la plantilla (si no lo estaba) y lo copia al portapapeles, listo para mandarlo a tu equipo por el medio que prefieras (WhatsApp, correo, etc.).

**Cómo lo llena el asignado:** la persona abre el link, **escribe su nombre** (es el único dato obligatorio además de los campos del formulario — no necesita cuenta) y lo envía con normalidad.

**Cómo ves el cumplimiento:** cada tarjeta de asignación muestra una barra de progreso ("X/Y completado") y, al expandirla, la lista de personas con su estado:
- ✅ **Completado** — junto con la fecha/hora en que lo enviaron.
- ⏳ **Pendiente** — todavía no ha llegado su envío.

> 🔁 **Reasignaciones / rondas:** si vuelves a crear una asignación para la misma plantilla (ej. la ronda de la próxima semana), se crea una tarjeta nueva con su propio conteo de pendientes — el historial de cumplimiento de rondas anteriores no se pierde.

Usa **🔗 Copiar link** para reenviar el mismo enlace, o **✕** para eliminar una asignación (esto no borra los envíos ya recibidos, solo la lista de seguimiento).

---

## 6. Dashboard — Inteligencia de Negocios

Vista consolidada de todos tus formularios y envíos:
- Tarjetas con totales: formularios creados, envíos totales, envíos del mes, envíos de los últimos 7 días.
- Gráficos de envíos por día (últimos 30 días) y por formulario.
- Tabla con todos los registros capturados, filtrable por formulario, con **⬇ Exportar CSV** para análisis externo (Excel, Power BI, etc.).

---

## 7. Preguntas frecuentes

**¿Necesito conexión a internet?**
No para llenar formularios que ya tienes guardados — funcionan localmente. Sí la necesitas para que un asignado sin cuenta pueda abrir un link público y enviarlo, y para sincronizar entre dispositivos.

**¿Veo "💾 Datos locales (este dispositivo)" — qué significa?**
Que Supabase no está conectado (o no iniciaste sesión), así que tus formularios y envíos solo existen en este navegador/dispositivo. Conéctate desde **Iniciar sesión ☁** para sincronizar en la nube y poder asignar formularios a tu equipo desde cualquier lugar.

**¿Los asignados necesitan crear una cuenta en SEKaform?**
No. Se identifican solo con su nombre al momento de llenar el link que les compartes.

**¿Puedo ser "usuario" y "administrador" con la misma cuenta?**
Sí — no hay roles separados. Cualquier cuenta puede tener su propio repositorio de formularios *y* asignar formularios a un equipo al mismo tiempo.

---

*Generado a partir de la versión actual de SEKaform — los nombres de botones y secciones pueden variar levemente si la app se actualiza.*
