// ─────────────────────────────────────────────────────────────
//  SEKaform — Supabase Configuration (modelo multi-organización)
//
//  Los datos pertenecen a una ORGANIZACIÓN, no a un usuario. Cada persona es
//  MIEMBRO de una organización con un ROL (dueño/admin/editor/lector). El
//  cliente resuelve la organización activa con skfGetOrg() y todas las
//  funciones de datos quedan scoped a esa organización. La nube es la fuente
//  de verdad; localStorage es caché/resiliencia sin conexión.
//
//  1. Create a project at https://supabase.com
//  2. Settings → API: copia URL y anon key
//  3. Corre supabase-schema.sql en el SQL editor
// ─────────────────────────────────────────────────────────────
const SKF_SUPABASE_URL = 'https://bdfppxvinyoszcfsvbcx.supabase.co';
const SKF_SUPABASE_KEY = 'sb_publishable_fet4FKrvN60SoZtZa_2ylg_2PkhWIWU';
const SKF_CONFIGURED   = !SKF_SUPABASE_URL.startsWith('YOUR_');

let _sb = null;

async function getSB() {
  if (!SKF_CONFIGURED) return null;
  if (_sb) return _sb;
  if (!window.supabase) {
    await new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.onload = resolve;
      s.onerror = () => reject(new Error('No se pudo cargar Supabase JS'));
      document.head.appendChild(s);
    });
  }
  _sb = window.supabase.createClient(SKF_SUPABASE_URL, SKF_SUPABASE_KEY);
  return _sb;
}

async function sbGetUser() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const { data: { user } } = await sb.auth.getUser();
    return user || null;
  } catch { return null; }
}

async function sbSignIn(email, password) {
  const sb = await getSB();
  return sb.auth.signInWithPassword({ email, password });
}

async function sbSignUp(email, password) {
  const sb = await getSB();
  return sb.auth.signUp({ email, password });
}

async function sbSignOut() {
  skfClearOrg();
  const sb = await getSB();
  if (sb) await sb.auth.signOut();
}

// ─────────────────────────────────────────────────────────────
//  Contexto de organización
//
//  Resuelve (y cachea) la organización activa del usuario y su rol. Al
//  registrarse, un trigger en el servidor ya crea la organización y deja al
//  usuario como "dueño"; skf_asegurar_org() es la red de seguridad idempotente
//  para cuentas que no la tengan aún. Todas las funciones de datos usan esto
//  para saber a qué organización pertenecen los registros que leen/escriben.
// ─────────────────────────────────────────────────────────────
let _skfOrg = null; // { orgId, rol }

async function skfGetOrg() {
  if (_skfOrg) return _skfOrg;
  const sb = await getSB();
  if (!sb) return null;
  const user = await sbGetUser();
  if (!user) return null;
  try {
    // Idempotente: devuelve la organización existente o la crea.
    const { data: oid, error } = await sb.rpc('skf_asegurar_org');
    if (!error && oid) {
      const { data: m } = await sb.from('miembros')
        .select('rol').eq('org_id', oid).eq('user_id', user.id).maybeSingle();
      _skfOrg = { orgId: oid, rol: m ? m.rol : 'editor' };
      return _skfOrg;
    }
    // Respaldo si la RPC no estuviera disponible: lectura directa.
    const { data } = await sb.from('miembros')
      .select('org_id, rol').eq('user_id', user.id)
      .order('creado_en', { ascending: true }).limit(1).maybeSingle();
    if (data) { _skfOrg = { orgId: data.org_id, rol: data.rol }; return _skfOrg; }
  } catch (e) { console.warn('[SEKaform] skfGetOrg:', e.message); }
  return null;
}

function skfClearOrg() { _skfOrg = null; }

// Rol del usuario en su organización: 'dueno' | 'admin' | 'editor' | 'lector'.
// Lo consumen las páginas para mostrar/ocultar acciones de escritura.
async function skfRol() { const o = await skfGetOrg(); return o ? o.rol : null; }
async function skfPuedeEscribir() {
  const r = await skfRol();
  return r === 'dueno' || r === 'admin' || r === 'editor';
}

