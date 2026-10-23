// SEKaform — Service Worker
//
// Cachea el "app shell" (HTML/CSS/JS propios) para que la app cargue sin
// conexión, indispensable para un inspector trabajando en campo sin señal.
// Las llamadas a /api/ viajan tal cual a la red — nunca se cachean — para no
// reproducir una escritura vieja; cuando no hay red simplemente fallan, y
// skf-api.js ya las encola para reintentarlas al volver la conexión (ver
// SKF_QUEUE_KEY).

const CACHE_VERSION = 'skf-shell-v78';

const SHELL_ASSETS = [
  'index.html',
  'plantillas.html',
  'digitalizador.html',
  'llenar.html',
  'asignaciones.html',
  'programadas.html',
  'unidades.html',
  'hallazgos.html',
  'cumplimiento.html',
  'bienvenida.html',
  'turnos.html',
  'dashboard.html',
  'organizacion.html',
  'plan.html',
  'empresa.html',
  'personas.html',
  'clientes.html',
  'styles.css',
  'field-types.js',
  'form-library.js',
  'sidebar.js',
  'agenda.js',
  'planear.js',
  'portal-admin.js',
  'skf-api.js',
  'chart.min.js',
  'qrcode.js',
  'etiquetas.js',
  'demo-sembrar.js',
  'manifest.json',
  'icons/icon-192.png',
  'icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  // Se precachea asset por asset y SOLO respuestas directas (200, sin redirección).
  // Si la sesión no es válida, Flask redirige a /login: guardar esa respuesta
  // redirigida y servirla luego para una navegación hace que el navegador
  // falle con ERR_FAILED en todas las páginas.
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) =>
      Promise.all(SHELL_ASSETS.map((a) =>
        fetch(a, { cache: 'reload' })
          .then((res) => { if (res.ok && !res.redirected) return cache.put(a, res); })
          .catch(() => {})
      ))
    )
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // nunca interceptar escrituras (POST/PATCH a Supabase)
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // CDN externo: directo a la red
  // Nunca cachear la API ni las pantallas de sesión: servir una respuesta
  // vieja de /api/bootstrap o de /login deja al usuario viendo datos o un
  // estado de sesión que ya no son ciertos.
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/admin')
      || ['/login','/logout','/registro','/recuperar'].includes(url.pathname)) return;

  const guardar = (res) => {
    if (res.ok && !res.redirected) {
      const copy = res.clone();
      caches.open(CACHE_VERSION).then((cache) => cache.put(req, copy));
    }
    return res;
  };
  const cacheado = () => caches.match(req).then((c) => (c && !c.redirected ? c : null));

  // Páginas (HTML): red primero, para que la sesión y el despliegue vigente
  // siempre manden; la caché solo cubre el modo sin conexión.
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).then(guardar).catch(() =>
        cacheado().then((c) => c || caches.match('index.html')).then((c) => c || Response.error())
      )
    );
    return;
  }

  // Assets (JS/CSS/íconos): caché primero.
  event.respondWith(
    cacheado().then((c) => c || fetch(req).then(guardar)).catch(() => caches.match('index.html'))
  );
});

// ── Avisos push (app/push.py) ────────────────────────────────────────────
// Llegan cifrados; el navegador los descifra y aquí solo se muestran. Al tocar el
// aviso se abre (o se enfoca) la app en la página del aviso.
self.addEventListener('push', (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { cuerpo: event.data && event.data.text() }; }
  event.waitUntil(self.registration.showNotification(d.titulo || 'SEKaform', {
    body: d.cuerpo || '',
    icon: 'icons/icon-192.png',
    badge: 'icons/icon-192.png',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: (typeof d.url === 'string' && d.url.startsWith('/')) ? d.url : '/index.html' },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const destino = new URL((event.notification.data && event.notification.data.url) || '/index.html', self.location.origin).href;
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((ventanas) => {
    const abierta = ventanas.find((v) => v.url.startsWith(self.location.origin));
    if (abierta) return abierta.focus().then((v) => (v && v.navigate ? v.navigate(destino) : null)).catch(() => self.clients.openWindow(destino));
    return self.clients.openWindow(destino);
  }));
});
