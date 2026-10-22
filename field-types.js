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
  {k:'equipo',         grupo:'Selección',   ico:'🏷', lbl:'Equipo (código)',          desc:'EXT-001, GAB-002…',  chip:'chip-smart', fieldClass:'fc-smart'},

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
const SEVERITY_TYPES = ['si_no', 'escala_1_5', 'select', 'radio', 'checkbox_multi', 'numero'];
function fieldCanHaveSeveridad(tipo) {
  return SEVERITY_TYPES.includes(tipo);
}
// El número es el único que usa un RANGO válido (mín/máx): si el valor
// registrado queda por fuera, se marca como hallazgo automáticamente.
function fieldUsaRango(tipo) {
  return tipo === 'numero';
}

// Detecta si una respuesta concreta indica un incumplimiento, dado el tipo
// de campo. Reutiliza el mismo estilo de la detección por regex que ya usa
// sugerirTipo()/sugerirOpciones() en digitalizador.html — sin requerir que
// el creador del formulario marque opción por opción cuál es "la mala".
const _SKF_BAD_ANSWER_RE = /no conforme|no cumple|incumple|deficiente|rechazad|inadecuad|insuficiente|vencid|da[ñn]ad|fuera de servicio/i;
function answerIsFinding(tipo, valor, field) {
  if (valor === undefined || valor === null || valor === '') return false;
  if (tipo === 'si_no') return valor === 'No';
  if (tipo === 'escala_1_5') return /^1\b|^2\b/.test(String(valor).trim());
  if (tipo === 'numero') {
    // Hallazgo si el valor queda por fuera del rango válido (mín/máx) definido
    // en el campo. Sin rango definido, un número nunca genera hallazgo.
    const n = parseFloat(String(valor).replace(',', '.'));
    if (isNaN(n) || !field) return false;
    const mn = (field.rangoMin === '' || field.rangoMin == null) ? null : parseFloat(field.rangoMin);
    const mx = (field.rangoMax === '' || field.rangoMax == null) ? null : parseFloat(field.rangoMax);
    if (mn === null && mx === null) return false;
    return (mn !== null && n < mn) || (mx !== null && n > mx);
  }
  if (tipo === 'checkbox_multi') {
    return Array.isArray(valor) && valor.some(v => _SKF_BAD_ANSWER_RE.test(String(v)));
  }
  if (tipo === 'select' || tipo === 'radio') return _SKF_BAD_ANSWER_RE.test(String(valor));
  return false;
}

// ── Lógica condicional: «mostrar este campo solo si otra respuesta es…» ─────
// campo.mostrarSi = { campoId, valores:[…] }. Solo puede depender de un campo ANTERIOR
// de respuesta única. Si la dependencia ya no es válida (el campo se borró, se movió
// más abajo o se cambió el texto de la opción) el campo se MUESTRA: es preferible un
// campo de más que uno que nunca aparece y deje al inspector sin poder registrar algo.
const COND_TYPES = ['si_no', 'radio', 'select', 'escala_1_5'];
function fieldCondOptions(c) {
  if (!c) return [];
  if (c.tipo === 'si_no') return ['Sí', 'No', 'N/A'];
  if (COND_TYPES.indexOf(c.tipo) === -1) return [];
  return (c.opciones || []).filter(function (o) { return o !== ''; });
}
function fieldIsVisible(c, campos, datos, depth) {
  var m = c && c.mostrarSi;
  if (!m || !m.campoId || !Array.isArray(m.valores) || !m.valores.length) return true;
  if ((depth || 0) > 8) return true;
  var ci = -1, ii = -1;
  for (var k = 0; k < campos.length; k++) { if (campos[k].id === m.campoId) ci = k; if (campos[k].id === c.id) ii = k; }
  if (ci < 0 || ii < 0 || ci >= ii) return true;
  var ctl = campos[ci];
  var opts = fieldCondOptions(ctl);
  if (!m.valores.some(function (v) { return opts.indexOf(v) !== -1; })) return true;
  if (!fieldIsVisible(ctl, campos, datos, (depth || 0) + 1)) return false;
  var v = datos[ctl.id];
  return m.valores.indexOf(v == null ? '' : String(v)) !== -1;
}

