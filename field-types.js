// SEKaform — catálogo único de tipos de campo.
//
// Fuente de verdad compartida entre digitalizador.html (selector de tipo y
// vista previa) y llenar.html (íconos del formulario real al llenarlo).
// Antes cada página mantenía su propia copia escrita a mano y llegaron a
// divergir sin que nada lo notara (el ícono de "Desplegable" no era el
// mismo en las dos: ▼ en una, ▾ en la otra).
//
// Cargar con <script src="field-types.js"></script> antes del script
// inline de cada página que lo use.

const FIELD_TYPE_GROUPS = ['Automáticos', 'Selección', 'Multimedia', 'Texto', 'Estructura'];

const FIELD_TYPES = [
  {k:'fecha_auto',     grupo:'Automáticos', ico:'📅', lbl:'Fecha automática',         desc:'Hoy auto',           chip:'chip-auto',  fieldClass:'fc-auto'},
  {k:'hora_auto',      grupo:'Automáticos', ico:'⏰', lbl:'Hora automática',          desc:'Ahora auto',         chip:'chip-auto',  fieldClass:'fc-auto'},
  {k:'ubicacion',      grupo:'Automáticos', ico:'📍', lbl:'Ubicación GPS',            desc:'Coords. auto',       chip:'chip-auto',  fieldClass:'fc-auto'},

  {k:'si_no',          grupo:'Selección',   ico:'✓✗', lbl:'Sí / No / N/A',           desc:'Cumplimiento',       chip:'chip-smart', fieldClass:'fc-smart'},
  {k:'escala_1_5',     grupo:'Selección',   ico:'⭐',  lbl:'Escala 1–5',               desc:'Calificación',       chip:'chip-smart', fieldClass:'fc-smart', needsOptions:true},
  {k:'select',         grupo:'Selección',   ico:'▼',  lbl:'Desplegable',              desc:'Lista opciones',     chip:'chip-smart', fieldClass:'fc-smart', needsOptions:true},
  {k:'radio',          grupo:'Selección',   ico:'◉',  lbl:'Opción única',             desc:'Radio buttons',      chip:'chip-smart', fieldClass:'fc-smart', needsOptions:true},
  {k:'checkbox',       grupo:'Selección',   ico:'☑',  lbl:'Casilla de verificación',  desc:'Marcar/Sin marcar',  chip:'chip-smart', fieldClass:'fc-smart'},
  {k:'checkbox_multi', grupo:'Selección',   ico:'📋', lbl:'Opción múltiple',          desc:'Varias casillas',    chip:'chip-smart', fieldClass:'fc-smart', needsOptions:true},

  {k:'firma',          grupo:'Multimedia',  ico:'✍',  lbl:'Firma digital',            desc:'Canvas táctil',      chip:'chip-sig',   fieldClass:'fc-sig'},
  {k:'foto',           grupo:'Multimedia',  ico:'📷', lbl:'Fotografía',               desc:'Cámara/galería',     chip:'chip-photo', fieldClass:'fc-media'},

  {k:'texto',          grupo:'Texto',       ico:'T',  lbl:'Texto corto',              desc:'Una línea',          chip:'chip-man'},
  {k:'textarea',       grupo:'Texto',       ico:'¶',  lbl:'Texto largo',              desc:'Párrafo',            chip:'chip-man'},
  {k:'numero',         grupo:'Texto',       ico:'#',  lbl:'Número',                   desc:'Cifra',              chip:'chip-man'},
  {k:'email',          grupo:'Texto',       ico:'@',  lbl:'Correo',                   desc:'E-mail',             chip:'chip-man'},
  {k:'telefono',       grupo:'Texto',       ico:'☏',  lbl:'Teléfono',                 desc:'Tel/cel',            chip:'chip-man'},
  {k:'fecha',          grupo:'Texto',       ico:'🗓', lbl:'Fecha manual',             desc:'El usuario elige',   chip:'chip-man'},

  {k:'separador',      grupo:'Estructura',  ico:'—',  lbl:'Separador / Título',       desc:'Encabezado',         chip:'chip-sep'},
];

const FIELD_TYPE_MAP = Object.fromEntries(FIELD_TYPES.map(t => [t.k, t]));

function fieldNeedsOptions(tipo) {
  return !!(FIELD_TYPE_MAP[tipo] && FIELD_TYPE_MAP[tipo].needsOptions);
}

// Tipos donde la respuesta del inspector puede indicar un incumplimiento
// (ej. "No Conforme", "1 - Deficiente") — solo estos pueden marcarse con
// una criticidad en digitalizador.html para que llenar.html detecte
// automáticamente un hallazgo. Los campos de texto libre no califican: no
// hay forma confiable de saber si la respuesta es "mala" sin que el
// inspector la reporte manualmente.
const SEVERITY_TYPES = ['si_no', 'escala_1_5', 'select', 'radio', 'checkbox_multi'];
function fieldCanHaveSeveridad(tipo) {
  return SEVERITY_TYPES.includes(tipo);
}

// Detecta si una respuesta concreta indica un incumplimiento, dado el tipo
// de campo. Reutiliza el mismo estilo de la detección por regex que ya usa
// sugerirTipo()/sugerirOpciones() en digitalizador.html — sin requerir que
// el creador del formulario marque opción por opción cuál es "la mala".
const _SKF_BAD_ANSWER_RE = /no conforme|no cumple|incumple|deficiente|rechazad|inadecuad|insuficiente|vencid|da[ñn]ad|fuera de servicio/i;
function answerIsFinding(tipo, valor) {
  if (valor === undefined || valor === null || valor === '') return false;
  if (tipo === 'si_no') return valor === 'No';
  if (tipo === 'escala_1_5') return /^1\b|^2\b/.test(String(valor).trim());
  if (tipo === 'checkbox_multi') {
    return Array.isArray(valor) && valor.some(v => _SKF_BAD_ANSWER_RE.test(String(v)));
  }
  if (tipo === 'select' || tipo === 'radio') return _SKF_BAD_ANSWER_RE.test(String(valor));
  return false;
}
