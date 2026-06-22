// ─────────────────────────────────────────────────────────────
//  SEKaform — Supabase Configuration
//
//  1. Create a project at https://supabase.com
//  2. Go to Settings → API and copy your URL and anon key
//  3. Replace the values below
//  4. Run supabase-schema.sql in the SQL editor
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
  const sb = await getSB();
  if (sb) await sb.auth.signOut();
}

async function sbSyncPlantilla(tmpl) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const payload = {
      id: tmpl.id,
      user_id: user.id,
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
    if (error) console.warn('[SEKaform] Sync plantilla:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync plantilla error:', e.message); }
}

async function sbDeletePlantilla(id) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const { error } = await sb.from('plantillas').delete().eq('id', id).eq('user_id', user.id);
    if (error) console.warn('[SEKaform] Delete plantilla:', error.message);
  } catch(e) { console.warn('[SEKaform] Delete plantilla error:', e.message); }
}

async function sbSyncEnvio(envio) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const payload = {
      id: envio.id,
      numero: envio.numero || null,
      plantilla_id: envio.plantillaId || null,
      plantilla_nombre: envio.plantillaNombre || '',
      plantilla_codigo: envio.plantillaCodigo || '',
      user_id: user.id,
      datos: envio.datos || {},
      estado: envio.estado || 'enviado',
      llenado_por: envio.llenadoPor || null,
      llenado_correo: envio.llenadoCorreo || null,
      creado_en: envio.creadoEn || new Date().toISOString(),
      enviado_en: envio.enviadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('envios').upsert(payload);
    if (error) console.warn('[SEKaform] Sync envío:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync envío error:', e.message); }
}

// Carga una plantilla pública por su share_token, sin necesitar sesión
// (usada por llenar.html cuando alguien abre un link/QR ?pub=<token>).
async function sbLoadPublicPlantilla(token) {
  try {
    const sb = await getSB();
    if (!sb || !token) return null;
    // Columnas explícitas (no '*'): user_id y correo_notificacion son
    // privados del dueño y no deben viajar a un visitante anónimo. La base
    // de datos también revoca esas columnas a nivel de permisos (ver
    // supabase-schema.sql) como segunda capa de defensa.
    const { data, error } = await sb.from('plantillas')
      .select('id, nombre, campos, codigo, descripcion, logo, publica, share_token')
      .eq('share_token', token).eq('publica', true).maybeSingle();
    if (error || !data) return null;
    return data;
  } catch { return null; }
}

// Envía un formulario sin sesión. El user_id que viajamos aquí es solo un
// placeholder: el trigger envios_asignar_dueno en el servidor lo
// sobrescribe siempre con el dueño real de la plantilla (ver
// supabase-schema.sql), así que el dato termina en el dataset del dueño.
async function sbSubmitPublicEnvio(envio) {
  try {
    const sb = await getSB();
    if (!sb) return { error: 'sin conexión' };
    const payload = {
      id: envio.id,
      numero: null, // el servidor lo asigna (el visitante anónimo no puede leer envíos previos)
      plantilla_id: envio.plantillaId || null,
      plantilla_nombre: envio.plantillaNombre || '',
      plantilla_codigo: envio.plantillaCodigo || '',
      user_id: '00000000-0000-0000-0000-000000000000',
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

// Sincroniza un hallazgo (detectado automáticamente o reportado a mano
// durante el llenado) hacia el panel del dueño de la plantilla — ver
// "hallazgos" en supabase-schema.sql.
async function sbSyncHallazgo(h) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const payload = {
      id: h.id,
      user_id: user.id,
      envio_id: h.envioId || null,
      plantilla_id: h.plantillaId || null,
      plantilla_nombre: h.plantillaNombre || '',
      campo_id: h.campoId || null,
      campo_etiqueta: h.campoEtiqueta || null,
      origen: h.origen || 'manual',
      severidad: h.severidad || 'menor',
      descripcion: h.descripcion || null,
      foto: h.foto || null,
      estado: h.estado || 'abierto',
      reportado_por: h.reportadoPor || null
    };
    const { error } = await sb.from('hallazgos').upsert(payload);
    if (error) console.warn('[SEKaform] Sync hallazgo:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync hallazgo error:', e.message); }
}

// Igual que sbSubmitPublicEnvio: un visitante sin cuenta llenando un link
// público también puede reportar un hallazgo — el trigger
// hallazgos_asignar_dueno en Supabase sobrescribe el user_id real.
async function sbSubmitPublicHallazgo(h) {
  try {
    const sb = await getSB();
    if (!sb) return { error: 'sin conexión' };
    const payload = {
      id: h.id,
      user_id: '00000000-0000-0000-0000-000000000000',
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
    const user = await sbGetUser();
    if (!user) return null;
    const { data, error } = await sb.from('hallazgos')
      .select('*').eq('user_id', user.id).order('creado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

// Acción correctiva (CAPA) — quién debe resolver un hallazgo y para cuándo.
async function sbSyncAccionCorrectiva(ac) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const payload = {
      id: ac.id,
      user_id: user.id,
      hallazgo_id: ac.hallazgoId,
      responsable: ac.responsable || null,
      correo: ac.correo || null,
      fecha_limite: ac.fechaLimite || null,
      estado: ac.estado || 'pendiente',
      evidencia_cierre: ac.evidenciaCierre || null,
      cerrado_en: ac.cerradoEn || null
    };
    const { error } = await sb.from('acciones_correctivas').upsert(payload);
    if (error) console.warn('[SEKaform] Sync acción correctiva:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync acción correctiva error:', e.message); }
}

async function sbLoadAccionesCorrectivas() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const user = await sbGetUser();
    if (!user) return null;
    const { data, error } = await sb.from('acciones_correctivas')
      .select('*').eq('user_id', user.id).order('creado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

async function sbLoadPlantillas() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const user = await sbGetUser();
    if (!user) return null;
    const { data, error } = await sb.from('plantillas')
      .select('*').eq('user_id', user.id).order('actualizado_en', { ascending: false });
    if (error) return null;
    return data;
  } catch { return null; }
}

async function sbLoadEnvios(limit = 500) {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const user = await sbGetUser();
    if (!user) return null;
    const { data, error } = await sb.from('envios')
      .select('*').eq('user_id', user.id)
      .order('enviado_en', { ascending: false }).limit(limit);
    if (error) return null;
    return data;
  } catch { return null; }
}

// ── Asignaciones (panel de administración: a quién se le pidió llenar
// cada plantilla, para calcular cumplimiento) ──────────────────────────
async function sbSyncAsignacion(a) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const payload = {
      id: a.id,
      user_id: user.id,
      plantilla_id: a.plantillaId || null,
      plantilla_nombre: a.plantillaNombre || '',
      nombre: a.nombre,
      correo: a.correo || null,
      creado_en: a.creadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('asignaciones').upsert(payload);
    if (error) console.warn('[SEKaform] Sync asignación:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync asignación error:', e.message); }
}

async function sbDeleteAsignacion(id) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const { error } = await sb.from('asignaciones').delete().eq('id', id).eq('user_id', user.id);
    if (error) console.warn('[SEKaform] Delete asignación:', error.message);
  } catch (e) { console.warn('[SEKaform] Delete asignación error:', e.message); }
}

async function sbLoadAsignaciones() {
  try {
    const sb = await getSB();
    if (!sb) return null;
    const user = await sbGetUser();
    if (!user) return null;
    const { data, error } = await sb.from('asignaciones')
      .select('*').eq('user_id', user.id).order('creado_en', { ascending: false });
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
