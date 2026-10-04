// A qué formulario lleva «Te falta evidencia de «X»» (form-library.js: skfFormularioParaPrincipio).
// Ejecutar: node tests/principios.test.cjs
const fs = require('fs'), path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'form-library.js'), 'utf8')
  + ';module.exports={skfFormularioParaPrincipio,SST_PRINCIPIOS,SST_PRINCIPIO_MAP,FORM_LIBRARY,skfLocalizeText};';
const m = { exports: {} }; new Function('module', 'require', src)(m, require);
const { skfFormularioParaPrincipio: dest, SST_PRINCIPIOS, SST_PRINCIPIO_MAP, FORM_LIBRARY, skfLocalizeText } = m.exports;
let ok = 0, fail = 0;
function t(n, f) { try { f(); console.log('PASS: ' + n); ok++; } catch (e) { console.log('FAIL: ' + n + '\n   ' + e.message); fail++; } }
function eq(a, b, msg) { if (a !== b) throw new Error((msg || '') + ' esperado ' + b + ' pero fue ' + a); }
const nom = (id, pais = 'co') => skfLocalizeText(FORM_LIBRARY.find(f => f.id === id).nombre, pais);

t('los 9 principios tienen al menos un formulario que los cubre (ninguno queda sin destino)', () => {
  SST_PRINCIPIOS.forEach(p => { if (!dest(p.id, 'co', [])) throw new Error('sin destino: ' + p.id); });
  eq(SST_PRINCIPIOS.length, 9);
});
t('todo formulario del mapa existe en el catálogo', () => {
  const ids = new Set(FORM_LIBRARY.map(f => f.id));
  Object.keys(SST_PRINCIPIO_MAP).forEach(k => { if (!ids.has(k)) throw new Error('no existe: ' + k); });
});
t('sin formularios propios: el más usado del catálogo, que se agrega y se abre', () => {
  const r = dest('prevencion', 'co', []);
  eq(r.propio, false); eq(r.id, 'inspeccion_sst', 'el más usado (freq 1) que cubre prevención'); eq(r.href, 'digitalizador.html?preset=inspeccion_sst');
});
t('si ya tiene uno que lo cubre, lo abre (no crea copia), aunque no sea el más usado', () => {
  const r = dest('prevencion', 'co', [{ id: 'mi-toma5', nombre: nom('toma_5') }]);
  eq(r.propio, true); eq(r.href, 'llenar.html?tmpl=mi-toma5');
});
t('si tiene varios, abre el más usado de los suyos', () => {
  const r = dest('prevencion', 'co', [{ id: 'm-toma5', nombre: nom('toma_5') }, { id: 'm-lista', nombre: nom('inspeccion_sst') }]);
  eq(r.id, 'inspeccion_sst'); eq(r.href, 'llenar.html?tmpl=m-lista');
});
t('formularios propios que no cubren ese principio no cuentan', () => {
  const r = dest('capacitacion', 'co', [{ id: 'x', nombre: nom('inspeccion_sst') }]);
  eq(r.propio, false); eq(r.id, 'asistencia');
});
t('los nombres se comparan localizados al país (Acta del comité cambia por país)', () => {
  const r = dest('cooperacion', 'cr', [{ id: 'acta-cr', nombre: nom('acta_copasst', 'cr') }]);
  eq(r.propio, true, 'reconoce «Acta de Reunión — Comisión de Salud Ocupacional»'); eq(r.nombre, 'Acta de Reunión — Comisión de Salud Ocupacional');
  eq(dest('cooperacion', 'cr', [{ id: 'acta-co', nombre: nom('acta_copasst', 'co') }]).propio, false, 'el nombre de Colombia no es el de Costa Rica');
});
t('el id se codifica en la URL y entradas raras no rompen', () => {
  eq(dest('prevencion', 'co', [{ id: 'a b/c', nombre: nom('inspeccion_sst') }]).href, 'llenar.html?tmpl=a%20b%2Fc');
  eq(dest('prevencion', 'co', [null, {}, { id: 'z' }, { nombre: 'q' }]).propio, false);
  eq(dest('principio-inexistente', 'co', []), null);
});
console.log('\n' + ok + ' pasaron, ' + fail + ' fallaron (de ' + (ok + fail) + ')'); process.exit(fail ? 1 : 0);
