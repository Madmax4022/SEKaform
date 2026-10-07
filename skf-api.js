// ─────────────────────────────────────────────────────────────────────────
//  Kanan Sentinel · SEKaform — capa de datos
//
//  Sustituye a supabase-config.js contra la API propia (Cloud Run + Cloud SQL).
//
//  Mantiene A PROPÓSITO los mismos nombres de función que la versión de
//  Supabase (sbLoadPlantillas, skfSyncOrQueue, skfReconcile…). Las 10 páginas
//  de la PWA hacen unas 46 llamadas a esta capa; reescribirlas una por una
//  habría sido mucho más arriesgado que reimplementar la interfaz por debajo.
//  Así el cambio de backend es una línea por página: el <script> que se carga.
//
//  Tres diferencias reales respecto a la versión anterior:
//
//  1. Los ids los pone el cliente como UUID y el servidor hace UPSERT sobre
//     ellos, así que reintentar la cola es inofensivo. Antes eran
//     `env_${Date.now()}`, que colisionan entre dispositivos.
//  2. La cola se vacía por LOTES en una sola petición.
//  3. Lo que el servidor rechaza por contenido NO se reintenta para siempre:
//     va a una bandeja de rechazados visible. Antes se descartaba en silencio
//     tras 5 intentos y el hallazgo se perdía sin que nadie se enterara.
// ─────────────────────────────────────────────────────────────────────────

const SKF_COLA = 'skf_cola_sync';
const SKF_RECHAZADOS = 'skf_rechazados';
const SKF_MAX_INTENTOS = 8;

// Varias páginas preguntan por esto antes de ofrecer algo que necesita nube
// (compartir un formulario, recuperar la contraseña). Con Supabase era «¿pegó
// alguien las claves en el archivo de configuración?» y podía ser false. Aquí
// el backend viaja con la aplicación: si esta página cargó, la API está del
// otro lado. Se conserva el nombre porque las páginas lo consultan tal cual.
const SKF_CONFIGURED = true;

// ── Utilidades ───────────────────────────────────────────────────────────

function skfUUID() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = crypto.getRandomValues(new Uint8Array(1))[0] % 16;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

function skfLeer(clave, defecto) {
  try { const v = localStorage.getItem(clave); return v === null ? defecto : JSON.parse(v); }
  catch { return defecto; }
}

function skfGuardar(clave, valor) {
  try { localStorage.setItem(clave, JSON.stringify(valor)); return true; }
  catch (e) {
    console.error('[SEKaform] localStorage lleno:', e);
    return false;
  }
}

// El token CSRF se pide al servidor porque las páginas de la PWA son HTML
// estático y no pueden llevarlo incrustado. Se cachea en memoria y se renueva
// solo si el servidor rechaza una escritura por token inválido.
let _csrf = null;

async function _asegurarCSRF() {
  if (_csrf) return _csrf;
  if (window.SKF_CSRF) { _csrf = window.SKF_CSRF; return _csrf; }
  try {
    const r = await fetch('/api/csrf', { credentials: 'same-origin' });
    _csrf = (await r.json()).token;
  } catch { _csrf = ''; }
  return _csrf;
}

function skfCSRF() { return _csrf || window.SKF_CSRF || ''; }

async function skfFetch(url, opciones = {}, _reintento = false) {
  if (opciones.method && opciones.method !== 'GET') await _asegurarCSRF();
  const r = await fetch(url, {
    ...opciones,
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-CSRFToken': skfCSRF(), ...(opciones.headers || {}) },
  });

  if (r.status === 401) {
    // Sesión vencida. NO se descarta la cola: se conserva para cuando vuelva a
    // entrar. Perder inspecciones por un token caducado sería el peor fallo
    // posible de este producto.
    window.dispatchEvent(new CustomEvent('skf:sin-sesion'));
    const e = new Error('Sesión expirada'); e.reintentable = true; throw e;
  }

  // Un 400 en una escritura suele ser el token caducado (la sesión se renovó
  // en otra pestaña). Se pide uno nuevo y se reintenta UNA vez.
  if (r.status === 400 && opciones.method && opciones.method !== 'GET' && !_reintento) {
    _csrf = null;
    await _asegurarCSRF();
    return skfFetch(url, opciones, true);
  }

  let cuerpo = null;
  try { cuerpo = await r.json(); } catch {}

  if (!r.ok) {
    const e = new Error(cuerpo?.error || `Error ${r.status}`);
    e.status = r.status;
    // 4xx: el servidor entendió y rechazó — reintentar no cambiará nada.
    // 5xx y fallos de red: puede funcionar más tarde.
    e.reintentable = r.status >= 500 || r.status === 429;
    throw e;
  }
  return cuerpo;
}

// ── Traducción de nombres de campo ───────────────────────────────────────
// Las páginas heredaron los nombres de Supabase (logo, foto, evidencia_cierre);
// el esquema nuevo usa logo_url / foto_url / evidencia_url, que describen mejor
// lo que guardan ahora que apuntan a objetos en Cloud Storage. Se traduce aquí
// en vez de tocar las páginas: un único sitio donde mirar si algo no cuadra.

