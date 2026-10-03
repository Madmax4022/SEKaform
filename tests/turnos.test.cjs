// Lógica del control por turnos (form-library.js): a qué turno pertenece una
// hora y si cada turno cumplió lo esperado. Las fechas se construyen con la
// hora LOCAL (igual que el código), así que la prueba no depende de la zona.
//
// Ejecutar: node tests/turnos.test.cjs
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'form-library.js'), 'utf8')
  + ';module.exports={skfTurnoDe,skfEstadoTurnos};';
const m = { exports: {} };
new Function('module', 'require', src)(m, require);
const { skfTurnoDe, skfEstadoTurnos } = m.exports;

const TURNOS = [
  { id: 'm', nombre: 'Mañana', inicio: '06:00', fin: '14:00' },
  { id: 't', nombre: 'Tarde',  inicio: '14:00', fin: '22:00' },
  { id: 'n', nombre: 'Noche',  inicio: '22:00', fin: '06:00' },
];
const D = (d, h, mi = 0) => new Date(2026, 9, d, h, mi); // octubre 2026, hora local
let ok = 0, fail = 0;
function t(nombre, fn) { try { fn(); console.log('PASS: ' + nombre); ok++; } catch (e) { console.log('FAIL: ' + nombre + '\n   ' + e.message); fail++; } }
function eq(a, b, msg) { if (a !== b) throw new Error((msg || '') + ' esperado ' + b + ' pero fue ' + a); }

t('una hora cae en su turno (mañana, tarde, noche antes de medianoche)', () => {
  eq(skfTurnoDe(D(5, 9), TURNOS).turno.id, 'm');
  eq(skfTurnoDe(D(5, 15), TURNOS).turno.id, 't');
  eq(skfTurnoDe(D(5, 23), TURNOS).turno.id, 'n');
});
t('los límites: inicio incluido, fin excluido', () => {
  eq(skfTurnoDe(D(5, 6, 0), TURNOS).turno.id, 'm', '06:00');
  eq(skfTurnoDe(D(5, 14, 0), TURNOS).turno.id, 't', '14:00 ya es tarde');
  eq(skfTurnoDe(D(5, 5, 59), TURNOS).turno.id, 'n', '05:59 aún es noche');
});
t('a las 02:00 pertenece a la noche que EMPEZÓ el día anterior', () => {
  const r = skfTurnoDe(D(6, 2), TURNOS);
  eq(r.turno.id, 'n');
  eq(r.inicio.getDate(), 5, 'la noche empezó el 5');
  eq(r.fin.getDate(), 6, 'y termina el 6');
});
t('sin turnos definidos no hay turno', () => { eq(skfTurnoDe(D(5, 9), []), null); });

const CFG = { turnos: TURNOS, esperado: ['A', 'B'] };
const env = (pid, f) => ({ plantilla_id: pid, enviado_en: f.toISOString() });

t('turno completo: llegó todo lo esperado dentro del turno', () => {
  const r = skfEstadoTurnos(CFG, [env('A', D(5, 7)), env('B', D(5, 10))], D(5, 12), 0);
  const m = r.find(x => x.turno.id === 'm');
  eq(m.estado, 'completo'); eq(m.hechos.length, 2);
});
t('turno en curso: falta algo pero el turno aún no termina', () => {
  const r = skfEstadoTurnos(CFG, [env('A', D(5, 7))], D(5, 12), 0);
  eq(r.find(x => x.turno.id === 'm').estado, 'en_curso');
});
t('turno omitido: terminó y faltó algo', () => {
  const r = skfEstadoTurnos(CFG, [env('A', D(5, 7))], D(5, 15), 0);
  const m = r.find(x => x.turno.id === 'm');
  eq(m.estado, 'omitido'); eq(m.faltan[0], 'B');
});
t('un registro fuera del turno no cuenta para ese turno', () => {
  const r = skfEstadoTurnos(CFG, [env('A', D(5, 15)), env('B', D(5, 15))], D(5, 20), 0);
  eq(r.find(x => x.turno.id === 'm').estado, 'omitido', 'mañana sin nada propio');
  eq(r.find(x => x.turno.id === 't').estado, 'completo', 'tarde sí lo hizo');
});
t('la noche cruza medianoche: lo de las 02:00 cuenta para la noche anterior', () => {
  const r = skfEstadoTurnos(CFG, [env('A', D(5, 23)), env('B', D(6, 2))], D(6, 8), 1);
  const noche5 = r.find(x => x.turno.id === 'n' && x.inicio.getDate() === 5);
  eq(noche5.estado, 'completo');
});
t('no se cuentan turnos que aún no empiezan', () => {
  const r = skfEstadoTurnos(CFG, [], D(5, 9), 0);
  eq(r.some(x => x.turno.id === 't'), false, 'la tarde aún no empieza');
  eq(r.some(x => x.turno.id === 'n' && x.inicio.getDate() === 5), false, 'la noche del 5 aún no empieza');
});
t('devuelve los más recientes primero', () => {
  const r = skfEstadoTurnos(CFG, [], D(6, 20), 1);
  for (let i = 1; i < r.length; i++) if (r[i - 1].inicio < r[i].inicio) throw new Error('orden incorrecto');
});
t('sin formularios esperados: estado «sin_esperado», nunca omitido', () => {
  const r = skfEstadoTurnos({ turnos: TURNOS, esperado: [] }, [], D(5, 20), 0);
  eq(r.every(x => x.estado === 'sin_esperado'), true);
});
t('fechas inválidas o plantillas ajenas se ignoran sin romper', () => {
  const r = skfEstadoTurnos(CFG, [{ plantilla_id: 'A', enviado_en: 'basura' }, env('Z', D(5, 8))], D(5, 12), 0);
  eq(r.find(x => x.turno.id === 'm').hechos.length, 0);
});

console.log('\n' + ok + ' pasaron, ' + fail + ' fallaron (de ' + (ok + fail) + ')');
process.exit(fail ? 1 : 0);
