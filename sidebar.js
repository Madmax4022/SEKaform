// ─────────────────────────────────────────────────────────────
//  SEKaform — Barra lateral colapsable (navegación + sesión)
//
//  Componente compartido por todas las páginas principales (no por
//  login.html, que es una pantalla previa a tener sesión). Se inserta
//  como primer elemento de <body> vía <script src="sidebar.js"></script>,
//  así que debe cargarse DESPUÉS de supabase-config.js en cada página
//  para que sbGetUser/sbSignOut ya existan.
//
//  El estado colapsado/expandido se guarda en localStorage y se aplica
//  antes del primer pintado mediante un script inline en <head> de cada
//  página (evita el "flash" de la barra abriéndose/cerrándose al cargar).
// ─────────────────────────────────────────────────────────────

function _skfEsc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;'); }

function skfToggleSidebar(forceOpen) {
  const collapsed = typeof forceOpen === 'boolean' ? !forceOpen : !document.documentElement.classList.contains('sb-collapsed');
  document.documentElement.classList.toggle('sb-collapsed', collapsed);
  localStorage.setItem('skf_sidebar_collapsed', collapsed ? 'true' : 'false');
}

// ── Barra inferior móvil — offline prep ──────────────────────────────────────

function skfPrepareOffline() {
  const btn = document.getElementById('bbOfflineBtn');
  if (!('serviceWorker' in navigator)) {
    if (btn) btn.textContent = '⚠️ No soportado';
    return;
  }
  if (btn) { btn.textContent = '⏳ Preparando…'; btn.disabled = true; }
  navigator.serviceWorker.getRegistrations().then(regs => {
    return regs.length
      ? Promise.all(regs.map(r => r.update()))
      : navigator.serviceWorker.register('sw.js');
  }).then(() => {
    const b = document.getElementById('bbOfflineBtn');
    if (b) { b.textContent = '✓ Lista sin conexión'; b.classList.add('bb-offline-ready'); b.disabled = false; }
  }).catch(() => {
    const b = document.getElementById('bbOfflineBtn');
    if (b) { b.textContent = '📥 Sin conexión'; b.disabled = false; }
  });
}

function _skfUpdateBottomAuth(user) {
  const el = document.getElementById('bbAuthZone');
  if (!el) return;
  if (user) {
    el.innerHTML = `<span class="bb-auth-chip">☁ ${_skfEsc(user.email)}</span>`;
  } else {
    el.innerHTML = `<a class="bb-btn" href="login.html">☁ Iniciar sesión</a>`;
  }
}

// ── Icono de ayuda «?» — popover de guía ─────────────────────────────────────
// Cualquier página puede poner <button class="skf-help" data-help-t="Título"
// data-help="Texto">?</button>. Un solo popover global se abre bajo el icono
// tocado y se cierra al tocar fuera, al tocar la ✕ o al abrir otro.

function _skfCloseHelp() {
  const pop = document.getElementById('skfHelpPop');
  if (pop) pop.remove();
  document.querySelectorAll('.skf-help.on, .skf-term.on').forEach(b => b.classList.remove('on'));
}

function _skfOpenHelp(btn) {
  _skfCloseHelp();
  btn.classList.add('on');
  const pop = document.createElement('div');
  pop.className = 'skf-help-pop';
  pop.id = 'skfHelpPop';
  const t = document.createElement('div');
  t.className = 'skf-help-pop-t';
  const tSpan = document.createElement('span');
  tSpan.textContent = btn.dataset.helpT || '¿Cómo funciona?';
  const x = document.createElement('button');
  x.className = 'skf-help-pop-x';
  x.textContent = '✕';
  x.setAttribute('aria-label', 'Cerrar ayuda');
  x.addEventListener('click', _skfCloseHelp);
  t.appendChild(tSpan); t.appendChild(x);
  const b = document.createElement('div');
  b.className = 'skf-help-pop-b';
  b.textContent = btn.dataset.help || '';
  pop.appendChild(t); pop.appendChild(b);
  document.body.appendChild(pop);
  const r = btn.getBoundingClientRect();
  const w = pop.offsetWidth;
  const left = Math.max(12, Math.min(r.left, window.innerWidth - w - 12));
  pop.style.top = (window.scrollY + r.bottom + 8) + 'px';
  pop.style.left = (window.scrollX + left) + 'px';
}