// ── Puntaje de cumplimiento de un registro ──────────────────────────────────
// Cuenta solo los «puntos de control»: preguntas Sí/No (N/A no cuenta), escalas 1–5, números con
// rango y cualquier otra pregunta de selección a la que se le puso criticidad. Los datos generales
// (nombre, área, fecha…) no suman ni restan. Un punto cumple si su respuesta NO sería un hallazgo.
// Lo oculto por una condición no cuenta. Devuelve null si el formulario no tiene puntos de control.
function skfPuntaje(campos, datos) {
  var items = [];
  (campos || []).forEach(function (c) {
    var v = datos ? datos[c.id] : undefined;
    if (v === undefined || v === null || v === '' || (Array.isArray(v) && !v.length)) return;
    if (!fieldIsVisible(c, campos, datos || {})) return;
    var cuenta = false;
    if (c.tipo === 'si_no') cuenta = (v === 'Sí' || v === 'No');
    else if (c.tipo === 'escala_1_5') cuenta = true;
    else if (c.tipo === 'numero') cuenta = (c.rangoMin !== undefined && c.rangoMin !== '' && c.rangoMin !== null) ||
                                          (c.rangoMax !== undefined && c.rangoMax !== '' && c.rangoMax !== null);
    else if (c.tipo === 'select' || c.tipo === 'radio' || c.tipo === 'checkbox_multi') cuenta = !!c.severidad;
    if (cuenta) items.push({ etiqueta: c.etiqueta, ok: !answerIsFinding(c.tipo, v, c) });
  });
  if (!items.length) return null;
  var ok = items.filter(function (i) { return i.ok; }).length;
  var pct = Math.round(ok / items.length * 100);
  return { total: items.length, ok: ok, pct: pct, nivel: pct >= 90 ? 'alto' : pct >= 70 ? 'medio' : 'bajo',
           fallan: items.filter(function (i) { return !i.ok; }).map(function (i) { return i.etiqueta; }) };
}

// ── Equipos: extintores, gabinetes, botiquines… ─────────────────────────
// Cada equipo se identifica con PREFIJO-consecutivo (EXT-001, EXT-002…). La
// ubicación NO va en el código: si el equipo se mueve, el código y su historial
// se mantienen. No hay inventario aparte: los equipos conocidos salen de los
// registros ya hechos, así que funciona desde el primer día sin preparar nada.
// dias: cada cuánto se inspecciona (NFPA 10, 14 y 101 piden revisión mensual).
const SKF_EQUIPOS = [
  {prefijo:'EXT', nombre:'Extintor',                 plural:'extintores',                ico:'🧯', dias:30},
  {prefijo:'GAB', nombre:'Gabinete contra incendio', plural:'gabinetes contra incendio', ico:'🚒', dias:30},
  {prefijo:'BOT', nombre:'Botiquín',                 plural:'botiquines',                ico:'🩹', dias:30},
  {prefijo:'CAM', nombre:'Camilla',                  plural:'camillas',                  ico:'🛏', dias:30},
  {prefijo:'LUZ', nombre:'Luz de emergencia',        plural:'luces de emergencia',       ico:'💡', dias:30},
  {prefijo:'ALA', nombre:'Pulsador / alarma',        plural:'pulsadores / alarmas',      ico:'🔔', dias:30},
  {prefijo:'LAV', nombre:'Lavaojos / ducha',         plural:'lavaojos / duchas',         ico:'🚿', dias:30},
];
function skfEquipoTipo(prefijo) {
  const p = String(prefijo || 'EXT').toUpperCase();
  return SKF_EQUIPOS.find(e => e.prefijo === p) || {prefijo:p, nombre:'Equipo', plural:'equipos', ico:'🏷', dias:30};
}
// «ext 3», «Ext-03», «EXT3» → «EXT-003». Lo que no tenga esa forma (la
// numeración propia de la empresa) se respeta tal cual, solo sin espacios de más.
function skfEquipoNormalizar(v) {
  const t = String(v == null ? '' : v).trim().replace(/\s+/g, ' ');
  const m = /^([A-Za-zÁÉÍÓÚÑáéíóúñ]{2,5})[\s\-_.]*0*(\d{1,4})$/.exec(t);
  if (m) return m[1].toUpperCase() + '-' + m[2].padStart(3, '0');
  return t;
}
function skfEquipoSiguiente(codigos, prefijo) {
  const p = String(prefijo || 'EXT').toUpperCase();
  const re = new RegExp('^' + p + '-(\\d+)$');
  let max = 0;
  (codigos || []).forEach(c => { const m = re.exec(skfEquipoNormalizar(c)); if (m) max = Math.max(max, parseInt(m[1], 10)); });
  return p + '-' + String(max + 1).padStart(3, '0');
}
// Equipos ya registrados de un tipo, con su última inspección (de cualquier
// formulario que tenga un campo «equipo» con ese prefijo).
function skfEquiposConocidos(envios, plantillas, prefijo) {
  const p = String(prefijo || 'EXT').toUpperCase();
  const camposDe = {};
  (plantillas || []).forEach(pl => {
    camposDe[pl.id] = (pl.campos || []).filter(c => c.tipo === 'equipo' && String(c.prefijo || 'EXT').toUpperCase() === p);
  });
  const por = {};
  (envios || []).forEach(e => {
    if (e.estado && e.estado !== 'enviado') return;
    const cs = camposDe[e.plantillaId || e.plantilla_id] || [];
    const fecha = e.enviadoEn || e.enviado_en || e.creadoEn || e.creado_en || '';
    cs.forEach(c => {
      const cod = skfEquipoNormalizar((e.datos || {})[c.id]);
      if (!cod) return;
      const prev = por[cod];
      if (!prev || String(fecha) > String(prev.ultima)) {
        por[cod] = {codigo:cod, ultima:fecha, unidadId:e.unidadId || e.unidad_id || null,
                    plantillaId:e.plantillaId || e.plantilla_id, datos:e.datos || {}, veces:(prev ? prev.veces : 0) + 1};
      } else prev.veces++;
    });
  });
  return Object.values(por).sort((a, b) => a.codigo.localeCompare(b.codigo, 'es', {numeric:true}));
}

