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