function _mapCloud(fila, pares) {
  if (!fila) return fila;
  const o = { ...fila };
  for (const [pagina, columna] of pares) {
    if (columna in o) { o[pagina] = o[columna]; }
  }
  return o;
}

const _P_PLANTILLA = [['logo', 'logo_url']];
const _P_HALLAZGO  = [['foto', 'foto_url']];
const _P_ACCION    = [['evidencia_cierre', 'evidencia_url']];
const _P_ORG       = [['logo', 'logo_url'], ['turnosConfig', 'turnos_config']];

// ── Sesión y organización ────────────────────────────────────────────────

let _skfYo = null;

async function skfYo({ forzar = false } = {}) {
  if (_skfYo && !forzar) return _skfYo;
  try {
    const r = await skfFetch('/api/yo');
    _skfYo = r.autenticado ? r.usuario : null;
  } catch { _skfYo = null; }
  return _skfYo;
}

// Compatibilidad con la interfaz de Supabase: las páginas y sidebar.js esperan
// un objeto con .email.
async function sbGetUser() {
  const u = await skfYo();
  return u ? { id: u.id, email: u.email, nombre: u.nombre } : null;
}

async function skfGetOrg() {
  const u = await skfYo();
  return u && u.orgId ? { orgId: u.orgId, rol: u.rol } : null;
}

function skfClearOrg() { _skfYo = null; }

async function skfRol() { const u = await skfYo(); return u ? u.rol : null; }
async function skfPuedeEscribir() { const u = await skfYo(); return !!(u && u.puedeEscribir); }

async function sbSignOut() {
  skfClearOrg();
  try { await skfFetch('/logout', { method: 'POST' }); } catch {}
  location.href = '/login';
}

// El alta y el inicio de sesión son formularios servidos por Flask
// (/login, /registro): no se hacen desde JavaScript. Se dejan estas funciones
// por si alguna página las llamara, para que redirijan en vez de fallar.
async function sbSignIn() { location.href = '/login'; return { error: null }; }
async function sbSignUp() { location.href = '/registro'; return { error: null }; }

// ── Lectura ──────────────────────────────────────────────────────────────
// Devuelven null si no hay sesión o no hay red, exactamente como la versión de
// Supabase: skfReconcile interpreta null como "no toques la caché local".

let _bootstrapCache = null;

async function _bootstrap({ forzar = false } = {}) {
  if (_bootstrapCache && !forzar) return _bootstrapCache;
  try {
    _bootstrapCache = await skfFetch('/api/bootstrap');
    return _bootstrapCache;
  } catch { return null; }
}

async function sbLoadPlantillas() {
  const b = await _bootstrap();
  if (!b) return null;
  // Las del catálogo también llegan aquí: la organización solo ve las que un
  // super administrador le haya concedido, así que si están, son suyas de usar.
  return (b.plantillas || []).map(p => _mapCloud(p, _P_PLANTILLA));
}

async function sbLoadUnidades() {
  const b = await _bootstrap();
  return b ? (b.unidades || []) : null;
}

async function sbLoadAsignaciones() {
  const b = await _bootstrap();
  return b ? (b.asignaciones || []) : null;
}

async function sbLoadInspecciones() {
  const b = await _bootstrap();
  return b ? (b.programadas || []) : null;
}

async function sbLoadOrg() {
  const b = await _bootstrap();
  return b && b.organizacion ? _mapCloud(b.organizacion, _P_ORG) : null;
}

async function sbLoadEnvios(limite = 500) {
  try { return (await skfFetch(`/api/envios?limite=${limite}`)).envios || []; }
  catch { return null; }
}

let _hzCache = null;
async function _hallazgos() {
  try { _hzCache = await skfFetch('/api/hallazgos'); return _hzCache; }
  catch { return null; }
}

async function sbLoadHallazgos() {
  const r = await _hallazgos();
  return r ? (r.hallazgos || []).map(h => _mapCloud(h, _P_HALLAZGO)) : null;
}

async function sbLoadAccionesCorrectivas() {
  const r = _hzCache || await _hallazgos();
  return r ? (r.acciones || []).map(a => _mapCloud(a, _P_ACCION)) : null;
}

// Plantilla pública por token (enlace / QR), sin sesión.
async function sbLoadPublicPlantilla(token) {
  try {
    const p = await skfFetch(`/api/publico/plantilla/${encodeURIComponent(token)}`);
    return _mapCloud(p, _P_PLANTILLA);
  } catch { return null; }
}

// ── Paneles compartidos y cierre del ciclo ───────────────────────────────
// El panel se entrega a un cliente o a un jefe SIN cuenta, por un enlace no
// listado. Lo que viaja es una FOTO de los datos ya filtrados, no acceso en
// vivo. Las funciones de lectura y marcado NO llevan sesión a propósito: quien
// abre el enlace no tiene usuario y nunca va a tenerlo; el token es la
// credencial y el servidor lo valida contra la base en cada llamada.
//
// Todas devuelven false/null en lugar de lanzar: la página las llama detrás de
// un `typeof … === 'function'` y sigue funcionando contra localStorage si algo
// falla. Un panel que se abre a medias es mejor que uno que no se abre.

