// SEKaform — QR y etiquetas de equipos, generados en el propio dispositivo.
//
// Antes el QR se pedía a api.qrserver.com: el enlace (con su clave de acceso)
// salía a un tercero, fallaba sin conexión y además la política de seguridad
// del sitio (img-src) bloqueaba esa imagen. Ahora se dibuja aquí con qrcode.js.
//
// Requiere qrcode.js antes de este archivo.

// SVG del QR (blanco y negro: es lo que mejor lee cualquier cámara). '' si no cabe.
function skfQrSvg(texto) {
  try {
    const q = qrcode(0, 'M');
    q.addData(String(texto));
    q.make();
    return q.createSvgTag({ cellSize: 4, margin: 4, scalable: true, alt: 'Código QR' });
  } catch (e) { return ''; }
}

// El QR de un equipo lleva solo su código: el formulario se busca al abrirlo, así
// la etiqueta sigue sirviendo aunque el formulario se renueve. Nada privado.
function skfUrlEquipo(codigo) {
  return new URL('llenar.html?equipo=' + encodeURIComponent(codigo), location.href).href;
}

// Abre una hoja lista para imprimir en papel adhesivo: código grande, QR, tipo y lugar.
// equipos: [{ codigo, tipo:{nombre,ico}, lugar }]
function skfImprimirEtiquetas(equipos, empresa) {
  const esc = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  const tarjetas = (equipos || []).map(e => `
    <div class="et">
      <div class="qr">${skfQrSvg(skfUrlEquipo(e.codigo))}</div>
      <div class="tx">
        <div class="cod">${esc(e.codigo)}</div>
        <div class="tipo">${esc(e.tipo.nombre)}${e.lugar ? ' · ' + esc(e.lugar) : ''}</div>
        <div class="esc">📷 Escanéame para inspeccionar</div>
        ${empresa ? `<div class="emp">${esc(empresa)}</div>` : ''}
      </div>
    </div>`).join('');
  const html = `<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Etiquetas de equipos${empresa ? ' — ' + esc(empresa) : ''}</title>
<style>
  *{box-sizing:border-box} body{margin:0;font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;color:#111;background:#f3f4f6}
  .bar{position:sticky;top:0;display:flex;gap:10px;align-items:center;justify-content:space-between;padding:12px 16px;background:#111827;color:#fff;font-size:.9rem}
  .bar button{min-height:44px;padding:0 18px;border:0;border-radius:10px;background:#2563eb;color:#fff;font:inherit;font-weight:700;cursor:pointer}
  .hoja{display:grid;grid-template-columns:repeat(auto-fill,minmax(88mm,1fr));gap:4mm;padding:8mm;max-width:210mm;margin:0 auto;background:#fff}
  .et{display:flex;gap:4mm;align-items:center;border:1px dashed #9ca3af;border-radius:3mm;padding:4mm;break-inside:avoid;page-break-inside:avoid}
  .qr{width:30mm;height:30mm;flex:none} .qr svg{width:100%;height:100%;display:block}
  .cod{font-size:22pt;font-weight:900;letter-spacing:.5px;line-height:1}
  .tipo{font-size:10pt;margin-top:2mm;font-weight:600} .esc{font-size:8.5pt;margin-top:2mm;color:#374151}
  .emp{font-size:7.5pt;margin-top:1.5mm;color:#6b7280}
  @page{size:A4;margin:8mm} @media print{.bar{display:none} body{background:#fff} .hoja{padding:0;max-width:none}}
</style></head><body>
<div class="bar"><span>${(equipos || []).length} etiqueta${(equipos || []).length !== 1 ? 's' : ''} · recorta por la línea punteada</span><button onclick="print()">🖨 Imprimir</button></div>
<div class="hoja">${tarjetas}</div></body></html>`;
  const w = window.open('', '_blank');
  if (!w) { alert('El navegador bloqueó la ventana de impresión. Permite las ventanas emergentes para este sitio e inténtalo de nuevo.'); return false; }
  w.document.open(); w.document.write(html); w.document.close();
  return true;
}
