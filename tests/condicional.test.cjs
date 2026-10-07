// Lógica condicional («mostrar este campo solo si…») de field-types.js.
// Ejecutar: node tests/condicional.test.cjs
const fs = require('fs'), vm = require('vm'), path = require('path');
const ctx = {}; vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'field-types.js'), 'utf8') +
  '\nthis.vis=fieldIsVisible; this.pun=skfPuntaje; this.opts=fieldCondOptions;', ctx);
let ok = 0, fail = 0;
const t = (n, c) => { if (c) ok++; else { fail++; console.error('FALLA:', n); } };

const campos = [
  { id: 'a', tipo: 'si_no' },
  { id: 'b', tipo: 'radio', opciones: ['1 - Deficiente', '2 - Regular', '3 - Bueno'] },
  { id: 'c', tipo: 'radio', opciones: ['x', 'y'], mostrarSi: { campoId: 'a', valores: ['No'] } },
  { id: 'd', tipo: 'texto', mostrarSi: { campoId: 'b', valores: ['1 - Deficiente', '2 - Regular'] } },
  { id: 'e', tipo: 'texto', mostrarSi: { campoId: 'c', valores: ['x'] } },   // depende de otro condicional
];
t('sin condición: visible', ctx.vis(campos[0], campos, {}));
t('condición no cumplida: oculto', !ctx.vis(campos[2], campos, { a: 'Sí' }));
t('sin responder: oculto', !ctx.vis(campos[2], campos, {}));
t('cumplida: visible', ctx.vis(campos[2], campos, { a: 'No' }));
t('varios valores (uno)', ctx.vis(campos[3], campos, { b: '2 - Regular' }));
t('varios valores (otro no)', !ctx.vis(campos[3], campos, { b: '3 - Bueno' }));
t('encadenado: padre oculto => oculto', !ctx.vis(campos[4], campos, { a: 'Sí', c: 'x' }));
t('encadenado: padre visible y cumple', ctx.vis(campos[4], campos, { a: 'No', c: 'x' }));
t('dependencia borrada: visible', ctx.vis({ id: 'z', mostrarSi: { campoId: 'nada', valores: ['x'] } }, [{ id: 'z' }], {}));
t('dependencia más abajo: visible', ctx.vis({ id: 'z', mostrarSi: { campoId: 'y', valores: ['Sí'] } }, [{ id: 'z' }, { id: 'y', tipo: 'si_no' }], {}));
t('opción renombrada: visible', ctx.vis({ id: 'z', mostrarSi: { campoId: 'b', valores: ['Malo'] } }, [campos[1], { id: 'z' }], {}));
t('valores vacíos: visible', ctx.vis({ id: 'z', mostrarSi: { campoId: 'a', valores: [] } }, [campos[0], { id: 'z' }], {}));
t('ciclo no cuelga', ctx.vis({ id: 'p', mostrarSi: { campoId: 'q', valores: ['Sí'] } }, [{ id: 'q', tipo: 'si_no', mostrarSi: { campoId: 'p', valores: ['Sí'] } }, { id: 'p' }], {}) !== undefined);
t('opciones si_no', ctx.opts({ tipo: 'si_no' }).join() === 'Sí,No,N/A');
t('texto no sirve de disparador', ctx.opts({ tipo: 'texto' }).length === 0);

// Puntaje de cumplimiento
const P = [
  { id: 'n', tipo: 'texto' },
  { id: 's1', tipo: 'si_no' }, { id: 's2', tipo: 'si_no' }, { id: 's3', tipo: 'si_no' }, { id: 's4', tipo: 'si_no' },
  { id: 'e', tipo: 'escala_1_5', opciones: ['1','2','3','4','5'] },
  { id: 'q', tipo: 'numero', rangoMin: 10, rangoMax: 20 }, { id: 'q2', tipo: 'numero' },
  { id: 'r', tipo: 'radio', opciones: ['Bueno', 'Deficiente'] },
  { id: 'r2', tipo: 'radio', opciones: ['Deficiente', 'Bueno'], severidad: 'menor' },
  { id: 'o', tipo: 'textarea', mostrarSi: { campoId: 's1', valores: ['No'] } },
];
let r = ctx.pun(P, { n: 'x', s1: 'Sí', s2: 'No', s3: 'N/A', s4: 'Sí', e: '4', q: '15', q2: '5', r: 'Deficiente', r2: 'Deficiente' });
t('puntos: si_no (N/A fuera) + escala + rango + radio con criticidad = 6', r.total === 6);
t('ok = s1,s4,e,q = 4', r.ok === 4 && r.pct === 67 && r.nivel === 'bajo');
t('datos generales y número sin rango no cuentan', r.fallan.length === 2);
r = ctx.pun(P, { s1: 'Sí', s2: 'Sí', s3: 'Sí', s4: 'Sí', e: '5', q: '12' });
t('100 % alto', r.pct === 100 && r.nivel === 'alto');
r = ctx.pun(P, { s1: 'Sí', s2: 'Sí', s3: 'Sí', s4: 'No', e: '5', q: '12' });
t('83 % medio', r.pct === 83 && r.nivel === 'medio');
t('escala 1 falla', ctx.pun([{ id: 'e', tipo: 'escala_1_5' }], { e: '1' }).pct === 0);
t('número fuera de rango falla', ctx.pun([P[6]], { q: '99' }).pct === 0);
t('sin puntos: null', ctx.pun([{ id: 'n', tipo: 'texto' }], { n: 'x' }) === null && ctx.pun(P, {}) === null);
t('campo oculto no cuenta', ctx.pun([P[1], { id: 'z', tipo: 'si_no', mostrarSi: { campoId: 's1', valores: ['No'] } }], { s1: 'Sí', z: 'No' }).total === 1);

// Catálogo: las condiciones apuntan a campos que existen, anteriores y con esa opción.
const lib = fs.readFileSync(path.join(__dirname, '..', 'form-library.js'), 'utf8');
const c2 = {}; vm.createContext(c2);
vm.runInContext(lib + '\nthis.L=FORM_LIBRARY;', c2);
let conds = 0;
c2.L.forEach(f => (f.campos_clave || []).forEach((x, i) => {
  if (!x.mostrarSi) return; conds++;
  const j = f.campos_clave.findIndex(y => y.etiqueta === x.mostrarSi.campo);
  t(f.id + ': dependencia existe y es anterior', j >= 0 && j < i);
  const dep = f.campos_clave[j] || {};
  const op = ctx.opts({ tipo: dep.tipo, opciones: dep.opciones });
  t(f.id + ': valores válidos', x.mostrarSi.valores.every(v => op.indexOf(v) !== -1));
}));
t('el catálogo usa condiciones', conds >= 3);
console.log(`${ok} pasaron, ${fail} fallaron (de ${ok + fail})`);
process.exit(fail ? 1 : 0);