async function sbPublishPanel(token, titulo, snapshot) {
  try {
    await skfFetch('/api/panel', {
      method: 'POST',
      body: JSON.stringify({ token, titulo: titulo || null, snapshot }),
    });
    return true;
  } catch { return false; }
}

async function sbLoadPanel(token) {
  if (!token) return null;
  try { return await skfFetch(`/api/panel/${encodeURIComponent(token)}`); }
  catch { return null; }
}

// Lo ya reportado desde ESTE enlace (lo lee el propio enlace al abrirse).
async function sbPanelMarcas(token) {
  if (!token) return null;
  try { return (await skfFetch(`/api/panel/${encodeURIComponent(token)}/marcas`)).marcas || []; }
  catch { return null; }
}

// Todo lo reportado en la organización (lo lee el dueño en su panel).
async function sbLoadCorreccionesCampo() {
  try { return (await skfFetch('/api/correcciones')).correcciones || []; }
  catch { return null; }
}

// Marcar es un REPORTE del campo, no un cierre: quien ejecuta avisa de que ya
// lo atendió, y el dueño lo confirma después desde su panel. Por eso esto no
// toca el estado del hallazgo.
async function sbMarcarCorregido(token, hallazgoId, por, nota) {
  if (!token || !hallazgoId) return false;
  try {
    await skfFetch(`/api/panel/${encodeURIComponent(token)}/marca`, {
      method: 'POST',
      body: JSON.stringify({ hallazgoId, por: por || '', nota: nota || '' }),
    });
    return true;
  } catch { return false; }
}

async function sbDesmarcarCorregido(token, hallazgoId) {
  if (!token || !hallazgoId) return false;
  try {
    await skfFetch(`/api/panel/${encodeURIComponent(token)}/marca/${encodeURIComponent(hallazgoId)}`,
                   { method: 'DELETE' });
    return true;
  } catch { return false; }
}

// Cerrar y reabrir NO pasan por la cola sin conexión, y es deliberado: se hacen
// con el panel delante y con datos de la nube a la vista, no en campo sin
// señal. Encolarlos abriría la puerta a cerrar un hallazgo el martes contra un
// estado del lunes. Si falla, la página ya dejó su copia local y el siguiente
// refresco desde el servidor manda.
async function sbCerrarHallazgo(id, por) {
  if (!id) return false;
  try {
    await skfFetch(`/api/hallazgos/${encodeURIComponent(id)}/cerrar`, {
      method: 'POST', body: JSON.stringify({ por: por || null }),
    });
    _hzCache = null;
    return true;
  } catch { return false; }
}

async function sbReabrirHallazgo(id) {
  if (!id) return false;
  try {
    await skfFetch(`/api/hallazgos/${encodeURIComponent(id)}/reabrir`, { method: 'POST' });
    _hzCache = null;
    return true;
  } catch { return false; }
}

// ── Escritura: traducción de la forma local a la del servidor ────────────
// Las páginas trabajan con objetos en camelCase; la API espera los nombres de
// columna. Cada entrada de este mapa es el contrato de un tipo.