document.addEventListener('click', e => {
  const btn = e.target.closest('.skf-help, .skf-term');
  if (btn) {
    e.preventDefault(); e.stopPropagation();
    if (btn.classList.contains('on')) _skfCloseHelp();
    else _skfOpenHelp(btn);
    return;
  }
  if (!e.target.closest('#skfHelpPop')) _skfCloseHelp();
});


// ── Glosario: términos de SST tocables ───────────────────────────────────────
// Un usuario nuevo no tiene por qué saber qué es un COPASST o un hallazgo. Cada
// término se subraya con puntitos la PRIMERA vez que aparece en la pantalla y,
// al tocarlo, abre el mismo popover que el «?». Se llama a skfGlosar(raíz)
// después de pintar (también tras renders dinámicos).
const SKF_GLOSARIO = [
  { re: /\bSG-SST\b/, t: 'SG-SST',
    d: 'Sistema de Gestión de Seguridad y Salud en el Trabajo: el conjunto de cosas que tu empresa organiza para evitar accidentes y enfermedades laborales — identificar peligros, inspeccionar, capacitar y corregir.\n\nEn Colombia es obligatorio para todo empleador (Decreto 1072 de 2015).' },
  { re: /\bCOPASST\b/, t: 'COPASST',
    d: 'Comité Paritario de Seguridad y Salud en el Trabajo: un grupo con representantes del empleador y de los trabajadores que se reúne cada mes para vigilar que la empresa cumpla con SST.\n\nEn otros países se llama Comité o Comisión de Salud y Seguridad Ocupacional.' },
  { re: /\bhallazgos?\b/i, t: 'Hallazgo',
    d: 'Algo que no cumple y se encontró al inspeccionar: un extintor vencido, una salida bloqueada, un trabajador sin casco.\n\nCada hallazgo se corrige con una acción correctiva, con responsable y fecha límite.' },
  { re: /\bacciones? correctivas?\b/i, t: 'Acción correctiva',
    d: 'Lo que se hace para arreglar un hallazgo y evitar que se repita: quién lo hace y para cuándo. Al cerrarla queda como evidencia de que corregiste.' },
  { re: /\bEPP\b/, t: 'EPP',
    d: 'Elementos de Protección Personal: casco, guantes, gafas, botas, tapabocas, arnés. La empresa debe entregarlos y dejar constancia firmada.' },
  { re: /\bGTC[ -]?45\b/, t: 'GTC 45',
    d: 'Guía técnica colombiana para identificar los peligros de cada actividad y valorar qué tan graves son sus riesgos. Con ella se arma la matriz de peligros.' },
  { re: /\bmatriz de peligros\b/i, t: 'Matriz de peligros',
    d: 'Una tabla donde la empresa lista los peligros de cada actividad (caídas, ruido, químicos…), qué tan graves son y qué hace para controlarlos. Es la base de todo el SG-SST.' },
  { re: /\bARL\b/, t: 'ARL',
    d: 'Administradora de Riesgos Laborales: la aseguradora que cubre a tus trabajadores si sufren un accidente o una enfermedad por el trabajo. El empleador debe afiliarlos.' },
  { re: /\bHACCP\b/, t: 'HACCP',
    d: 'Análisis de Peligros y Puntos Críticos de Control: un método para que un alimento no se contamine ni se dañe, vigilando los puntos del proceso donde puede pasar — por ejemplo, la temperatura de la nevera.' },
  { re: /\bINVIMA\b/, t: 'INVIMA',
    d: 'Instituto Nacional de Vigilancia de Medicamentos y Alimentos: la entidad colombiana que vigila alimentos y medicamentos. Sus visitas pueden terminar en sanciones o en el cierre del establecimiento.' },
  { re: /\bBPM\b/, t: 'BPM',
    d: 'Buenas Prácticas de Manufactura: las reglas de higiene y orden para manipular y producir alimentos de forma segura.' },
  { re: /\bMIP\b/, t: 'MIP',
    d: 'Manejo Integrado de Plagas: controlar roedores e insectos con prevención y registros, no solo fumigando.' },
  { re: /\bNFPA\b/, t: 'NFPA',
    d: 'National Fire Protection Association: asociación de Estados Unidos cuyas normas de protección contra incendios se usan como referencia en Colombia — extintores, rociadores, alarmas y salidas.' },
  { re: /\bRUC\b/, t: 'RUC',
    d: 'Registro Uniforme para la Evaluación del Desempeño en SST de contratistas: un sistema con el que las empresas contratantes evalúan a sus contratistas. Muchas lo exigen para dar trabajo.' },
  { re: /\bPGIRASA\b/, t: 'PGIRASA',
    d: 'Plan de Gestión Integral de Residuos de Atención en Salud: cómo una clínica o laboratorio separa, almacena y entrega sus residuos peligrosos.' },
  { re: /\bISO 9001\b/, t: 'ISO 9001',
    d: 'Norma internacional de gestión de calidad. Certificarse demuestra que la empresa controla sus procesos y corrige sus fallas.' },
  { re: /\bRes(?:olución|\.)?\s?0312\b/, t: 'Resolución 0312 de 2019',
    d: 'Define los estándares mínimos del SG-SST que debe cumplir una empresa. Cuántos le exigen depende de su tamaño y del nivel de riesgo de su actividad.' },
];