// ─────────────────────────────────────────────────────────────
//  Reconciliación nube-como-verdad
//
//  La nube es la fuente de verdad; localStorage es caché. Al reconciliar:
//   · la nube gana en conflictos (ítem con el mismo id → se queda el de la nube),
//   · los borrados remotos se propagan (un ítem que ANTES estaba en la nube y
//     ya no está, se elimina del caché local),
//   · los ítems locales que la nube nunca ha visto (creados sin conexión, aún
//     en la cola de sincronización) se conservan — nunca se pierde un registro
//     de campo sin sincronizar.
//
//  Guardar el set de ids vistos en la nube (`<key>__synced`) es lo que permite
//  distinguir "borrado remoto" (antes estaba) de "creado local" (nunca estuvo)
//  sin arriesgar datos. Con cloudItems === null (sin conexión / sin sesión /
//  error) no se toca nada: se devuelve el caché local intacto.
// ─────────────────────────────────────────────────────────────
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

async function sbSyncPlantilla(tmpl) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    const org = await skfGetOrg();
    if (!org) return false;
    const user = await sbGetUser();
    const payload = {
      id: tmpl.id,
      org_id: org.orgId,
      autor_id: user ? user.id : null,
      nombre: tmpl.nombre,
      campos: tmpl.campos,
      codigo: tmpl.codigo || null,
      descripcion: tmpl.descripcion || null,
      logo: tmpl.logo || null,
      favorito: tmpl.favorito || false,
      publica: tmpl.publica || false,
      share_token: tmpl.shareToken || null,
      correo_notificacion: tmpl.correoNotificacion || null,
      creado_en: tmpl.creadoEn || new Date().toISOString(),
      actualizado_en: new Date().toISOString()
    };
    const { error } = await sb.from('plantillas').upsert(payload);
    if (error) { console.warn('[SEKaform] Sync plantilla:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Sync plantilla error:', e.message); return false; }
}

async function sbDeletePlantilla(id) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    if (!(await skfGetOrg())) return false;
    // RLS limita el borrado a la organización del usuario; basta el id.
    const { error } = await sb.from('plantillas').delete().eq('id', id);
    if (error) { console.warn('[SEKaform] Delete plantilla:', error.message); return false; }
    return true;
  } catch(e) { console.warn('[SEKaform] Delete plantilla error:', e.message); return false; }
}

async function sbSyncEnvio(envio) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    const org = await skfGetOrg();
    if (!org) return false;
    const user = await sbGetUser();
    const payload = {
      id: envio.id,
      org_id: org.orgId,                       // el trigger lo reafirma desde la plantilla
      autor_id: user ? user.id : null,
      numero: envio.numero || null,
      plantilla_id: envio.plantillaId || null,
      plantilla_nombre: envio.plantillaNombre || '',
      plantilla_codigo: envio.plantillaCodigo || '',
      unidad_id: envio.unidadId || null,       // sede/área/contratista
      datos: envio.datos || {},
      estado: envio.estado || 'enviado',
      llenado_por: envio.llenadoPor || null,
      llenado_correo: envio.llenadoCorreo || null,
      creado_en: envio.creadoEn || new Date().toISOString(),
      enviado_en: envio.enviadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('envios').upsert(payload);
    if (error) { console.warn('[SEKaform] Sync envío:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Sync envío error:', e.message); return false; }
}

// Carga una plantilla pública por su share_token, sin necesitar sesión
// (usada por llenar.html cuando alguien abre un link/QR ?pub=<token>). Solo
// selecciona columnas públicas: org_id/autor_id/correo_notificacion quedan
// además revocados a nivel de columna en el esquema (segunda capa de defensa).
async function sbLoadPublicPlantilla(token) {
  try {
    const sb = await getSB();
    if (!sb || !token) return null;
    const { data, error } = await sb.from('plantillas')
      .select('id, nombre, campos, codigo, descripcion, logo, publica, share_token')
      .eq('share_token', token).eq('publica', true).maybeSingle();
    if (error || !data) return null;
    return data;
  } catch { return null; }
}