const _SALIDA = {
  plantilla: t => ({
    id: t.id, nombre: t.nombre, campos: t.campos, codigo: t.codigo || null,
    descripcion: t.descripcion || null, norma: t.norma || null,
    logo_url: t.logo || null, favorito: !!t.favorito, publica: !!t.publica,
    share_token: t.shareToken || null, correo_notificacion: t.correoNotificacion || null,
    // Ajustes de aviso por puntaje bajo (migración 008). Solo viajan si el formulario los tiene;
    // null = «predeterminado» y SÍ se envía, para poder volver al valor por defecto.
    ...('avisoUmbral' in t ? { aviso_umbral: t.avisoUmbral } : {}),
    ...('avisoMaxHora' in t ? { aviso_max_hora: t.avisoMaxHora } : {}),
  }),
  envio: e => ({
    id: e.id, plantilla_id: e.plantillaId || null,
    plantilla_nombre: e.plantillaNombre || '', plantilla_codigo: e.plantillaCodigo || '',
    unidad_id: e.unidadId || null, datos: e.datos || {}, estado: e.estado || 'enviado',
    llenado_por: e.llenadoPor || null, llenado_correo: e.llenadoCorreo || null,
    // Cuándo se llenó de verdad, que sin señal puede ser mucho antes de que
    // llegue. El servidor pone por su cuenta cuándo lo recibió.
    capturado_en: e.creadoEn || e.enviadoEn || null,
  }),
  hallazgo: h => ({
    id: h.id, envio_id: h.envioId || null, plantilla_id: h.plantillaId || null,
    plantilla_nombre: h.plantillaNombre || '', campo_id: h.campoId || null,
    campo_etiqueta: h.campoEtiqueta || null, origen: h.origen || 'manual',
    severidad: h.severidad || 'menor', descripcion: h.descripcion || null,
    foto_url: h.foto || null, unidad_id: h.unidadId || null,
    estado: h.estado || 'abierto', reportado_por: h.reportadoPor || null,
  }),
  accionCorrectiva: a => ({
    id: a.id, hallazgo_id: a.hallazgoId, responsable: a.responsable || null,
    correo: a.correo || null, fecha_limite: a.fechaLimite || null,
    estado: a.estado || 'pendiente', evidencia_url: a.evidenciaCierre || null,
    cerrado_en: a.cerradoEn || null,
  }),
  asignacion: a => ({
    id: a.id, plantilla_id: a.plantillaId || null,
    plantilla_nombre: a.plantillaNombre || '', unidad_id: a.unidadId || null,
    nombre: a.nombre, correo: a.correo || null,
  }),
  unidad: u => ({
    id: u.id, nombre: u.nombre, tipo: u.tipo || 'sede',
    padre_id: u.padreId || null, activa: u.activa !== false,
  }),
  inspeccion: i => ({
    id: i.id, plantilla_id: i.plantillaId || null, unidad_id: i.unidadId || null,
    nombre: i.nombre, frecuencia: i.frecuencia || 'mensual', proximo_en: i.proximoEn,
    responsable: i.responsable || null, correo: i.correo || null,
    activa: i.activa !== false, ultimo_completado: i.ultimoCompletado || null,
  }),
  // Cada campo viaja solo si se envió: guardar únicamente los turnos no debe
  // borrar el logo ni el país (que llegarían como null).
  org: o => {
    const r = {};
    if (o.nombre !== undefined) r.nombre = o.nombre;
    if ('logo' in o) r.logo_url = o.logo || null;
    if ('pais' in o) r.pais = o.pais || null;
    if (o.turnos_config !== undefined) r.turnos_config = o.turnos_config;
    return r;
  },

  deletePlantilla:  x => ({ id: x.id }),
  deleteUnidad:     x => ({ id: x.id }),
  deleteAsignacion: x => ({ id: x.id }),
  deleteInspeccion: x => ({ id: x.id }),
};

// Los envíos públicos van por su propia ruta, sin sesión.
const _PUBLICOS = {
  envioPublico: e => ['/api/publico/envio', {
    id: e.id, token: e.shareToken || window.SKF_SHARE_TOKEN || '',
    datos: e.datos || {}, llenadoPor: e.llenadoPor || null,
    llenadoCorreo: e.llenadoCorreo || null, capturadoEn: e.creadoEn || null,
  }],
  hallazgoPublico: h => ['/api/publico/hallazgo', {
    id: h.id, token: h.shareToken || window.SKF_SHARE_TOKEN || '',
    envioId: h.envioId || null, campoId: h.campoId || null,
    campoEtiqueta: h.campoEtiqueta || null, origen: h.origen || 'manual',
    severidad: h.severidad || 'menor', descripcion: h.descripcion || null,
    fotoUrl: h.foto || null, reportadoPor: h.reportadoPor || null,
  }],
};

// ── Cola sin conexión ────────────────────────────────────────────────────

function skfQueueGet() { return skfLeer(SKF_COLA, []); }
function skfQueueSet(q) { skfGuardar(SKF_COLA, q); skfUpdateSyncBadge(); }

function skfQueueAdd(tipo, payload) {
  const q = skfQueueGet();
  // Si el mismo registro ya estaba en cola (el inspector corrigió un campo
  // antes de recuperar señal), se reemplaza en vez de encolar dos versiones.
  const i = q.findIndex(o => o.tipo === tipo && o.datos?.id === payload.id);
  const op = { opId: skfUUID(), tipo, datos: payload, creadoEn: new Date().toISOString(), intentos: 0 };
  if (i >= 0) q[i] = op; else q.push(op);
  skfQueueSet(q);
}

function skfRechazar(tipo, datos, motivo) {
  const r = skfLeer(SKF_RECHAZADOS, []);
  r.push({ tipo, datos, motivo, fecha: new Date().toISOString() });
  skfGuardar(SKF_RECHAZADOS, r);
  console.warn('[SEKaform] Registro rechazado:', tipo, motivo);
}

async function _enviarUna(tipo, datos) {
  if (_PUBLICOS[tipo]) {
    const [url, cuerpo] = _PUBLICOS[tipo](datos);
    await skfFetch(url, { method: 'POST', body: JSON.stringify(cuerpo) });
    return true;
  }
  const mapear = _SALIDA[tipo];
  if (!mapear) { const e = new Error(`Tipo desconocido: ${tipo}`); e.reintentable = false; throw e; }

  const r = await skfFetch('/api/sync', {
    method: 'POST',
    body: JSON.stringify({ operaciones: [{ opId: skfUUID(), tipo, datos: mapear(datos) }] }),
  });
  const res = r.resultados?.[0];
  if (res?.ok) return true;
  const e = new Error(res?.error || 'No se pudo guardar');
  e.reintentable = res?.reintentable !== false;
  throw e;
}

