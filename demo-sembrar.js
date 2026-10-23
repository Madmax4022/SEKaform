// SEKaform — empresa de demostración para vender (guion de demo de 10 minutos).
//
// Llena la empresa ACTIVA —que debe llamarse «… (demo)»— con lo que el guion muestra:
// sede y bodega, dos contratistas (uno evaluado, otro sin evaluar), cinco extintores con
// código (uno atrasado y uno con la recarga vencida), inspecciones, un hallazgo crítico
// abierto, uno cerrado con fotos de antes y después, una rutina para hoy, un encargo y el
// portal del cliente con fotos. Todo entra por la misma API que usa la app (/api/sync).
//
// Fechas: lo que vale como evidencia (puntaje, principios) usa la hora del servidor y no
// se puede antedatar; equipos y contratistas usan cuándo se llenó, por eso esos sí
// muestran historia (un extintor revisado hace 41 días).
//
// Requiere skf-api.js (skfFetch, _SALIDA, skfUUID) y form-library.js (catálogo).

const SKF_DEMO_SUFIJO = '(demo)';
const SKF_DEMO_FORMULARIOS = ['inspeccion_sst', 'inspeccion_extintores', 'evaluacion_contratista', 'inspeccion_botiquin',
  'asistencia', 'entrega_epp', 'acta_copasst'];

// Fotos de ejemplo dibujadas en el teléfono (en la demo se toma una real al reportar un hallazgo).
function _demoFoto(fondo, detalle) {
  const cv = document.createElement('canvas'); cv.width = 960; cv.height = 720;
  const x = cv.getContext('2d');
  const g = x.createLinearGradient(0, 0, 0, 720); g.addColorStop(0, fondo[0]); g.addColorStop(1, fondo[1]);
  x.fillStyle = g; x.fillRect(0, 0, 960, 720);
  x.fillStyle = 'rgba(255,255,255,.08)'; for (let i = 0; i < 12; i++) x.fillRect(0, i * 64, 960, 2);   // muro
  x.fillStyle = '#c0392b'; x.beginPath(); x.roundRect(400, 200, 160, 380, 40); x.fill();               // extintor
  x.fillStyle = '#222'; x.fillRect(440, 150, 80, 60); x.fillStyle = '#e5e7eb'; x.fillRect(452, 360, 56, 90);
  // Sin rótulo arriba: la app y el portal ya ponen «Antes» / «Después» sobre la foto.
  x.fillStyle = 'rgba(0,0,0,.45)'; x.fillRect(0, 610, 960, 110);
  x.fillStyle = '#fff'; x.font = 'bold 38px system-ui, sans-serif'; x.textAlign = 'center'; x.fillText(detalle, 480, 678);
  return cv.toDataURL('image/jpeg', 0.7);
}
function _demoFirma() {
  const cv = document.createElement('canvas'); cv.width = 400; cv.height = 140;
  const x = cv.getContext('2d'); x.strokeStyle = '#1e293b'; x.lineWidth = 3; x.beginPath(); x.moveTo(20, 90);
  for (let i = 0; i < 14; i++) x.quadraticCurveTo(40 + i * 25, i % 2 ? 30 : 120, 55 + i * 25, 80);
  x.stroke();
  return cv.toDataURL('image/png');
}

// Respuestas por tipo; `r` = respuestas puntuales por texto de la pregunta (regex → valor).
function _demoDatos(pl, r, extra) {
  const hoy = new Date().toISOString().slice(0, 10), firma = _demoFirma(), d = {};
  (pl.campos || []).forEach(c => {
    const m = (r || []).find(([re]) => re.test(c.etiqueta || ''));
    if (m) { d[c.id] = m[1]; return; }
    switch (c.tipo) {
      case 'si_no': d[c.id] = 'Sí'; break;
      case 'fecha_auto': case 'fecha': d[c.id] = hoy; break;
      case 'hora_auto': d[c.id] = '08:30'; break;
      case 'firma': d[c.id] = firma; break;
      case 'select': case 'radio': d[c.id] = (c.opciones || [])[0] || ''; break;
      case 'checkbox_multi': d[c.id] = (c.opciones || []).slice(0, 1); break;
      case 'numero': d[c.id] = '12'; break;
      case 'escala_1_5': d[c.id] = (c.opciones || [])[3] || '4 - Muy Bueno'; break;
      case 'texto': d[c.id] = /responsable|inspector|nombre|quien/i.test(c.etiqueta) ? 'Laura Gómez' : 'Sede principal'; break;
      case 'textarea': d[c.id] = 'Sin novedades.'; break;
    }
  });
  return Object.assign(d, extra || {});
}