// Envía un formulario sin sesión. No viaja org_id: el trigger envios_asignar_org
// lo fija desde la organización dueña de la plantilla, así el dato cae en el
// dataset correcto sin que un anónimo pueda inyectar en otra organización.
async function sbSubmitPublicEnvio(envio) {
  try {
    const sb = await getSB();
    if (!sb) return { error: 'sin conexión' };
    const payload = {
      id: envio.id,
      numero: null, // el servidor lo asigna (el visitante anónimo no lee envíos previos)
      plantilla_id: envio.plantillaId || null,
      plantilla_nombre: envio.plantillaNombre || '',
      plantilla_codigo: envio.plantillaCodigo || '',
      datos: envio.datos || {},
      estado: envio.estado || 'enviado',
      llenado_por: envio.llenadoPor || null,
      llenado_correo: envio.llenadoCorreo || null,
      creado_en: envio.creadoEn || new Date().toISOString(),
      enviado_en: envio.enviadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('envios').insert(payload);
    if (error) { console.warn('[SEKaform] Envío público:', error.message); return { error: error.message }; }
    return { ok: true };
  } catch (e) { console.warn('[SEKaform] Envío público error:', e.message); return { error: e.message }; }
}

// Sincroniza un hallazgo (automático o manual) hacia la organización dueña de
// la plantilla.
async function sbSyncHallazgo(h) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    const org = await skfGetOrg();
    if (!org) return false;
    const payload = {
      id: h.id,
      org_id: org.orgId,
      envio_id: h.envioId || null,
      plantilla_id: h.plantillaId || null,
      plantilla_nombre: h.plantillaNombre || '',
      campo_id: h.campoId || null,
      campo_etiqueta: h.campoEtiqueta || null,
      origen: h.origen || 'manual',
      severidad: h.severidad || 'menor',
      descripcion: h.descripcion || null,
      foto: h.foto || null,
      unidad_id: h.unidadId || null,
      estado: h.estado || 'abierto',
      reportado_por: h.reportadoPor || null
    };
    const { error } = await sb.from('hallazgos').upsert(payload);
    if (error) { console.warn('[SEKaform] Sync hallazgo:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Sync hallazgo error:', e.message); return false; }
}

// Igual que sbSubmitPublicEnvio: un visitante sin cuenta puede reportar un
// hallazgo desde un link público — el trigger hallazgos_asignar_org fija el
// org_id real.
async function sbSubmitPublicHallazgo(h) {
  try {
    const sb = await getSB();
    if (!sb) return { error: 'sin conexión' };
    const payload = {
      id: h.id,
      envio_id: h.envioId || null,
      plantilla_id: h.plantillaId || null,
      plantilla_nombre: h.plantillaNombre || '',
      campo_id: h.campoId || null,
      campo_etiqueta: h.campoEtiqueta || null,
      origen: h.origen || 'manual',
      severidad: h.severidad || 'menor',
      descripcion: h.descripcion || null,
      foto: h.foto || null,
      estado: 'abierto',
      reportado_por: h.reportadoPor || null
    };
    const { error } = await sb.from('hallazgos').insert(payload);
    if (error) { console.warn('[SEKaform] Hallazgo público:', error.message); return { error: error.message }; }
    return { ok: true };
  } catch (e) { console.warn('[SEKaform] Hallazgo público error:', e.message); return { error: e.message }; }
}

async function sbLoadHallazgos() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const org = await skfGetOrg();
    if (!org) return null;
    const { data, error } = await sb.from('hallazgos')
      .select('*').eq('org_id', org.orgId).order('creado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

// Acción correctiva (CAPA) — quién debe resolver un hallazgo y para cuándo.
async function sbSyncAccionCorrectiva(ac) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    const org = await skfGetOrg();
    if (!org) return false;
    const payload = {
      id: ac.id,
      org_id: org.orgId,
      hallazgo_id: ac.hallazgoId,
      responsable: ac.responsable || null,
      correo: ac.correo || null,
      fecha_limite: ac.fechaLimite || null,
      estado: ac.estado || 'pendiente',
      evidencia_cierre: ac.evidenciaCierre || null,
      cerrado_en: ac.cerradoEn || null
    };
    const { error } = await sb.from('acciones_correctivas').upsert(payload);
    if (error) { console.warn('[SEKaform] Sync acción correctiva:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Sync acción correctiva error:', e.message); return false; }
}

