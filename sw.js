// SEKaform — Service Worker
//
// Cachea el "app shell" (HTML/CSS/JS propios) para que la app cargue sin
// conexión, indispensable para un inspector trabajando en campo sin señal.
// Las llamadas a Supabase y al CDN de supabase-js viajan tal cual a la red
// — nunca se cachean — para no reproducir una escritura vieja; cuando no
// hay red simplemente fallan, y supabase-config.js ya las encola para
// reintentarlas al volver la conexión (ver SKF_QUEUE_KEY).

const CACHE_VERSION = 'skf-shell-v2';

const SHELL_ASSETS = [
  'index.html',
  'login.html',
  'plantillas.html',
  'digitalizador.html',
  'llenar.html',
  'asignaciones.html',
  'hallazgos.html',
  'dashboard.html',
  'styles.css',
  'field-types.js',
  'form-library.js',
  'sidebar.js',
  'supabase-config.js',
  'chart.min.js',
  'manifest.json',
  'icons/icon-192.png',
  'icons/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) => cache.addAll(SHELL_ASSETS))
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
  if (url.origin !== self.location.origin) return; // CDN/Supabase: directo a la red

  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE_VERSION).then((cache) => cache.put(req, copy));
          }
          return res;
        })
        .catch(() => caches.match('index.html'));
    })
  );
});
