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
  { href: 'digitalizador.html', ico: '⚡', label: 'Digitalizar' },
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
  `;
  document.body.insertAdjacentHTML('afterbegin', html);

  if (typeof sbGetUser === 'function') {
    sbGetUser().then(user => {
      if (!user) return;
      const bar = document.getElementById('sidebarAuth');
      bar.innerHTML = `<span class="auth-chip">☁ ${_skfEsc(user.email)}</span><a class="auth-link" onclick="sbSignOut().then(()=>location.reload())">Salir</a>`;
    }).catch(() => {});
  }
}

skfRenderSidebar();