async function sbLoadAccionesCorrectivas() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const org = await skfGetOrg();
    if (!org) return null;
    const { data, error } = await sb.from('acciones_correctivas')
      .select('*').eq('org_id', org.orgId).order('creado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

async function sbLoadPlantillas() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const org = await skfGetOrg();
    if (!org) return null;
    const { data, error } = await sb.from('plantillas')
      .select('*').eq('org_id', org.orgId).order('actualizado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

async function sbLoadEnvios(limit = 500) {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const org = await skfGetOrg();
    if (!org) return null;
    const { data, error } = await sb.from('envios')
      .select('*').eq('org_id', org.orgId)
      .order('enviado_en', { ascending: false }).limit(limit);
    if (error) return null;
    return data;
  } catch { return null; }
}

// ── Unidades (sede/área/contratista) — dimensión de reporte ─────────────
async function sbSyncUnidad(u) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    const org = await skfGetOrg();
    if (!org) return false;
    const payload = {
      id: u.id,
      org_id: org.orgId,
      nombre: u.nombre,
      tipo: u.tipo || 'sede',
      padre_id: u.padreId || null,
      creado_en: u.creadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('unidades').upsert(payload);
    if (error) { console.warn('[SEKaform] Sync unidad:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Sync unidad error:', e.message); return false; }
}

async function sbDeleteUnidad(id) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    if (!(await skfGetOrg())) return false;
    const { error } = await sb.from('unidades').delete().eq('id', id);
    if (error) { console.warn('[SEKaform] Delete unidad:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Delete unidad error:', e.message); return false; }
}

async function sbLoadUnidades() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const org = await skfGetOrg();
    if (!org) return null;
    const { data, error } = await sb.from('unidades')
      .select('*').eq('org_id', org.orgId).order('creado_en', { ascending: true });
    if (error) return null;
    return data;
  } catch { return null; }
}

// ── Asignaciones (panel de administración: a quién se le pidió llenar
// cada plantilla, para calcular cumplimiento) ──────────────────────────
async function sbSyncAsignacion(a) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    const org = await skfGetOrg();
    if (!org) return false;
    const payload = {
      id: a.id,
      org_id: org.orgId,
      plantilla_id: a.plantillaId || null,
      plantilla_nombre: a.plantillaNombre || '',
      unidad_id: a.unidadId || null,
      nombre: a.nombre,
      correo: a.correo || null,
      creado_en: a.creadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('asignaciones').upsert(payload);
    if (error) { console.warn('[SEKaform] Sync asignación:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Sync asignación error:', e.message); return false; }
}

async function sbDeleteAsignacion(id) {
  try {
    const sb = await getSB();
    if (!sb) return false;
    if (!(await skfGetOrg())) return false;
    const { error } = await sb.from('asignaciones').delete().eq('id', id);
    if (error) { console.warn('[SEKaform] Delete asignación:', error.message); return false; }
    return true;
  } catch (e) { console.warn('[SEKaform] Delete asignación error:', e.message); return false; }
}