/** Guarda contra el servidor; si no hay red, encola. Interfaz idéntica a la
 *  versión de Supabase: devuelve si quedó sincronizado. */
async function skfSyncOrQueue(tipo, payload) {
  if (!payload.id && !_PUBLICOS[tipo] && tipo !== 'org') payload.id = skfUUID();

  if (navigator.onLine) {
    try {
      await _enviarUna(tipo, payload);
      skfUpdateSyncBadge();
      return true;
    } catch (e) {
      if (e.reintentable === false) { skfRechazar(tipo, payload, e.message); skfUpdateSyncBadge(); return false; }
    }
  }
  skfQueueAdd(tipo, payload);
  return false;
}

let _sincronizando = false;

async function skfProcessQueue() {
  if (_sincronizando || !navigator.onLine) return;
  const cola = skfQueueGet();
  if (!cola.length) return;

  _sincronizando = true;
  skfUpdateSyncBadge(true);
  try {
    // Los públicos y la organización no caben en el lote de /api/sync: van uno
    // a uno por su propia ruta.
    const sueltos = cola.filter(o => _PUBLICOS[o.tipo]);
    const lote = cola.filter(o => !_PUBLICOS[o.tipo] && _SALIDA[o.tipo]);
    const restantes = [];

    for (const op of sueltos) {
      try { await _enviarUna(op.tipo, op.datos); }
      catch (e) {
        op.intentos = (op.intentos || 0) + 1;
        if (e.reintentable === false) skfRechazar(op.tipo, op.datos, e.message);
        else if (op.intentos < SKF_MAX_INTENTOS) restantes.push(op);
        else skfRechazar(op.tipo, op.datos, `Sin éxito tras ${SKF_MAX_INTENTOS} intentos`);
      }
    }

    if (lote.length) {
      // En tandas de 100: un lote enorme sobre una red que acaba de volver
      // tiene muchas papeletas de agotar el tiempo de espera y perderse entero.
      const tanda = lote.slice(0, 100);
      let porOp = new Map();
      try {
        const r = await skfFetch('/api/sync', {
          method: 'POST',
          body: JSON.stringify({
            operaciones: tanda.map(o => ({ opId: o.opId, tipo: o.tipo, datos: _SALIDA[o.tipo](o.datos) })),
          }),
        });
        porOp = new Map((r.resultados || []).map(x => [x.opId, x]));
      } catch {
        // Falló el lote entero (red): se conservan todas para el próximo intento.
        tanda.forEach(o => restantes.push(o));
      }

      for (const op of lote) {
        const res = porOp.get(op.opId);
        if (!res) { if (!restantes.includes(op) && tanda.includes(op) === false) restantes.push(op); continue; }
        if (res.ok) continue;
        op.intentos = (op.intentos || 0) + 1;
        if (res.reintentable === false) skfRechazar(op.tipo, op.datos, res.error);
        else if (op.intentos < SKF_MAX_INTENTOS) restantes.push(op);
        else skfRechazar(op.tipo, op.datos, `Sin éxito tras ${SKF_MAX_INTENTOS} intentos`);
      }
    }

    // Tipos que ya no existen: no se reintentan eternamente.
    cola.filter(o => !_PUBLICOS[o.tipo] && !_SALIDA[o.tipo])
        .forEach(o => skfRechazar(o.tipo, o.datos, 'Tipo desconocido'));

    skfQueueSet(restantes);
    if (restantes.length === 0) { _bootstrapCache = null; _hzCache = null; }
  } finally {
    _sincronizando = false;
    skfUpdateSyncBadge(false);
  }
}

// ── Reconciliación nube-como-verdad ──────────────────────────────────────
// Idéntica a la versión anterior: la nube gana, los borrados remotos se
// propagan, y lo creado sin conexión (que la nube nunca ha visto) se conserva.
function skfReconcile(key, cloudItems, normalizeFn) {
  if (cloudItems == null) {
    try { return JSON.parse(localStorage.getItem(key) || '[]'); } catch { return []; }
  }
  const norm = cloudItems.map(normalizeFn);
  const cloudIds = new Set(norm.map(x => x.id));
  const syncedKey = key + '__synced';
  let prevSynced, local;
  try { prevSynced = new Set(JSON.parse(localStorage.getItem(syncedKey) || '[]')); } catch { prevSynced = new Set(); }
  try { local = JSON.parse(localStorage.getItem(key) || '[]'); } catch { local = []; }
  const localOnly = local.filter(x => x && !cloudIds.has(x.id) && !prevSynced.has(x.id));
  const merged = [...norm, ...localOnly];
  localStorage.setItem(key, JSON.stringify(merged));
  localStorage.setItem(syncedKey, JSON.stringify([...cloudIds]));
  return merged;
}

// ── Indicador de estado ──────────────────────────────────────────────────