function skfGlosar(root) {
  root = root || document.body;
  if (!root || !root.querySelectorAll) return;
  const OMITIR = new Set(['SCRIPT','STYLE','BUTTON','INPUT','TEXTAREA','SELECT','OPTION','H1']);
  const yaEnPantalla = new Set(Array.from(document.querySelectorAll('.skf-term')).map(el => el.dataset.helpT));
  SKF_GLOSARIO.forEach(g => {
    if (yaEnPantalla.has(g.t)) return;
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        for (let p = n.parentNode; p && p !== root.parentNode; p = p.parentNode) {
          if (p.nodeType === 1 && (OMITIR.has(p.tagName) || p.classList.contains('skf-term') || p.classList.contains('skf-help') || p.id === 'skfHelpPop')) return NodeFilter.FILTER_REJECT;
        }
        return g.re.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    const nodo = w.nextNode();
    if (!nodo) return;
    const m = nodo.nodeValue.match(g.re);
    const resto = nodo.splitText(m.index);
    resto.splitText(m[0].length);
    const span = document.createElement('span');
    span.className = 'skf-term';
    span.dataset.helpT = g.t;
    span.dataset.help = g.d;
    span.setAttribute('role', 'button');
    span.setAttribute('tabindex', '0');
    span.textContent = m[0];
    resto.parentNode.replaceChild(span, resto);
  });
}
document.addEventListener('keydown', e => {
  if ((e.key === 'Enter' || e.key === ' ') && e.target.classList && e.target.classList.contains('skf-term')) { e.preventDefault(); e.target.click(); }
});

// ── Rol de solo lectura ──────────────────────────────────────────────────────
// Si el usuario es "lector" en su organización, muestra un aviso y activa la
// clase .skf-lector en <html> (styles.css oculta/desactiva los controles de
// escritura). El servidor ya rechaza esas escrituras por RLS; esto solo evita
// mostrar botones que fallarían. Si no se puede resolver el rol (sin sesión,
// sin conexión), no se gatea nada: se muestra la UI completa y el servidor
// sigue siendo la autoridad.
async function skfApplyRoleGating() {
  if (typeof skfRol !== 'function') return;
  let rol = null;
  try { rol = await skfRol(); } catch {}
  if (rol !== 'lector') return;
  document.documentElement.classList.add('skf-lector');
  if (document.getElementById('skfReadonlyBar')) return;
  const bar = document.createElement('div');
  bar.id = 'skfReadonlyBar';
  bar.className = 'skf-readonly-bar';
  bar.innerHTML = '👁️ Tu rol es <strong>solo lectura</strong>: puedes ver todo, pero no crear ni editar. Pídele a un administrador de tu organización que cambie tu permiso si necesitas editar.';
  const host = document.querySelector('.page.on .wrap') || document.querySelector('.wrap, .wrapper');
  if (host) host.insertAdjacentElement('afterbegin', bar);
  else document.body.insertAdjacentElement('afterbegin', bar);
}

