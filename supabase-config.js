// ─────────────────────────────────────────────────────────────
//  SEKaform — Supabase Configuration
//
//  1. Create a project at https://supabase.com
//  2. Go to Settings → API and copy your URL and anon key
//  3. Replace the values below
//  4. Run supabase-schema.sql in the SQL editor
// ─────────────────────────────────────────────────────────────
const SKF_SUPABASE_URL = 'YOUR_SUPABASE_URL';
const SKF_SUPABASE_KEY = 'YOUR_SUPABASE_ANON_KEY';
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
      creado_en: tmpl.creadoEn || new Date().toISOString(),
      actualizado_en: new Date().toISOString()
    };
    const { error } = await sb.from('plantillas').upsert(payload);
    if (error) console.warn('[SEKaform] Sync plantilla:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync plantilla error:', e.message); }
}

async function sbSyncEnvio(envio) {
  try {
    const sb = await getSB();
    if (!sb) return;
    const user = await sbGetUser();
    if (!user) return;
    const payload = {
      id: envio.id,
      plantilla_id: envio.plantillaId || null,
      plantilla_nombre: envio.plantillaNombre || '',
      user_id: user.id,
      datos: envio.datos || {},
      estado: envio.estado || 'enviado',
      creado_en: envio.creadoEn || new Date().toISOString(),
      enviado_en: envio.enviadoEn || new Date().toISOString()
    };
    const { error } = await sb.from('envios').upsert(payload);
    if (error) console.warn('[SEKaform] Sync envío:', error.message);
  } catch (e) { console.warn('[SEKaform] Sync envío error:', e.message); }
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