function skfUpdateSyncBadge(sincronizando) {
  const el = document.getElementById('skfSyncBar');
  if (!el) return;
  const n = skfQueueGet().length;
  const rech = skfLeer(SKF_RECHAZADOS, []).length;

  if (!navigator.onLine) {
    el.innerHTML = `📡 Sin conexión${n ? ` · ${n} pendiente${n !== 1 ? 's' : ''}` : ' · tu trabajo se guarda en el dispositivo'}`;
    el.className = 'skf-sync-bar offline'; el.style.display = 'flex';
  } else if (sincronizando) {
    el.innerHTML = '↻ Sincronizando…';
    el.className = 'skf-sync-bar syncing'; el.style.display = 'flex';
  } else if (n) {
    el.innerHTML = `☁ ${n} pendiente${n !== 1 ? 's' : ''} de sincronizar`;
    el.className = 'skf-sync-bar syncing'; el.style.display = 'flex';
  } else if (rech) {
    el.innerHTML = `⚠️ ${rech} registro${rech !== 1 ? 's' : ''} no aceptado${rech !== 1 ? 's' : ''} · <a href="#" onclick="skfVerRechazados();return false" style="color:inherit;text-decoration:underline">revisar</a>`;
    el.className = 'skf-sync-bar syncing'; el.style.display = 'flex';
  } else {
    el.style.display = 'none';
  }
}

function skfVerRechazados() {
  const r = skfLeer(SKF_RECHAZADOS, []);
  if (!r.length) return alert('No hay registros rechazados.');
  if (confirm('Registros que el servidor no aceptó:\n\n' +
      r.map(x => `• ${x.tipo} — ${x.motivo}`).join('\n') +
      '\n\n¿Descartarlos? (Aceptar = descartar, Cancelar = conservar)')) {
    localStorage.removeItem(SKF_RECHAZADOS);
    skfUpdateSyncBadge();
  }
}

// ── Alertas de hallazgos críticos ────────────────────────────────────────
// Supabase Realtime mantenía un WebSocket abierto. Aquí se pregunta cada
// minuto: para un aviso de seguridad esa latencia sobra, y en un móvil en
// campo cada radio despierta menos.