// ── Mapa de la app: secciones y a cuál pertenece cada página ────────────────
// Hacer (Registrar) · Planear (Plan) · Seguir (Hallazgos) · Demostrar (Cumplimiento) · Configurar (Mi empresa)
const SKF_SECCIONES = {
  hoy:          { t: 'Hoy',          ico: '🏠', href: 'index.html' },
  plan:         { t: 'Plan',         ico: '📅', href: 'plan.html' },
  hallazgos:    { t: 'Hallazgos',    ico: '⚠️', href: 'hallazgos.html' },
  cumplimiento: { t: 'Cumplimiento', ico: '🎯', href: 'cumplimiento.html' },
  empresa:      { t: 'Mi empresa',   ico: '🏢', href: 'empresa.html' },
};
// página → [sección, título si es una subpágina (muestra «‹ sección» para volver)]
const SKF_PAGINAS = {
  '': ['hoy'], 'index.html': ['hoy'],
  'plan.html': ['plan'], 'programadas.html': ['plan', 'Rutinas'], 'asignaciones.html': ['plan', 'Encargos'], 'turnos.html': ['plan', 'Turnos'],
  'hallazgos.html': ['hallazgos'],
  'cumplimiento.html': ['cumplimiento'], 'dashboard.html': ['cumplimiento', 'Panel y reportes'],
  'empresa.html': ['empresa'], 'organizacion.html': ['empresa', 'Datos de la empresa'], 'unidades.html': ['empresa', 'Lugares'],
  'plantillas.html': ['empresa', 'Catálogo'], 'llenar.html': ['empresa', 'Formularios'], 'digitalizador.html': ['empresa', 'Crear formulario'],
  'bienvenida.html': ['empresa', 'Configurar'],
};

// ── Hoja inferior genérica (bottom sheet) ───────────────────────────────────
// Se abre desde abajo, en la zona del pulgar. Se cierra tocando fuera, con Esc, con la ✕
// o arrastrando hacia abajo. Devuelve el elemento del contenido.
function skfSheet(titulo, cuerpoHtml, origen) {
  skfSheetCerrar();
  const w = document.createElement('div');
  w.className = 'skf-sheet-wrap'; w.id = 'skfSheet';
  w.innerHTML = `<div class="skf-sheet-bg" data-cerrar></div>
    <div class="skf-sheet" role="dialog" aria-modal="true" aria-labelledby="skfSheetT">
      <div class="skf-sheet-grab" aria-hidden="true"></div>
      <div class="skf-sheet-hd"><h2 id="skfSheetT">${titulo}</h2><button type="button" class="skf-sheet-x" data-cerrar aria-label="Cerrar">✕</button></div>
      <div class="skf-sheet-body">${cuerpoHtml}</div>
    </div>`;
  document.body.appendChild(w);
  w._origen = origen || document.activeElement;
  w.addEventListener('click', e => { if (e.target.closest('[data-cerrar]')) skfSheetCerrar(); });
  // Arrastrar hacia abajo desde la cabecera para cerrar, como en una app nativa.
  const hoja = w.querySelector('.skf-sheet'); let y0 = null, dy = 0;
  hoja.addEventListener('touchstart', e => { if (hoja.scrollTop <= 0 && e.target.closest('.skf-sheet-grab,.skf-sheet-hd')) { y0 = e.touches[0].clientY; dy = 0; } }, { passive: true });
  hoja.addEventListener('touchmove', e => { if (y0 === null) return; dy = Math.max(0, e.touches[0].clientY - y0); hoja.style.transform = `translateY(${dy}px)`; }, { passive: true });
  hoja.addEventListener('touchend', () => { if (y0 === null) return; y0 = null; hoja.style.transform = ''; if (dy > 90) skfSheetCerrar(); });
  requestAnimationFrame(() => w.classList.add('on'));
  document.documentElement.classList.add('skf-sheet-abierta');
  const primero = w.querySelector('.skf-sheet-body a, .skf-sheet-body button');
  if (primero) primero.focus({ preventScroll: true });
  return w.querySelector('.skf-sheet-body');
}
function skfSheetCerrar() {
  const w = document.getElementById('skfSheet');
  if (!w) return;
  document.documentElement.classList.remove('skf-sheet-abierta');
  const origen = w._origen;
  w.remove();
  if (origen && origen.focus) origen.focus({ preventScroll: true });
}
document.addEventListener('keydown', e => { if (e.key === 'Escape') skfSheetCerrar(); });

