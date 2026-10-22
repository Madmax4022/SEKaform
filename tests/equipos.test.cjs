// Códigos de equipo (EXT-001…) de field-types.js.
// Ejecutar: node tests/equipos.test.cjs
const fs = require('fs'), vm = require('vm'), path = require('path');
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'field-types.js'), 'utf8') +
  '\nthis.norm=skfEquipoNormalizar; this.sig=skfEquipoSiguiente; this.con=skfEquiposConocidos; this.tipo=skfEquipoTipo; this.pun=skfPuntaje;', ctx);
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
t('se queda con la última', c[0].ultima === '2026-10-01T10:00:00Z' && c[0].unidadId === 'B' && c[0].datos.u === 'Patio');
t('borradores no cuentan', !c.find(x => x.codigo === 'EXT-099'));
t('otro prefijo aparte', ctx.con(envs, pls, 'GAB').length === 1);
t('el equipo no suma al puntaje', ctx.pun([{ id: 'e', tipo: 'equipo' }, { id: 'q', tipo: 'si_no' }], { e: 'EXT-001', q: 'Sí' }).total === 1);

console.log(`${ok} pasaron, ${fail} fallaron (de ${ok + fail})`);
process.exit(fail ? 1 : 0);
