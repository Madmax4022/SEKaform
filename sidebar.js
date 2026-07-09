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

const SKF_NAV_LINKS = [
  { href: 'plantillas.html',    ico: '📋', label: 'Plantillas' },
  { href: 'digitalizador.html', ico: '⚡', label: 'Crear formulario' },
  { href: 'llenar.html',        ico: '📝', label: 'Mis formularios' },
  { href: 'asignaciones.html',  ico: '👥', label: 'Asignaciones' },
  { href: 'hallazgos.html',     ico: '⚠️', label: 'Hallazgos' },
  { href: 'dashboard.html',     ico: '📊', label: 'Dashboard' }
];

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
  document.querySelectorAll('.skf-help.on').forEach(b => b.classList.remove('on'));
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
  const btn = e.target.closest('.skf-help');
  if (btn) {
    e.preventDefault(); e.stopPropagation();
    if (btn.classList.contains('on')) _skfCloseHelp();
    else _skfOpenHelp(btn);
    return;
  }
  if (!e.target.closest('#skfHelpPop')) _skfCloseHelp();
});

function skfRenderSidebar() {
  const current = (location.pathname.split('/').pop() || 'index.html');
  const links = SKF_NAV_LINKS.map(n =>
    `<a href="${n.href}" class="sidebar-link${current === n.href ? ' active' : ''}"><span class="sidebar-ico">${n.ico}</span>${n.label}</a>`
  ).join('');

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
    <div class="skf-bottom-bar" id="skfBottomBar">
      <a href="index.html" class="bb-btn">🏠 Inicio</a>
      <div class="bb-auth" id="bbAuthZone">
        <a class="bb-btn" href="login.html">☁ Iniciar sesión</a>
      </div>
      <button class="bb-btn" id="bbOfflineBtn" onclick="skfPrepareOffline()">📥 Sin conexión</button>
    </div>
  `;
  document.body.insertAdjacentHTML('afterbegin', html);

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
      const bar = document.getElementById('sidebarAuth');
      bar.innerHTML = `<span class="auth-chip">☁ ${_skfEsc(user.email)}</span><button class="auth-bell" id="skfBellBtn" onclick="skfToggleNotifications()">🔕</button><a class="auth-link" onclick="sbSignOut().then(()=>location.reload())">Salir</a>`;
      if (typeof skfUpdateBellIcon === 'function') skfUpdateBellIcon();
      if (typeof skfSubscribeCriticalAlerts === 'function') skfSubscribeCriticalAlerts(user);
    }).catch(() => {});
  }

  // Si el cache del SW ya existe, mostrar que ya está lista para sin conexión
  if ('caches' in window) {
    caches.has('skf-shell-v2').then(has => {
      if (has) {
        const btn = document.getElementById('bbOfflineBtn');
        if (btn) { btn.textContent = '✓ Lista sin conexión'; btn.classList.add('bb-offline-ready'); }
      }
    }).catch(() => {});
  }
}

skfRenderSidebar();
