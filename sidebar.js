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

function skfRenderSidebar() {
  const current = (location.pathname.split('/').pop() || 'index.html');
  // Menú agrupado: la SST es la estrella; la configuración y las herramientas
  // de creación quedan en un grupo colapsable ("segundo plano").
  const GRUPOS = [
    { h: '⛑️ Salud Ocupacional', links: [
      { href: 'index.html',        ico: '⛑️', label: 'Centro de SST' },
      { href: 'cumplimiento.html', ico: '🎯', label: 'Mapa de cumplimiento' },
      { href: 'hallazgos.html',    ico: '⚠️', label: 'Hallazgos' },
    ]},
    { h: 'Día a día', links: [
      { href: 'llenar.html',    ico: '📝', label: 'Mis formularios' },
      { href: 'dashboard.html', ico: '📊', label: 'Panel de control' },
    ]},
    { h: 'Configuración y más', colapsable: true, links: [
      { href: 'bienvenida.html',    ico: '🧭', label: 'Configurar mi empresa' },
      { href: 'digitalizador.html', ico: '⚡', label: 'Crear formulario' },
      { href: 'plantillas.html',    ico: '📋', label: 'Formularios listos' },
      { href: 'asignaciones.html',  ico: '👥', label: 'Asignaciones' },
      { href: 'turnos.html',        ico: '🔄', label: 'Control por turnos' },
      { href: 'programadas.html',   ico: '📅', label: 'Programadas' },
      { href: 'unidades.html',      ico: '🏢', label: 'Sedes y áreas' },
      { href: 'organizacion.html',  ico: '⚙️', label: 'Organización' },
    ]},
  ];
  const _sl = l => `<a href="${l.href}" class="sidebar-link${current === l.href ? ' active' : ''}"><span class="sidebar-ico">${l.ico}</span>${l.label}</a>`;
  const links = GRUPOS.map(g => {
    const items = g.links.map(_sl).join('');
    if (g.colapsable) {
      const aqui = g.links.some(l => l.href === current);
      return `<details class="sidebar-group"${aqui ? ' open' : ''}><summary class="sidebar-group-h">${g.h}</summary>${items}</details>`;
    }
    return `<div class="sidebar-group"><div class="sidebar-group-h">${g.h}</div>${items}</div>`;
  }).join('');

  const html = `
    <div class="skf-sync-bar" id="skfSyncBar" style="display:none"></div>
    <button class="sidebar-toggle" id="sidebarToggle" onclick="skfToggleSidebar()" title="Mostrar/ocultar menú" aria-label="Mostrar/ocultar menú">☰</button>
    <aside class="sidebar" id="sidebar">
      <a href="index.html" class="sidebar-logo">SEK<span>a</span>form</a>
      <nav class="sidebar-nav">${links}</nav>
      <div class="sidebar-bottom" id="sidebarAuth">
        <a class="auth-link" href="login.html">Iniciar sesión ☁</a>
      </div>
    </aside>
    <div class="sidebar-backdrop" id="sidebarBackdrop" onclick="skfToggleSidebar(false)"></div>
    <nav class="skf-bottom-bar" id="skfBottomBar" aria-label="Navegación">
      <a href="index.html"     class="bb-tab" data-page="index.html"><span class="bi">⛑️</span>SST</a>
      <a href="llenar.html"    class="bb-tab" data-page="llenar.html"><span class="bi">📝</span>Llenar</a>
      <a href="dashboard.html" class="bb-tab" data-page="dashboard.html"><span class="bi">📊</span>Panel</a>
      <button type="button" class="bb-tab" onclick="skfToggleSidebar(true)"><span class="bi">⋯</span>Más</button>
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

  // Marca la pestaña activa de la barra inferior según la página actual.
  const _cur = (location.pathname.split('/').pop() || 'index.html');
  document.querySelectorAll('#skfBottomBar .bb-tab[data-page]').forEach(t => {
    const pg = t.getAttribute('data-page');
    if (pg === _cur || (pg === 'index.html' && (_cur === '' || _cur === 'index.html'))) t.classList.add('active');
  });

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