// ── «Registrar»: lo que se hace en campo, a un toque ────────────────────────
// Primero los formularios propios (favoritos y los más usados); luego los reportes de SST que
// cualquiera debe poder hacer sin buscar: un peligro, un accidente, una capacitación. Esos van al
// catálogo con ?preset=…, que abre el formulario propio si ya existe (no crea copias).
function skfRegistrar() {
  if (document.documentElement.classList.contains('skf-lector')) {
    skfSheet('Solo lectura', '<p class="skf-sheet-nota">Tu rol es de solo lectura: puedes ver todo, pero no registrar. Pídele a un administrador que cambie tu permiso.</p>');
    return;
  }
  try { if (navigator.vibrate) navigator.vibrate(8); } catch (e) {}
  const lee = k => { try { return JSON.parse(localStorage.getItem(k) || '[]'); } catch (e) { return []; } };
  const plts = lee('skf_plantillas'), envs = lee('skf_envios');
  const uso = {}; envs.forEach(e => { const id = e.plantillaId || e.plantilla_id; const f = e.enviadoEn || e.creadoEn || ''; if (id && (!uso[id] || f > uso[id])) uso[id] = f; });
  const evento = /accidente|incidente/i;
  const mios = plts.filter(p => p && p.id && !evento.test(p.nombre || ''))
    .sort((a, b) => (b.favorito ? 1 : 0) - (a.favorito ? 1 : 0) || String(uso[b.id] || '').localeCompare(String(uso[a.id] || '')) || String(a.nombre).localeCompare(String(b.nombre)))
    .slice(0, 5);
  const fila = (href, ico, t, sub, cls) => `<a class="skf-opt${cls ? ' ' + cls : ''}" href="${href}"><span class="so-ico" aria-hidden="true">${ico}</span><span class="so-txt"><b>${_skfEsc(t)}</b>${sub ? `<small>${_skfEsc(sub)}</small>` : ''}</span><span class="so-arr" aria-hidden="true">›</span></a>`;
  const formularios = mios.length
    ? mios.map(p => fila('llenar.html?tmpl=' + encodeURIComponent(p.id), p.favorito ? '⭐' : '📋', p.nombre, uso[p.id] ? 'Último: ' + new Date(uso[p.id]).toLocaleDateString('es-CO', { day: 'numeric', month: 'short' }) : 'Aún sin registros')).join('')
    : fila('digitalizador.html?preset=inspeccion_sst', '📋', 'Lista de verificación SST', 'La inspección básica de seguridad');
  skfSheet('¿Qué vas a registrar?', `
    <div class="skf-sheet-sec">Inspeccionar</div>${formularios}
    <a class="skf-sheet-mas" href="llenar.html">Ver todos mis formularios ›</a>
    <div class="skf-sheet-sec">Reportar</div>
    ${fila('digitalizador.html?preset=reporte_condicion_acto_inseguro', '⚠️', 'Un peligro o acto inseguro', 'Algo que puede causar un accidente')}
    ${fila('digitalizador.html?preset=incidente_accidente', '🚑', 'Un accidente o incidente', 'Lo que ya pasó: registrarlo es obligatorio', 'urgente')}
    ${fila('digitalizador.html?preset=asistencia', '🎓', 'Asistencia a una capacitación', 'Quién asistió y firmas')}`);
}

