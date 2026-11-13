// SEKaform · control de trabajos. Lo que comparten control.html, solicitud.html y porteria.html:
// iconos, formato de fechas y folios, QR y avisos. No depende de skf-api.js, porque las dos
// páginas públicas no tienen sesión ni cola de sincronización.

const CT_ICONOS = {
  escudo: 'M12 3l7 3v5c0 4.5-3 8.3-7 10-4-1.7-7-5.5-7-10V6l7-3zM9 12l2 2 4-4',
  edificio: 'M4 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16M16 9h2a2 2 0 0 1 2 2v10M2 21h20M8 7h4M8 11h4M8 15h4',
  alturas: 'M8 3v18M16 3v18M8 7h8M8 12h8M8 17h8',
  caliente: 'M12 3c1 3 4 5 4 9a4 4 0 0 1-8 0c0-1.5.5-2.5 1.5-3.5C10 10 11 7 12 3z',
  electrico: 'M13 2L4 14h7l-1 8 9-12h-7l1-8z',
  incendio: 'M6 16v-5a6 6 0 0 1 12 0v5l2 2H4l2-2zM10 21a2 2 0 0 0 4 0',
  general: 'M9 4h6v3H9zM9 5H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1h-3M9 12h6M9 16h6',
  rutinario: 'M5 12l5 5 9-10',
  foto: 'M4 8h3l2-3h6l2 3h3v11H4zM12 17a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z',
  firma: 'M4 20l4-1L19 8l-3-3L5 16l-1 4zM14 7l3 3',
  doc: 'M7 3h7l5 5v13H7zM14 3v5h5',
  alerta: 'M12 4l9 16H3L12 4zM12 10v4M12 17v.5',
  reloj: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2',
  ok: 'M5 12l5 5 9-10', no: 'M6 6l12 12M18 6L6 18', mas: 'M12 5v14M5 12h14',
  relevo: 'M4 8h13l-3-3M20 16H7l3 3',
  personas: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20a6 6 0 0 1 12 0M16 5.2a3 3 0 0 1 0 5.6M21 20a6 6 0 0 0-4-5.6',
  enlace: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
};
const CT_CRIT = { critico: 'Crítico', medio: 'Medio', bajo: 'Bajo' };

function ctIco(n) { return `<svg class="i" viewBox="0 0 24 24" aria-hidden="true"><path d="${CT_ICONOS[n] || CT_ICONOS.general}"/></svg>`; }
function ctEsc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }

// El «hoy» es el del teléfono, no el del servidor: a las 7 p. m. en Centroamérica el servidor ya va por mañana.
function ctHoy() { const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
function ctFecha(iso) {
  if (!iso) return '';
  const f = String(iso).slice(0, 10);
  if (f === ctHoy()) return 'Hoy';
  return new Date(f + 'T00:00:00').toLocaleDateString('es', { weekday: 'short', day: 'numeric', month: 'short' });
}
function ctHora(iso) { return iso ? new Date(iso).toLocaleTimeString('es', { hour: 'numeric', minute: '2-digit' }) : ''; }
function ctFechaHora(iso) { if (!iso) return ''; const d = new Date(iso); return (d.toDateString() === new Date().toDateString() ? '' : d.toLocaleDateString('es', { day: 'numeric', month: 'short' }) + ' ') + ctHora(iso); }
function ctMinutos(iso) { return iso ? Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000)) : 0; }
function ctEspera(min) { return min >= 1440 ? Math.floor(min / 1440) + ' d' : min >= 60 ? Math.floor(min / 60) + ' h ' + (min % 60) + ' min' : min + ' min'; }

// PT-PLZ-0012: «permiso de trabajo», tres letras del edificio y el correlativo de ese edificio.
function ctSigla(nombre) {
  const p = String(nombre || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9 ]/g, '').trim().split(/\s+/).filter(Boolean);
  const s = p.length >= 3 ? p[0][0] + p[1][0] + p[2][0] : p.length === 2 ? p[0].slice(0, 2) + p[1][0] : (p[0] || 'EDI').slice(0, 3);
  return s.toUpperCase().padEnd(3, 'X');
}
function ctFolio(nombreEdificio, numero) { return 'PT-' + ctSigla(nombreEdificio) + '-' + String(numero || 0).padStart(4, '0'); }

function ctQR(texto) {
  if (typeof qrcode !== 'function') return '';
  try { const q = qrcode(0, 'M'); q.addData(texto); q.make(); return q.createSvgTag({ cellSize: 4, margin: 2, scalable: true, alt: 'Código QR' }); } catch (e) { return ''; }
}
function ctToast(m) {
  const d = document.createElement('div'); d.className = 'toast'; d.setAttribute('role', 'status'); d.textContent = m;
  document.body.appendChild(d); setTimeout(() => d.remove(), 3000);
}
async function ctCopiar(texto) {
  try { await navigator.clipboard.writeText(texto); ctToast('Enlace copiado.'); }
  catch (e) { window.prompt('Copia este enlace:', texto); }
}
// Petición sin sesión (páginas públicas). Devuelve el JSON o lanza un Error con el mensaje del servidor.
async function ctPublico(url, cuerpo) {
  const r = await fetch(url, cuerpo ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(cuerpo) } : {});
  let j = null; try { j = await r.json(); } catch (e) {}
  if (!r.ok) throw new Error((j && j.error) || 'No se pudo conectar. Revisa tu señal e intenta de nuevo.');
  return j;
}
function ctRequisitos(tipo) { return tipo ? tipo.grupos.reduce((a, g) => a.concat(g.items), []) : []; }