function _skfHtmlEsc(s) { return String(s || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;'); }

function skfShowCriticalToast(h) {
  let el = document.getElementById('skfCriticalToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'skfCriticalToast'; el.className = 'skf-critical-toast';
    document.body.appendChild(el);
  }
  el.innerHTML = `
    <span class="skf-critical-toast-ico">🔴</span>
    <div class="skf-critical-toast-body">
      <strong>Hallazgo crítico</strong>
      <span>${_skfHtmlEsc(h.plantilla_nombre || '')}${h.campo_etiqueta ? ' · ' + _skfHtmlEsc(h.campo_etiqueta) : ''}</span>
    </div>
    <a class="skf-critical-toast-link" href="hallazgos.html">Ver →</a>
    <button class="skf-critical-toast-close" onclick="this.closest('.skf-critical-toast').classList.remove('show')" aria-label="Cerrar">✕</button>`;
  el.classList.add('show');
  clearTimeout(el._skfTimer);
  el._skfTimer = setTimeout(() => el.classList.remove('show'), 12000);
}

function skfNotifyCritical(h) {
  skfShowCriticalToast(h);
  window.dispatchEvent(new CustomEvent('skf:hallazgo-critico', { detail: h }));
  if (typeof Notification !== 'undefined' && Notification.permission === 'granted' && document.hidden) {
    try {
      const n = new Notification('🔴 Hallazgo crítico — Kanan Sentinel', {
        body: (h.plantilla_nombre || '') + (h.campo_etiqueta ? ' · ' + h.campo_etiqueta : ''),
        tag: 'skf-critico-' + h.id,
      });
      n.onclick = () => { window.focus(); location.href = 'hallazgos.html'; };
    } catch {}
  }
}

function skfNotificationsEnabled() {
  return typeof Notification !== 'undefined' && Notification.permission === 'granted';
}

async function skfToggleNotifications() {
  if (typeof Notification === 'undefined') return;
  if (Notification.permission === 'granted') {
    alert('Las alertas del navegador ya están activas. Para desactivarlas, hazlo desde la configuración de notificaciones de tu navegador.');
    return;
  }
  await Notification.requestPermission();
  skfUpdateBellIcon();
}

function skfUpdateBellIcon() {
  const btn = document.getElementById('skfBellBtn');
  if (!btn) return;
  const on = skfNotificationsEnabled();
  btn.textContent = on ? '🔔' : '🔕';
  btn.classList.toggle('on', on);
  btn.title = on
    ? 'Alertas activas — los hallazgos críticos te avisan al instante'
    : 'Activar notificaciones del navegador para hallazgos críticos';
}

let _alertasDesde = new Date().toISOString();
let _alertasTimer = null;

async function skfSubscribeCriticalAlerts() {
  if (_alertasTimer) return;
  const revisar = async () => {
    if (!navigator.onLine) return;
    try {
      const r = await skfFetch(`/api/alertas?desde=${encodeURIComponent(_alertasDesde)}`);
      (r.alertas || []).forEach(h => {
        skfNotifyCritical(h);
        if (h.creado_en > _alertasDesde) _alertasDesde = h.creado_en;
      });
    } catch {}
  };
  _alertasTimer = setInterval(revisar, 60000);
  revisar();
}

// ── Arranque ─────────────────────────────────────────────────────────────

window.addEventListener('online', () => { skfUpdateSyncBadge(); skfProcessQueue(); });
window.addEventListener('offline', () => skfUpdateSyncBadge());

document.addEventListener('DOMContentLoaded', () => {
  skfUpdateSyncBadge();
  if (navigator.onLine) skfProcessQueue();
});


// ══════════════════════════════════════════════════════════════════════════
//  MODO EJEMPLO — ver la app "llena" antes de capturar datos reales
//
//  Garantía central: NADA de lo de ejemplo puede llegar a la nube ni a la
//  Carpeta de evidencia (sería evidencia falsa ante un inspector). Por eso:
//   1. Al entrar se respalda todo skf_* local y se reemplaza por el ejemplo.
//   2. Durante el modo, skfSyncOrQueue/skfProcessQueue no envían nada.
//   3. Al salir se borra lo de ejemplo y se restaura el respaldo tal cual.
// ══════════════════════════════════════════════════════════════════════════
const SKF_DEMO_FLAG = 'skf_demo';
const SKF_DEMO_BACKUP = 'skf_demo_backup';
function skfDemoActivo() { try { return localStorage.getItem(SKF_DEMO_FLAG) === '1'; } catch (e) { return false; } }

function _skfDemoClaves() {
  const keep = ['skf_sidebar_collapsed', SKF_DEMO_FLAG, SKF_DEMO_BACKUP, 'skf_org'];
  const out = [];
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (k && k.indexOf('skf_') === 0 && keep.indexOf(k) === -1 && k.indexOf('skf_perfil:') !== 0) out.push(k);
  }
  return out;
}

function _skfDemoDatos() {
  const DIA = 86400000, hace = d => new Date(Date.now() - d * DIA).toISOString();
  const futuro = d => new Date(Date.now() + d * DIA).toISOString().slice(0, 10);
  const pasado = d => new Date(Date.now() - d * DIA).toISOString().slice(0, 10);
  const F = {
    lista:   { id: 'demo-f1', nombre: 'Lista de Verificación SST', n: 10 },
    epp:     { id: 'demo-f2', nombre: 'Entrega de Elementos de Protección Personal (EPP)', n: 12 },
    asist:   { id: 'demo-f3', nombre: 'Registro de Asistencia a Capacitación', n: 8 },
    acta:    { id: 'demo-f4', nombre: 'Acta de Reunión — COPASST', n: 15 },
    acto:    { id: 'demo-f5', nombre: 'Reporte de Acto y Condición Insegura', n: 10 },
    botiquin:{ id: 'demo-f6', nombre: 'Inspección de Botiquín y Brigada de Emergencias', n: 14 },
  };
  const plantillas = Object.keys(F).map((k, i) => ({
    id: F[k].id, nombre: F[k].nombre, codigo: 'FORM-' + String(i + 1).padStart(4, '0'), publica: false,
    campos: Array.from({ length: F[k].n }, (_, c) => ({ id: 'c' + c, tipo: 'texto', etiqueta: 'Campo ' + (c + 1) })),
    creado_en: hace(120), creadoEn: hace(120), actualizado_en: hace(10), actualizadoEn: hace(10),
  }));
  // [formulario, hace cuántos días, quién, sede]. Cubre principios al día, un atrasado
  // (capacitación) y deja otros pendientes, para que el mapa muestre de todo un poco.
  const filas = [
    ['lista', 3, 'Juan Pérez', 'demo-u1'], ['lista', 18, 'Juan Pérez', 'demo-u1'], ['lista', 40, 'María López', 'demo-u2'], ['lista', 75, 'Juan Pérez', 'demo-u1'],
    ['epp', 7, 'María López', 'demo-u2'], ['epp', 30, 'María López', 'demo-u2'], ['epp', 90, 'Juan Pérez', 'demo-u1'],
    ['asist', 200, 'Carlos Ruiz', 'demo-u1'], ['asist', 260, 'Carlos Ruiz', 'demo-u1'],
    ['acta', 35, 'Ana Gómez', 'demo-u1'],
    ['acto', 9, 'Pedro Díaz', 'demo-u2'], ['acto', 22, 'Pedro Díaz', 'demo-u2'],
    ['botiquin', 12, 'María López', 'demo-u2'],
  ];
  const envios = filas.map((r, i) => ({
    id: 'demo-e' + (i + 1), numero: i + 1, plantilla_id: F[r[0]].id, plantillaId: F[r[0]].id,
    plantilla_nombre: F[r[0]].nombre, plantillaNombre: F[r[0]].nombre, plantillaCodigo: '', plantilla_codigo: '',
    unidad_id: r[3], unidadId: r[3], estado: 'enviado', datos: {},
    llenado_por: r[2], llenadoPor: r[2], llenado_correo: null, llenadoCorreo: null,
    creado_en: hace(r[1]), creadoEn: hace(r[1]), enviado_en: hace(r[1]), enviadoEn: hace(r[1]),
  }));
  const hz = (id, sev, desc, campo, dias, estado, uid) => ({
    id, envio_id: 'demo-e1', envioId: 'demo-e1', plantilla_id: F.lista.id, plantillaId: F.lista.id,
    plantilla_nombre: F.lista.nombre, plantillaNombre: F.lista.nombre, campo_etiqueta: campo, campoEtiqueta: campo,
    origen: 'formulario', severidad: sev, descripcion: desc, estado, unidad_id: uid, unidadId: uid,
    reportado_por: 'Juan Pérez', reportadoPor: 'Juan Pérez', creado_en: hace(dias), creadoEn: hace(dias),
  });
  const hallazgos = [
    hz('demo-h1', 'critico', 'Extintor de la bodega con la recarga vencida.', 'Extintor cercano y vigente', 6, 'abierto', 'demo-u1'),
    hz('demo-h2', 'mayor', 'Falta señalización de la salida de emergencia en el segundo piso.', 'Señalización de salida', 14, 'abierto', 'demo-u2'),
    hz('demo-h3', 'menor', 'Botiquín sin gasas suficientes (ya repuestas).', 'Vendas y gasas', 40, 'cerrado', 'demo-u2'),
  ];
  const acciones = [
    { id: 'demo-a1', hallazgo_id: 'demo-h1', hallazgoId: 'demo-h1', responsable: 'Carlos Ruiz', correo: null, fecha_limite: pasado(2), fechaLimite: pasado(2), estado: 'pendiente', creado_en: hace(5), creadoEn: hace(5) },
    { id: 'demo-a2', hallazgo_id: 'demo-h2', hallazgoId: 'demo-h2', responsable: 'Ana Gómez', correo: null, fecha_limite: futuro(10), fechaLimite: futuro(10), estado: 'en_progreso', creado_en: hace(12), creadoEn: hace(12) },
  ];
  const unidades = [
    { id: 'demo-u1', nombre: 'Sede Principal (ejemplo)', tipo: 'sede', padre_id: null, padreId: null, creado_en: hace(100), creadoEn: hace(100) },
    { id: 'demo-u2', nombre: 'Bodega Norte (ejemplo)', tipo: 'sede', padre_id: null, padreId: null, creado_en: hace(100), creadoEn: hace(100) },
  ];
  return { plantillas, envios, hallazgos, acciones, unidades };
}

function skfDemoEntrar() {
  if (skfDemoActivo()) return true;
  try {
    const backup = {};
    _skfDemoClaves().forEach(k => { backup[k] = localStorage.getItem(k); });
    localStorage.setItem(SKF_DEMO_BACKUP, JSON.stringify(backup));   // si no cabe, falla ANTES de tocar nada
    Object.keys(backup).forEach(k => localStorage.removeItem(k));
    const d = _skfDemoDatos();
    localStorage.setItem('skf_plantillas', JSON.stringify(d.plantillas));
    localStorage.setItem('skf_envios', JSON.stringify(d.envios));
    localStorage.setItem('skf_hallazgos', JSON.stringify(d.hallazgos));
    localStorage.setItem('skf_acciones_correctivas', JSON.stringify(d.acciones));
    localStorage.setItem('skf_unidades', JSON.stringify(d.unidades));
    localStorage.setItem(SKF_DEMO_FLAG, '1');
    return true;
  } catch (e) {
    try { localStorage.removeItem(SKF_DEMO_BACKUP); } catch (e2) {}
    return false;
  }
}

function skfDemoSalir() {
  try {
    _skfDemoClaves().forEach(k => localStorage.removeItem(k));        // fuera todo lo de ejemplo
    const backup = JSON.parse(localStorage.getItem(SKF_DEMO_BACKUP) || '{}');
    Object.keys(backup).forEach(k => { if (backup[k] != null) localStorage.setItem(k, backup[k]); });
    localStorage.removeItem(SKF_DEMO_BACKUP);
    localStorage.removeItem(SKF_DEMO_FLAG);
  } catch (e) {}
  location.href = 'index.html';
}

if (skfDemoActivo()) {
  const _d = _skfDemoDatos();
  // Lecturas: siempre el ejemplo. Escrituras: ninguna sale del dispositivo.
  sbLoadPlantillas = async () => _d.plantillas;
  sbLoadEnvios = async () => _d.envios;
  sbLoadInspecciones = async () => _d.envios;
  sbLoadHallazgos = async () => _d.hallazgos;
  sbLoadAccionesCorrectivas = async () => _d.acciones;
  sbLoadUnidades = async () => _d.unidades;
  sbLoadAsignaciones = async () => [];
  skfSyncOrQueue = async () => true;
  skfProcessQueue = async () => {};
}

setInterval(() => { if (navigator.onLine) skfProcessQueue(); }, 60000);

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {}));
}
