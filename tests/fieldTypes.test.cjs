// Regresión para field-types.js — el catálogo único de tipos de campo
// compartido entre digitalizador.html y llenar.html.
//
// Antes cada página mantenía su propia copia a mano (TIPOS/TIPO_MAP en
// digitalizador.html, _FICON/_FCLASS en llenar.html) y llegaron a divergir
// sin que nada lo notara (el ícono de "Desplegable" no era el mismo en las
// dos). Esta prueba no solo corre field-types.js de forma aislada: carga el
// script real de cada página en un contexto vm y confirma que efectivamente
// leen del mismo catálogo, en vez de mantener una copia local.
//
// Ejecutar: node tests/fieldTypes.test.cjs

const vm = require('vm');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const FIELD_TYPES_SRC = fs.readFileSync(path.join(ROOT, 'field-types.js'), 'utf8');

function makeStub() {
  const target = function stub() { return makeStub(); };
  const handler = {
    get(t, prop) {
      if (prop === Symbol.toPrimitive) return () => '';
      if (prop in t) return t[prop];
      return makeStub();
    },
    set() { return true; },
    apply() { return makeStub(); },
  };
  return new Proxy(target, handler);
}

function makeDomSandbox() {
  const sandbox = { console, setTimeout, clearTimeout, clearInterval, setInterval, Promise, URLSearchParams };
  sandbox.document = makeStub();
  sandbox.window = sandbox;
  sandbox.localStorage = makeStub();
  sandbox.navigator = makeStub();
  sandbox.location = makeStub();
  sandbox.history = makeStub();
  vm.createContext(sandbox);
  return sandbox;
}

function extractInlineScript(htmlFile) {
  const html = fs.readFileSync(path.join(ROOT, htmlFile), 'utf8');
  const match = html.match(/<script>([\s\S]*?)<\/script>/);
  if (!match) throw new Error(`No se encontró el <script> inline en ${htmlFile}`);
  return match[1];
}

let pass = 0, fail = 0;
function check(name, fn) {
  try {
    fn();
    pass++;
    console.log(`PASS: ${name}`);
  } catch (e) {
    fail++;
    console.log(`FAIL: ${name}`);
    console.log(`  ${e.message}`);
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg || 'assertion failed'); }

// --- 1. field-types.js aislado ------------------------------------------

check('field-types.js define el catálogo esperado', () => {
  const sandbox = makeDomSandbox();
  vm.runInContext(FIELD_TYPES_SRC, sandbox, { filename: 'field-types.js' });

  const keys = vm.runInContext('FIELD_TYPES.map(t=>t.k)', sandbox);
  const expected = ['fecha_auto','hora_auto','ubicacion','si_no','escala_1_5','select','radio','checkbox','checkbox_multi','firma','foto','texto','textarea','numero','email','telefono','fecha','separador'];
  assert(JSON.stringify(keys) === JSON.stringify(expected), `claves inesperadas: ${JSON.stringify(keys)}`);

  const needsOpts = vm.runInContext("['select','radio','checkbox_multi','escala_1_5','si_no','texto'].map(fieldNeedsOptions)", sandbox);
  assert(JSON.stringify(needsOpts) === JSON.stringify([true,true,true,true,false,false]), `fieldNeedsOptions incorrecto: ${JSON.stringify(needsOpts)}`);

  const selectIco = vm.runInContext('FIELD_TYPE_MAP.select.ico', sandbox);
  assert(selectIco === '▼', `ícono de "select" inesperado: ${selectIco}`);
});

// --- 2. digitalizador.html consume el catálogo compartido (no copia local) ---

check('digitalizador.html: TIPO_MAP es el mismo objeto que FIELD_TYPE_MAP', () => {
  const sandbox = makeDomSandbox();
  vm.runInContext(FIELD_TYPES_SRC, sandbox, { filename: 'field-types.js' });
  vm.runInContext(extractInlineScript('digitalizador.html'), sandbox, { filename: 'digitalizador-inline.js' });

  const sameObject = vm.runInContext('TIPO_MAP === FIELD_TYPE_MAP', sandbox);
  assert(sameObject === true, 'TIPO_MAP ya no apunta al catálogo compartido (¿volvió a copiarse localmente?)');

  assert(typeof sandbox.analyzeText === 'function', 'analyzeText no quedó definida');
});

// --- 3. llenar.html consume el catálogo compartido (no _FICON/_FCLASS) ---

check('llenar.html: buildFieldEl usa el ícono canónico de field-types.js', () => {
  const sandbox = makeDomSandbox();
  vm.runInContext(FIELD_TYPES_SRC, sandbox, { filename: 'field-types.js' });
  vm.runInContext(extractInlineScript('llenar.html'), sandbox, { filename: 'llenar-inline.js' });

  assert(typeof sandbox.buildFieldEl === 'function', 'buildFieldEl no quedó definida');

  // No debe lanzar ReferenceError por _FICON/_FCLASS ya removidos.
  sandbox.buildFieldEl({ id: 'c1', tipo: 'select', etiqueta: 'Cargo', requerido: false, opciones: ['A','B'] });

  const icoEnContexto = vm.runInContext('FIELD_TYPE_MAP.select.ico', sandbox);
  assert(icoEnContexto === '▼', `llenar.html ya no ve el ícono canónico de "select": ${icoEnContexto}`);
});

console.log(`\n${pass} pasaron, ${fail} fallaron (de ${pass + fail})`);
if (fail > 0) process.exit(1);