// Estado de cada equipo hoy: cuándo toca su próxima inspección y cuándo vence su
// recarga (o prueba / vencimiento), tomada de un campo de fecha de su última
// inspección cuya etiqueta lo diga. dias* < 0 = vencido; null = no aplica.
const _SKF_RE_VENCE = /recarga|vencim|hidrost|caducidad/i;
function _skfDiasHasta(fecha, ahora) {
  const hoy = new Date(ahora.getFullYear(), ahora.getMonth(), ahora.getDate());
  const s = String(fecha || '');
  const d = /^\d{4}-\d{2}-\d{2}$/.test(s) ? new Date(s + 'T00:00:00') : new Date(s);
  if (isNaN(d.getTime())) return null;
  return Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - hoy) / 864e5);
}
function skfEquiposEstado(envios, plantillas, ahora) {
  ahora = ahora || new Date();
  const pls = plantillas || [];
  const prefijos = {};
  pls.forEach(pl => (pl.campos || []).forEach(c => { if (c.tipo === 'equipo') prefijos[String(c.prefijo || 'EXT').toUpperCase()] = 1; }));
  const out = [];
  Object.keys(prefijos).forEach(p => {
    const tipo = skfEquipoTipo(p);
    skfEquiposConocidos(envios, pls, p).forEach(eq => {
      const pl = pls.find(x => x.id === eq.plantillaId);
      const fv = pl && (pl.campos || []).find(c => c.tipo === 'fecha' && _SKF_RE_VENCE.test(c.etiqueta || '') && eq.datos[c.id]);
      const recarga = fv ? String(eq.datos[fv.id]) : null;
      const prox = new Date(new Date(eq.ultima).getTime() + tipo.dias * 864e5);
      out.push({codigo:eq.codigo, tipo, unidadId:eq.unidadId, plantillaId:eq.plantillaId, ultima:eq.ultima,
        proxima:isNaN(prox.getTime()) ? null : prox.toISOString(), diasInspeccion:_skfDiasHasta(prox.toISOString(), ahora),
        recarga, diasRecarga:recarga ? _skfDiasHasta(recarga, ahora) : null});
    });
  });
  const peor = e => Math.min(e.diasInspeccion == null ? 999 : e.diasInspeccion, e.diasRecarga == null ? 999 : e.diasRecarga);
  return out.sort((a, b) => peor(a) - peor(b) || a.codigo.localeCompare(b.codigo, 'es', {numeric:true}));
}

// Qué formulario abre el QR de un equipo: el de su última inspección si sigue
// existiendo; si no, cualquiera que tenga un campo de ese tipo de equipo.
function skfEquipoFormulario(codigo, envios, plantillas) {
  const cod = skfEquipoNormalizar(codigo);
  if (!cod) return null;
  const pls = plantillas || [];
  const pref = (/^([A-Z]+)-\d+$/.exec(cod) || [])[1];
  const prefijos = {};
  pls.forEach(pl => (pl.campos || []).forEach(c => { if (c.tipo === 'equipo') prefijos[String(c.prefijo || 'EXT').toUpperCase()] = 1; }));
  for (const p of Object.keys(prefijos)) {
    const eq = skfEquiposConocidos(envios, pls, p).find(x => x.codigo === cod);
    if (eq && pls.some(x => x.id === eq.plantillaId)) return eq.plantillaId;
  }
  const alguna = pref && pls.find(pl => (pl.campos || []).some(c => c.tipo === 'equipo' && String(c.prefijo || 'EXT').toUpperCase() === pref));
  return alguna ? alguna.id : null;
}