async function skfSembrarDemo(progreso) {
  const paso = t => { try { progreso && progreso(t); } catch (e) {} };
  const yo = await skfYo({ forzar: true });
  if (!yo || !yo.orgNombre || !yo.orgNombre.endsWith(SKF_DEMO_SUFIJO)) throw new Error('La demostración solo se crea en una empresa cuyo nombre termina en «(demo)».');
  const env0 = await skfFetch('/api/envios?limite=1');
  if ((env0.envios || []).length) throw new Error('Esta empresa de demostración ya tiene datos.');

  const ops = [], op = (tipo, obj) => { ops.push({ opId: skfUUID(), tipo, datos: _SALIDA[tipo](obj) }); return obj; };
  const dias = n => new Date(Date.now() - n * 864e5).toISOString();
  const fecha = n => new Date(Date.now() + n * 864e5).toISOString().slice(0, 10);

  paso('Formularios del catálogo…');
  const pl = {};
  SKF_DEMO_FORMULARIOS.forEach((id, i) => { const p = skfPlantillaDesdeCatalogo(id, 'co', yo.email, 'FORM-' + String(i + 1).padStart(4, '0')); if (p) pl[id] = op('plantilla', p); });

  paso('Sedes y contratistas…');
  const sede = op('unidad', { id: skfUUID(), nombre: 'Sede principal', tipo: 'sede' });
  const bodega = op('unidad', { id: skfUUID(), nombre: 'Bodega de materiales', tipo: 'area' });
  const montajes = op('unidad', { id: skfUUID(), nombre: 'Montajes Ruiz S.A.S.', tipo: 'contratista' });
  op('unidad', { id: skfUUID(), nombre: 'Vigilancia Sur Ltda.', tipo: 'contratista' });

  paso('Inspecciones…');
  const envio = (p, unidad, datos, capturado) => op('envio', { id: skfUUID(), plantillaId: p.id, plantillaNombre: p.nombre, plantillaCodigo: p.codigo,
    unidadId: unidad ? unidad.id : null, datos, estado: 'enviado', llenadoPor: 'Laura Gómez', llenadoCorreo: yo.email, creadoEn: capturado || dias(0) });
  // Lista de verificación SST: varias, con algún incumplimiento para que el puntaje sea creíble.
  const sst = pl.inspeccion_sst;
  [0, 2, 5, 9, 14].forEach((n, i) => envio(sst, i % 2 ? bodega : sede, _demoDatos(sst, i === 1 ? [[/orden|aseo|limpi/i, 'No']] : i === 3 ? [[/señaliz/i, 'No']] : []), dias(n)));
  // Extintores: EXT-002 lleva 41 días sin inspección; EXT-004 tiene la recarga vencida.
  const ext = pl.inspeccion_extintores;
  [['EXT-001', 'Recepción', 6, 200, sede], ['EXT-002', 'Cocina del personal', 41, 120, sede], ['EXT-003', 'Pasillo bodega', 3, 260, bodega],
   ['EXT-004', 'Entrada de bodega', 12, -5, bodega], ['EXT-005', 'Oficina de obra', 8, 300, sede]].forEach(([cod, ubic, hace, recarga, u]) =>
    envio(ext, u, _demoDatos(ext, [[/^Extintor$/, cod], [/Ubicación/i, ubic], [/Capacidad/i, '20 lb'], [/recarga|vencim/i, fecha(recarga)]]), dias(hace)));
  // Contratista evaluado hace 20 días, con dos incumplimientos.
  const ev = pl.evaluacion_contratista;
  envio(ev, montajes, _demoDatos(ev, [[/^Contratista/, montajes.nombre], [/inducción/i, 'No'], [/alto riesgo/i, 'Sí'], [/certificado vigente/i, 'No'],
    [/Servicio u obra/i, 'Montaje de estructura metálica'], [/quien atiende/i, 'Carlos Ruiz']]), dias(20));
  ['inspeccion_botiquin', 'asistencia', 'entrega_epp', 'acta_copasst'].forEach((id, i) => pl[id] && envio(pl[id], sede, _demoDatos(pl[id]), dias(3 + i * 4)));

  paso('Hallazgos con fotos…');
  const hz = (desc, sev, unidad, p, extra) => op('hallazgo', Object.assign({ id: skfUUID(), plantillaId: p.id, plantillaNombre: p.nombre, origen: 'manual',
    severidad: sev, descripcion: desc, unidadId: unidad.id, estado: 'abierto', reportadoPor: 'Laura Gómez' }, extra || {}));
  hz('Salida de emergencia de la bodega bloqueada con estibas', 'critico', bodega, sst,
    { foto: _demoFoto(['#7f1d1d', '#450a0a'], 'Salida bloqueada con estibas') });
  const cerrado = hz('EXT-003 · Extintor sin sello de seguridad', 'mayor', bodega, ext,
    { estado: 'cerrado', foto: _demoFoto(['#7f1d1d', '#450a0a'], 'EXT-003 sin sello de seguridad') });
  op('accionCorrectiva', { id: skfUUID(), hallazgoId: cerrado.id, responsable: 'Laura Gómez', estado: 'completada', cerradoEn: dias(0),
    evidenciaCierre: _demoFoto(['#14532d', '#052e16'], 'EXT-003 con sello nuevo') });
  const ind = hz('Montajes Ruiz · trabajadores sin la inducción SST de la empresa', 'mayor', montajes, ev);
  op('accionCorrectiva', { id: skfUUID(), hallazgoId: ind.id, responsable: 'Carlos Ruiz', correo: null, fechaLimite: fecha(7), estado: 'pendiente' });
  hz('Montajes Ruiz · trabajo en alturas sin certificado vigente', 'critico', montajes, ev);

  paso('Plan del día…');
  op('inspeccion', { id: skfUUID(), plantillaId: sst.id, unidadId: sede.id, nombre: 'Ronda de seguridad semanal', frecuencia: 'semanal',
    proximoEn: fecha(0), responsable: 'Laura Gómez' });
  op('asignacion', { id: skfUUID(), plantillaId: pl.inspeccion_botiquin.id, plantillaNombre: pl.inspeccion_botiquin.nombre, unidadId: bodega.id,
    nombre: 'Andrés (brigadista)', correo: null, fechaLimite: fecha(2) });

  paso('Guardando en la nube…');
  for (let i = 0; i < ops.length; i += 40) {
    const r = await skfFetch('/api/sync', { method: 'POST', body: JSON.stringify({ operaciones: ops.slice(i, i + 40) }) });
    const mal = (r.resultados || []).filter(x => !x.ok);
    if (mal.length) throw new Error('No se pudo guardar parte de la demostración (' + mal.length + '). Vuelve a intentarlo.');
  }

  paso('Portal del cliente…');
  let portal = null;
  try { portal = (await skfFetch('/api/portal', { method: 'POST', body: JSON.stringify({ fotos: true }) })).portal; } catch (e) {}
  // El perfil de la empresa queda listo: la app no manda al asistente de bienvenida.
  try { skfPerfilSet(yo.email, { completo: true, trabajadores: '11-50', riesgo: 'III', pais: 'co', areas: ['construccion'], en: new Date().toISOString() }); } catch (e) {}
  return { registros: ops.length, portal: portal && portal.url };
}
