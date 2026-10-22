// Códigos de equipo (EXT-001…) de field-types.js.
// Ejecutar: node tests/equipos.test.cjs
const fs = require('fs'), vm = require('vm'), path = require('path');
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'field-types.js'), 'utf8') +
  '\nthis.norm=skfEquipoNormalizar; this.sig=skfEquipoSiguiente; this.con=skfEquiposConocidos; this.tipo=skfEquipoTipo; this.pun=skfPuntaje; this.form=skfEquipoFormulario;', ctx);
let ok = 0, fail = 0;
const t = (n, c) => { if (c) ok++; else { fail++; console.error('FALLA:', n); } };

t('ext 3', ctx.norm('ext 3') === 'EXT-003');
t('Ext-03', ctx.norm('Ext-03') === 'EXT-003');
t('EXT3', ctx.norm('EXT3') === 'EXT-003');
t('EXT-0012', ctx.norm('EXT-0012') === 'EXT-012');
t('EXT-1234 no se recorta', ctx.norm('EXT-1234') === 'EXT-1234');
t('numeración propia se respeta', ctx.norm('  Extintor  cocina ') === 'Extintor cocina');
t('vacío', ctx.norm(null) === '' && ctx.norm('') === '');
t('siguiente sin nada', ctx.sig([], 'EXT') === 'EXT-001');
t('siguiente con huecos y otros prefijos', ctx.sig(['EXT-001', 'ext 7', 'GAB-020', 'Cocina'], 'EXT') === 'EXT-008');
t('siguiente de otro prefijo', ctx.sig(['EXT-001', 'GAB-002'], 'gab') === 'GAB-003');
t('tipo conocido', ctx.tipo('ext').nombre === 'Extintor');
t('tipo desconocido', ctx.tipo('ZZ').prefijo === 'ZZ');

const pls = [
  { id: 'p1', campos: [{ id: 'e', tipo: 'equipo', prefijo: 'EXT' }, { id: 'u', tipo: 'texto' }] },
  { id: 'p2', campos: [{ id: 'x', tipo: 'equipo' }] },                 // sin prefijo = EXT
  { id: 'p3', campos: [{ id: 'g', tipo: 'equipo', prefijo: 'GAB' }] },
];
const envs = [
  { plantillaId: 'p1', estado: 'enviado', enviadoEn: '2026-09-01T10:00:00Z', unidadId: 'A', datos: { e: 'ext 2', u: 'Bodega' } },
  { plantillaId: 'p1', estado: 'enviado', enviadoEn: '2026-10-01T10:00:00Z', unidadId: 'B', datos: { e: 'EXT-002', u: 'Patio' } },
  { plantillaId: 'p2', estado: 'enviado', enviadoEn: '2026-10-05T10:00:00Z', datos: { x: 'EXT-010' } },
  { plantillaId: 'p3', estado: 'enviado', enviadoEn: '2026-10-05T10:00:00Z', datos: { g: 'GAB-001' } },
  { plantillaId: 'p1', estado: 'borrador', enviadoEn: '2026-10-09T10:00:00Z', datos: { e: 'EXT-099' } },
];
const c = ctx.con(envs, pls, 'EXT');
t('agrupa por código normalizado', c.length === 2 && c[0].codigo === 'EXT-002' && c[1].codigo === 'EXT-010');
t('cuenta inspecciones', c[0].veces === 2);
t('se queda con la última', c[0].ultima === '2026-10-01T10:00:00.000Z' && c[0].unidadId === 'B' && c[0].datos.u === 'Patio');
t('borradores no cuentan', !c.find(x => x.codigo === 'EXT-099'));
t('otro prefijo aparte', ctx.con(envs, pls, 'GAB').length === 1);
t('el equipo no suma al puntaje', ctx.pun([{ id: 'e', tipo: 'equipo' }, { id: 'q', tipo: 'si_no' }], { e: 'EXT-001', q: 'Sí' }).total === 1);

// ── Avisos: inspección mensual y recarga ─────────────────────────────
const ag = {}; vm.createContext(ag);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'field-types.js'), 'utf8') + '\n' +
  fs.readFileSync(path.join(__dirname, '..', 'agenda.js'), 'utf8') + '\nthis.est=skfEquiposEstado; this.agenda=skfAgenda; this.hoyF=skfAgendaHoy;', ag);
const ahora = new Date('2026-10-22T12:00:00');
const plE = [{ id: 'pe', nombre: 'Extintores', campos: [{ id: 'e', tipo: 'equipo', prefijo: 'EXT' }, { id: 'r', tipo: 'fecha', etiqueta: 'Fecha de próxima recarga / vencimiento' }, { id: 'o', tipo: 'fecha', etiqueta: 'Otra fecha' }] }];
const env = (cod, f, rec) => ({ plantillaId: 'pe', estado: 'enviado', enviadoEn: f, datos: { e: cod, r: rec, o: '2020-01-01' } });
const es = ag.est([env('EXT-001', '2026-10-20T10:00:00', '2027-06-01'), env('EXT-002', '2026-09-10T10:00:00', '2026-11-05'),
                   env('EXT-003', '2026-09-20T10:00:00', '2026-10-01')], plE, ahora);