async function sbLoadAsignaciones() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const org = await skfGetOrg();
    if (!org) return null;
    const { data, error } = await sb.from('asignaciones')
      .select('*').eq('org_id', org.orgId).order('creado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

// Show "cloud connected" indicator on pages that include this script
document.addEventListener('DOMContentLoaded', async () => {
  const badge = document.getElementById('skfCloudBadge');
  if (!badge || !SKF_CONFIGURED) return;
  const user = await sbGetUser();
  if (user) {
    badge.textContent = '☁ ' + (user.email || 'Conectado');
    badge.style.color = 'var(--ok, #1abc9c)';
  } else {
    badge.textContent = '☁ Sin sesión';
    badge.href = 'login.html';
    badge.style.color = 'var(--mut, #94a3b8)';
  }
  badge.style.display = 'inline-block';
});

// ─────────────────────────────────────────────────────────────
//  Fase 3: alertas en tiempo real de hallazgos críticos
//
//  Un hallazgo crítico (extintor vencido, fuga, riesgo eléctrico…) no
//  debe esperar a que alguien abra el dashboard. Cualquier sesión
//  abierta de un miembro de la organización se suscribe vía Supabase
//  Realtime (WebSocket) a los INSERT en "hallazgos"; al llegar uno con
//  severidad "critico" se muestra un aviso dentro de la app y, si el
//  usuario activó el campanazo, una notificación nativa del navegador
//  (llega aunque esté en otra pestaña).
// ─────────────────────────────────────────────────────────────
function _skfHtmlEsc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;'); }

function skfShowCriticalToast(h) {
  let el = document.getElementById('skfCriticalToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'skfCriticalToast';
    el.className = 'skf-critical-toast';
    document.body.appendChild(el);
  }
  el.innerHTML = `
    <span class="skf-critical-toast-ico">🔴</span>
    <div class="skf-critical-toast-body">
      <strong>Hallazgo crítico</strong>
      <span>${_skfHtmlEsc(h.plantilla_nombre || '')}${h.campo_etiqueta ? ' · ' + _skfHtmlEsc(h.campo_etiqueta) : ''}</span>
    </div>
    <a class="skf-critical-toast-link" href="hallazgos.html">Ver →</a>
    <button class="skf-critical-toast-close" onclick="this.closest('.skf-critical-toast').classList.remove('show')" aria-label="Cerrar">✕</button>
  `;
  el.classList.add('show');
  clearTimeout(el._skfTimer);
  el._skfTimer = setTimeout(() => el.classList.remove('show'), 12000);
}

function skfNotifyCritical(h) {
  skfShowCriticalToast(h);
  window.dispatchEvent(new CustomEvent('skf:hallazgo-critico', { detail: h }));
  if (typeof Notification !== 'undefined' && Notification.permission === 'granted' && document.hidden) {
    try {
      const n = new Notification('🔴 Hallazgo crítico — SEKaform', {
        body: (h.plantilla_nombre || '') + (h.campo_etiqueta ? ' · ' + h.campo_etiqueta : ''),
        tag: 'skf-critico-' + h.id
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
    alert('Las alertas del navegador ya están activas para SEKaform. Para desactivarlas, hazlo desde la configuración de notificaciones de tu navegador.');
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
    ? 'Alertas activas — los hallazgos críticos te avisan al instante, aunque estés en otra pestaña'
    : 'Activar notificaciones del navegador para hallazgos críticos';
}

let _skfCriticalChannel = null;
// El parámetro se mantiene por compatibilidad con quien la llama (sidebar.js),
// pero la suscripción ahora se filtra por organización, no por usuario.
async function skfSubscribeCriticalAlerts(_user) {
  if (!SKF_CONFIGURED || _skfCriticalChannel) return;
  const org = await skfGetOrg();
  if (!org) return;
  const sb = await getSB();
  if (!sb) return;
  _skfCriticalChannel = sb.channel('hallazgos-criticos-' + org.orgId)
    .on('postgres_changes', {
      event: 'INSERT', schema: 'public', table: 'hallazgos',
      filter: `org_id=eq.${org.orgId}`
    }, (payload) => {
      if (payload.new && payload.new.severidad === 'critico') skfNotifyCritical(payload.new);
    })
    .subscribe();
}

// ─────────────────────────────────────────────────────────────
//  Cola de sincronización offline
//
//  Un inspector en campo no siempre tiene señal. La nube es la fuente de
//  verdad, pero cada registro se guarda primero en localStorage como caché
//  y, si el envío a Supabase falla (sin conexión o error del servidor), la
//  operación se encola en localStorage y se reintenta sola al recuperar la
//  señal — nunca se pierde un hallazgo por falta de cobertura.
// ─────────────────────────────────────────────────────────────
const SKF_QUEUE_KEY = 'skf_sync_queue';

function skfQueueGet() {
  try { return JSON.parse(localStorage.getItem(SKF_QUEUE_KEY)) || []; } catch { return []; }
}
function skfQueueSet(q) {
  localStorage.setItem(SKF_QUEUE_KEY, JSON.stringify(q));
  skfUpdateSyncBadge();
}
const SKF_QUEUE_MAX_ATTEMPTS = 5;

function skfQueueAdd(tipo, payload) {
  const q = skfQueueGet();
  q.push({
    id: crypto.randomUUID ? crypto.randomUUID() : 'q_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8),
    tipo, payload, creadoEn: new Date().toISOString(), attempts: 0
  });
  skfQueueSet(q);
}

const SKF_SYNC_FNS = {
  plantilla: sbSyncPlantilla,
  deletePlantilla: (p) => sbDeletePlantilla(p.id),
  envio: sbSyncEnvio,
  envioPublico: (p) => sbSubmitPublicEnvio(p).then(r => !!(r && r.ok)),
  hallazgo: sbSyncHallazgo,
  hallazgoPublico: (p) => sbSubmitPublicHallazgo(p).then(r => !!(r && r.ok)),
  accionCorrectiva: sbSyncAccionCorrectiva,
  asignacion: sbSyncAsignacion,
  deleteAsignacion: (p) => sbDeleteAsignacion(p.id),
  unidad: sbSyncUnidad,
  deleteUnidad: (p) => sbDeleteUnidad(p.id),
};

// Intenta sincronizar de inmediato; si falla o no hay conexión, encola
// para reintentar automáticamente más tarde. Devuelve si quedó sincronizado.
async function skfSyncOrQueue(tipo, payload) {
  if (navigator.onLine) {
    try {
      if (await SKF_SYNC_FNS[tipo](payload)) return true;
    } catch {}
  }
  skfQueueAdd(tipo, payload);
  return false;
}

let _skfProcessingQueue = false;
async function skfProcessQueue() {
  if (_skfProcessingQueue || !navigator.onLine) return;
  _skfProcessingQueue = true;
  skfUpdateSyncBadge(true);
  try {
    const q = skfQueueGet();
    if (!q.length) return;
    const remaining = [];
    for (const item of q) {
      const fn = SKF_SYNC_FNS[item.tipo];
      let ok = false;
      if (fn) { try { ok = await fn(item.payload); } catch { ok = false; } }
      if (!ok) {
        item.attempts = (item.attempts || 0) + 1;
        if (item.attempts < SKF_QUEUE_MAX_ATTEMPTS) remaining.push(item);
      }
    }
    skfQueueSet(remaining);
  } finally {
    _skfProcessingQueue = false;
    skfUpdateSyncBadge(false);
  }
}

function skfUpdateSyncBadge(activelySyncing) {
  const el = document.getElementById('skfSyncBar');
  if (!el) return;
  const n = skfQueueGet().length;
  if (!navigator.onLine) {
    el.innerHTML = '📡 Sin conexión' + (n ? ` · ${n} pendiente${n !== 1 ? 's' : ''} de sincronizar` : ' · tus datos se guardan localmente');
    el.className = 'skf-sync-bar offline';
    el.style.display = 'flex';
  } else if (activelySyncing) {
    el.innerHTML = `↻ Sincronizando…`;
    el.className = 'skf-sync-bar syncing';
    el.style.display = 'flex';
  } else if (n) {
    el.innerHTML = `☁ ${n} pendiente${n !== 1 ? 's' : ''} · <a href="login.html" style="color:inherit;text-decoration:underline">inicia sesión para sincronizar</a>`;
    el.className = 'skf-sync-bar syncing';
    el.style.display = 'flex';
  } else {
    el.style.display = 'none';
  }
}

window.addEventListener('online', () => { skfUpdateSyncBadge(false); skfProcessQueue(); });
window.addEventListener('offline', () => skfUpdateSyncBadge(false));
document.addEventListener('DOMContentLoaded', () => {
  skfUpdateSyncBadge(false);
  if (navigator.onLine) skfProcessQueue();
});
setInterval(() => { if (navigator.onLine) skfProcessQueue(); }, 30000);

// ── PWA: registra el service worker para que el "app shell" cargue sin
// conexión (indispensable para un inspector sin señal en campo). ───────
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  });
}
