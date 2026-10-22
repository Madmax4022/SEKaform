// SEKaform — administrar el «Portal del cliente» (migración 011).
// Un enlace por empresa, sin cuenta, con su estado de cumplimiento siempre al día.
// Requiere skf-api.js y sidebar.js (skfSheet). Solo dueño o administrador lo crean.

async function skfPortal() { return skfFetch('/api/portal'); }
async function skfPortalCrear() { return skfFetch('/api/portal', { method: 'POST', body: '{}' }); }
async function skfPortalRevocar() { return skfFetch('/api/portal', { method: 'DELETE' }); }

async function skfPortalAdministrar(origen) {
  const esc = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  const cuerpo = skfSheet('Portal del cliente', '<p class="skf-sheet-nota">Cargando…</p>', origen);
  let rol = null; try { rol = await skfRol(); } catch (e) {}
  const admin = rol === 'dueno' || rol === 'admin';
  const hace = f => { if (!f) return 'nunca'; const d = Math.floor((Date.now() - new Date(f)) / 864e5); return d <= 0 ? 'hoy' : d === 1 ? 'ayer' : 'hace ' + d + ' días'; };
  const intro = '<p class="skf-sheet-nota">Un enlace para tu cliente o tu gerencia, sin cuenta: ve el estado de cumplimiento <b>siempre al día</b> — los 9 principios, el puntaje, los hallazgos y las últimas inspecciones. No muestra respuestas detalladas, firmas ni fotos.</p>';

  async function pintar() {
    let r;
    try { r = await skfPortal(); }
    catch (e) { cuerpo.innerHTML = '<p class="skf-sheet-nota">Sin conexión: el portal se administra con señal.</p>'; return; }
    if (r.disponible === false) { cuerpo.innerHTML = intro + '<p class="skf-sheet-nota">Falta preparar la base (migración 011). Pídeselo a tu administrador técnico.</p>'; return; }
    const p = r.portal;
    if (!p) {
      cuerpo.innerHTML = intro + (admin
        ? '<button type="button" class="pw-sig pw-fin" id="ptCrear">Crear el portal</button>'
        : '<p class="skf-sheet-nota">Aún no hay portal. Solo el dueño o un administrador puede crearlo.</p>');
      const b = document.getElementById('ptCrear');
      if (b) b.onclick = async () => { b.disabled = true; b.textContent = 'Creando…'; try { await skfPortalCrear(); pintar(); } catch (e) { b.textContent = e.message; } };
      return;
    }
    const msg = 'Te comparto el estado de cumplimiento en seguridad y salud en el trabajo, siempre actualizado: ' + p.url;
    cuerpo.innerHTML = intro + `
      <div class="pw-resumen" style="font-size:.9rem;word-break:break-all">${esc(p.url)}</div>
      <p class="skf-sheet-nota">Abierto ${p.accesos} ${p.accesos === 1 ? 'vez' : 'veces'} · última ${hace(p.ultimoAcceso)}</p>
      <a class="skf-opt" target="_blank" rel="noopener" href="https://wa.me/?text=${encodeURIComponent(msg)}"><span class="so-ico">💬</span><span class="so-txt"><b>Enviar por WhatsApp</b><small>Con el mensaje ya escrito</small></span><span class="so-arr">›</span></a>
      <button type="button" class="skf-opt pw-btnopt" id="ptCopiar"><span class="so-ico">🔗</span><span class="so-txt"><b>Copiar enlace</b><small id="ptCopS">Para correo u otra app</small></span><span class="so-arr">›</span></button>
      <a class="skf-opt" target="_blank" rel="noopener" href="${esc(p.url)}"><span class="so-ico">👁️</span><span class="so-txt"><b>Ver como lo ve tu cliente</b><small>Se abre en otra pestaña</small></span><span class="so-arr">›</span></a>
      ${admin ? `<div class="skf-sheet-sec">Seguridad del enlace</div>
      <button type="button" class="skf-opt pw-btnopt" id="ptRegen"><span class="so-ico">🔄</span><span class="so-txt"><b>Cambiar el enlace</b><small>El anterior deja de funcionar (por si se reenvió a quien no debía)</small></span><span class="so-arr">›</span></button>
      <button type="button" class="skf-opt pw-btnopt" id="ptOff"><span class="so-ico">⛔</span><span class="so-txt"><b style="color:var(--err-txt)">Desactivar el portal</b><small>Nadie podrá abrirlo hasta que crees uno nuevo</small></span><span class="so-arr">›</span></button>` : ''}`;
    document.getElementById('ptCopiar').onclick = () => (navigator.clipboard ? navigator.clipboard.writeText(p.url) : Promise.reject())
      .then(() => { document.getElementById('ptCopS').textContent = '✓ Copiado'; }).catch(() => prompt('Copia el enlace:', p.url));
    const regen = document.getElementById('ptRegen'), off = document.getElementById('ptOff');
    if (regen) regen.onclick = async () => {
      if (!confirm('¿Cambiar el enlace? El que ya compartiste dejará de funcionar.')) return;
      try { await skfPortalCrear(); pintar(); } catch (e) { alert(e.message); }
    };
    if (off) off.onclick = async () => {
      if (!confirm('¿Desactivar el portal? El enlace dejará de funcionar para todos.')) return;
      try { await skfPortalRevocar(); pintar(); } catch (e) { alert(e.message); }
    };
  }
  pintar();
}