const q = c => es.find(x => x.codigo === c);
t('al día: próxima en 28 días', q('EXT-001').diasInspeccion === 28 && q('EXT-001').diasRecarga > 200);
t('atrasada: 42 días sin inspección', q('EXT-002').diasInspeccion === -12);
t('recarga en 14 días', q('EXT-002').diasRecarga === 14);
t('recarga vencida', q('EXT-003').diasRecarga === -21);
t('usa la fecha de recarga, no cualquier fecha', q('EXT-001').recarga === '2027-06-01');
t('lo más urgente primero', es[0].codigo === 'EXT-003' && es[2].codigo === 'EXT-001');
t('sin campo de recarga: null', ag.est([{ plantillaId: 'p1', estado: 'enviado', enviadoEn: '2026-10-01', datos: { e: 'EXT-001' } }], pls, ahora)[0].diasRecarga === null);

const its = ag.agenda({ plantillas: plE, envios: [env('EXT-001', '2026-10-20T10:00:00', '2027-06-01'), env('EXT-002', '2026-09-10T10:00:00', '2026-11-05')] }, ahora)
  .filter(i => i.tipo === 'equipo');
t('al día y sin recarga cerca: no aparece', !its.find(i => i.titulo.startsWith('EXT-001')));
t('inspección atrasada en la agenda', !!its.find(i => i.titulo === 'EXT-002 · inspección mensual' && i.estado === 'vencido'));
t('recarga en 14 días en la agenda (no en Hoy)', !!its.find(i => i.titulo === 'EXT-002 · recarga por vencer' && i.estado === 'despues'));
t('el aviso abre el equipo', its[0].href === 'llenar.html?tmpl=pe&equipo=EXT-002');
t('ícono del equipo', its[0].ico === '🧯');
const muchos = ['EXT-004', 'EXT-005', 'EXT-006', 'EXT-007', 'EXT-008'].map(c => env(c, '2026-09-01T10:00:00', '2028-01-01'));
const g = ag.agenda({ plantillas: plE, envios: muchos }, ahora).filter(i => i.tipo === 'equipo');
t('tres o más se agrupan', g.length === 1 && g[0].titulo === '5 extintores · sin inspección al día' && /EXT-004, EXT-005, EXT-006, EXT-007 y 1 más/.test(g[0].detalle));
t('el grupo va en Hoy', ag.hoyF(g).length === 1);

// Fechas como las manda la nube (RFC 1123) y capturado_en antes que la recepción
const nube = [{ plantilla_id: 'p1', estado: 'enviado', enviado_en: 'Thu, 22 Oct 2026 10:00:00 GMT', capturado_en: 'Mon, 05 Oct 2026 10:00:00 GMT', datos: { e: 'EXT-050' } },
              { plantilla_id: 'p1', estado: 'enviado', enviado_en: 'Wed, 21 Oct 2026 10:00:00 GMT', datos: { e: 'EXT-050', u: 'Última' } }];
const cn = ctx.con(nube, pls, 'EXT');
t('fechas de la nube: gana la más reciente, no la de texto mayor', cn[0].ultima === '2026-10-21T10:00:00.000Z' && cn[0].datos.u === 'Última');
t('usa cuándo se capturó', ctx.con([nube[0]], pls, 'EXT')[0].ultima === '2026-10-05T10:00:00.000Z');

// ── Bajas ─────────────────────────────────────────────────────────────
const env3 = [env('EXT-001', '2026-09-01T10:00:00', '2028-01-01'), env('EXT-002', '2026-09-01T10:00:00', '2028-01-01')];
const bajas = [{ codigo: 'EXT-001', bajaEn: '2026-10-01T00:00:00Z' }, { codigo: 'ext 2', bajaEn: '2026-08-01T00:00:00Z' }];
const eb = ag.est(env3, plE, ahora, bajas);
t('dado de baja: no avisa', !eb.find(x => x.codigo === 'EXT-001'));
t('inspeccionado después de la baja: vuelve', !!eb.find(x => x.codigo === 'EXT-002'));
t('agenda sin el dado de baja', !ag.agenda({ plantillas: plE, envios: env3, equiposBaja: bajas }, ahora).some(i => /EXT-001/.test(i.titulo)));
t('sin bajas: igual que antes', ag.est(env3, plE, ahora).length === 2);

// ── QR: qué formulario abre un código ────────────────────────────────
t('QR: formulario de su última inspección', ctx.form('ext 2', envs, pls) === 'p1');
t('QR: código nuevo de un tipo conocido', ctx.form('GAB-099', envs, pls) === 'p3');
t('QR: formulario borrado → otro del mismo tipo', ctx.form('EXT-010', envs, pls.filter(p => p.id !== 'p2')) === 'p1');
t('QR: tipo sin formulario', ctx.form('LUZ-001', envs, pls) === null);
t('QR: vacío', ctx.form('', envs, pls) === null);
const qr = {}; vm.createContext(qr);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'qrcode.js'), 'utf8') + '\n' + fs.readFileSync(path.join(__dirname, '..', 'etiquetas.js'), 'utf8') + '\nthis.svg=skfQrSvg;', qr);
t('QR en el dispositivo: SVG', /^<svg[\s\S]*<path d="M/.test(qr.svg('https://sekaform.kanansentinel.com/llenar.html?equipo=EXT-004')));
t('QR demasiado largo: vacío, sin romper', qr.svg('x'.repeat(5000)) === '');

console.log(`${ok} pasaron, ${fail} fallaron (de ${ok + fail})`);
process.exit(fail ? 1 : 0);