function skfRenderSidebar() {
  const current = (location.pathname.split('/').pop() || 'index.html');
  const [secActual, subTitulo] = SKF_PAGINAS[current] || ['hoy'];
  const sec = SKF_SECCIONES[secActual];

  // Escritorio: el mismo orden que la barra del teléfono — hacer, planear, seguir, demostrar;
  // y aparte, «Mi empresa» para configurar. 8 enlaces en lugar de 13.
  const PRINCIPAL = [
    { href: 'index.html', s: 'hoy' }, { href: 'plan.html', s: 'plan' },
    { href: 'hallazgos.html', s: 'hallazgos' }, { href: 'cumplimiento.html', s: 'cumplimiento' },
    { href: 'dashboard.html', ico: '📊', label: 'Panel y reportes' },
  ];
  const EMPRESA = [
    { href: 'empresa.html', s: 'empresa' },
    { href: 'llenar.html', ico: '📋', label: 'Formularios' },
    { href: 'unidades.html', ico: '📍', label: 'Lugares' },
  ];
  const _sl = l => {
    const d = l.s ? SKF_SECCIONES[l.s] : l;
    const activo = current === l.href || (l.s && l.s === secActual && !PRINCIPAL.concat(EMPRESA).some(x => x.href === current && x !== l));
    return `<a href="${l.href}" class="sidebar-link${activo ? ' active' : ''}"${activo ? ' aria-current="page"' : ''}><span class="sidebar-ico">${d.ico}</span>${d.label || d.t}</a>`;
  };
  const links = `<button type="button" class="sidebar-registrar" onclick="skfRegistrar()">＋ Registrar</button>
    <div class="sidebar-group">${PRINCIPAL.map(_sl).join('')}</div>
    <div class="sidebar-group"><div class="sidebar-group-h">Mi empresa</div>${EMPRESA.map(_sl).join('')}</div>`;

  // Teléfono: barra superior que siempre dice DÓNDE estás (sección, o «‹ sección» en una
  // subpágina) y lleva a «Mi empresa»; y barra inferior para el pulgar con «Registrar» al centro.
  // Las pantallas de tarea (llenar un formulario, crear uno) ya tienen su propia barra.
  const tieneToolbar = !!document.querySelector('.page-toolbar') || /^(llenar|digitalizador)\.html$/.test(current);
  const appbar = tieneToolbar ? '' : `
    <header class="skf-appbar" id="skfAppbar">
      ${subTitulo
        ? `<a class="ab-back" href="${sec.href}" aria-label="Volver a ${sec.t}"><span aria-hidden="true">‹</span> ${sec.t}</a><span class="ab-sub">${subTitulo}</span>`
        : `<span class="ab-title"><span aria-hidden="true">${sec.ico}</span> ${sec.t}</span>`}
      ${typeof skfDemoActivo === 'function' && skfDemoActivo() ? '<span class="ab-demo" title="Datos de ejemplo: nada es real">🧪 Ejemplo</span>' : ''}
      <a class="ab-empresa${secActual === 'empresa' ? ' on' : ''}" href="empresa.html" aria-label="Mi empresa" id="abEmpresa"><span id="abInicial">🏢</span></a>
    </header>`;
  const tab = k => {
    const x = SKF_SECCIONES[k], on = k === secActual;
    return `<a href="${x.href}" class="bb-tab${on ? ' active' : ''}" data-sec="${k}"${on ? ' aria-current="page"' : ''}><span class="bi" aria-hidden="true">${x.ico}</span><span class="bl">${x.t}</span></a>`;
  };

  const html = `
    <div class="skf-sync-bar" id="skfSyncBar" style="display:none"></div>
    <button class="sidebar-toggle" id="sidebarToggle" onclick="skfToggleSidebar()" title="Mostrar/ocultar menú" aria-label="Mostrar/ocultar menú">☰</button>
    <aside class="sidebar" id="sidebar">
      <a href="index.html" class="sidebar-logo">SEK<span>a</span>form</a>
      <nav class="sidebar-nav" aria-label="Menú principal">${links}</nav>
      <div class="sidebar-bottom" id="sidebarAuth">
        <a class="auth-link" href="login.html">Iniciar sesión ☁</a>
      </div>
    </aside>
    <div class="sidebar-backdrop" id="sidebarBackdrop" onclick="skfToggleSidebar(false)"></div>
    ${appbar}
    <nav class="skf-bottom-bar" id="skfBottomBar" aria-label="Navegación">
      ${tab('hoy')}${tab('plan')}
      <button type="button" class="bb-fab" onclick="skfRegistrar()" aria-label="Registrar algo nuevo" aria-haspopup="dialog">
        <span class="bb-fab-c" aria-hidden="true">＋</span><span class="bl">Registrar</span></button>
      ${tab('hallazgos')}${tab('cumplimiento')}
    </nav>
  `;
  document.body.insertAdjacentHTML('afterbegin', html);


  // Modo ejemplo: aviso permanente para que NUNCA se confunda con datos reales.
  if (typeof skfDemoActivo === 'function' && skfDemoActivo()) {
    document.body.insertAdjacentHTML('afterbegin',
      '<div class="skf-demo-bar" role="status"><span>🧪 <b>Datos de ejemplo</b> — nada de esto es real y no se guarda.</span>' +
      '<button type="button" onclick="skfDemoSalir()">Salir del ejemplo</button></div>');
  }

  // Barra de «siguiente paso»: hasta que la cuenta tenga su primer envío (el momento en que la app
  // ya le sirvió), una franja fija en TODAS las páginas lleva directo a ese paso. Así quien entra
  // por cualquier puerta no queda a varios clics del camino que importa. Desaparece sola.
  (function skfBarraSiguiente() {
    try {
      var pg = location.pathname.split('/').pop() || 'index.html';
      var q = location.search;
      // No en: inicio (ya tiene su tarjeta), asistente, digitalizador, ni mientras llena un formulario.
      if (['index.html', 'bienvenida.html', 'digitalizador.html'].indexOf(pg) !== -1) return;
      if (pg === 'llenar.html' && /[?&](tmpl|pub|shared)=/.test(q)) return;
      if (typeof skfDemoActivo === 'function' && skfDemoActivo()) return;
      if (sessionStorage.getItem('skf_barra_off') === '1') return;
      if (typeof sbGetUser !== 'function' || typeof sbLoadEnvios !== 'function') return;
      sbGetUser().then(function (user) {
        if (!user) return;
        return sbLoadEnvios().then(function (nube) {
          var local = []; try { local = JSON.parse(localStorage.getItem('skf_envios') || '[]'); } catch (e) {}
          if ((nube && nube.length) || local.length) return;       // ya tiene su primer envío
          var plts = []; try { plts = JSON.parse(localStorage.getItem('skf_plantillas') || '[]'); } catch (e) {}
          var href = plts.length && plts[0].id ? 'llenar.html?tmpl=' + encodeURIComponent(plts[0].id)
                                               : 'digitalizador.html?preset=inspeccion_sst';
          var b = document.createElement('div');
          b.className = 'skf-next-bar'; b.setAttribute('role', 'status');
          b.innerHTML = '<span>👉 <b>Te falta un paso:</b> haz tu primer registro y ya tendrás evidencia.</span>' +
            '<a href="' + href + '">Empezar</a>' +
            '<button type="button" aria-label="Ocultar por ahora">✕</button>';
          b.querySelector('button').onclick = function () { try { sessionStorage.setItem('skf_barra_off', '1'); } catch (e) {} b.remove(); };
          document.body.insertAdjacentElement('afterbegin', b);
        });
      }).catch(function () {});
    } catch (e) {}
  })();

  // «Mi empresa» con la inicial de la organización, para que se sienta propio.
  if (typeof sbLoadOrg === 'function' && document.getElementById('abInicial')) {
    sbLoadOrg().then(o => { const n = (o && o.nombre || '').trim(); if (n) document.getElementById('abInicial').textContent = n[0].toUpperCase(); }).catch(() => {});
  }


  // En páginas con barra de herramientas (llenar, digitalizador) los botones
  // de la toolbar viven arriba a la derecha, justo donde flota la barra de
  // sincronización — se marca el body para bajarla y evitar el choque (CSS).
  // La toolbar puede estar más abajo en el HTML que este script, así que se
  // comprueba cuando el DOM ya está listo.
  const _skfMarkToolbar = () => {
    if (document.querySelector('.page-toolbar')) document.body.classList.add('skf-has-toolbar');
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', _skfMarkToolbar);
  else _skfMarkToolbar();

  // On mobile the sidebar is a flyout overlay — collapse it when the user
  // taps any nav link so the destination page doesn't re-open it.
  document.querySelectorAll('.sidebar-link').forEach(a => {
    a.addEventListener('click', () => {
      if (window.matchMedia('(max-width:860px)').matches) {
        localStorage.setItem('skf_sidebar_collapsed', 'true');
      }
    });
  });

  if (typeof sbGetUser === 'function') {
    sbGetUser().then(user => {
      _skfUpdateBottomAuth(user || null);
      if (!user) return;
      skfApplyRoleGating();
      const bar = document.getElementById('sidebarAuth');
      bar.innerHTML = `<span class="auth-chip">☁ ${_skfEsc(user.email)}</span><button class="auth-bell" id="skfBellBtn" onclick="skfToggleNotifications()">🔕</button><a class="auth-link" onclick="sbSignOut().then(()=>location.reload())">Salir</a>`;
      if (typeof skfUpdateBellIcon === 'function') skfUpdateBellIcon();
      if (typeof skfSubscribeCriticalAlerts === 'function') skfSubscribeCriticalAlerts(user);
    }).catch(() => {});
  }

  // Si el cache del SW ya existe, mostrar que ya está lista para sin conexión.
  // Se busca por prefijo y no por el nombre exacto: al bumpear CACHE_VERSION en
  // sw.js este check quedaba mirando un cache viejo y el aviso no volvía a salir.
  if ('caches' in window) {
    caches.keys().then(ks => ks.some(k => k.startsWith('skf-shell-'))).then(has => {
      if (has) {
        const btn = document.getElementById('bbOfflineBtn');
        if (btn) { btn.textContent = '✓ Lista sin conexión'; btn.classList.add('bb-offline-ready'); }
      }
    }).catch(() => {});
  }
}

skfRenderSidebar();
