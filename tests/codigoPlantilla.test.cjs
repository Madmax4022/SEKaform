// Regresión para el "Código" de formulario en digitalizador.html — la llave
// que el dashboard usa para agrupar envíos del mismo tipo de formulario
// (en vez de su nombre escrito a mano, que puede variar de una digitalización
// a otra y fragmentar las estadísticas de inteligencia de negocio).
//
// Carga el <script> inline real de digitalizador.html en un contexto vm,
// con un localStorage controlable (no el stub genérico) para poder fijar
// qué plantillas "ya existen" y comprobar la autogeneración / no-duplicado.
//
// Ejecutar: node tests/codigoPlantilla.test.cjs

const vm = require('vm');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const FIELD_TYPES_SRC = fs.readFileSync(path.join(ROOT, 'field-types.js'), 'utf8');
const MAIN_SRC = (() => {
  const html = fs.readFileSync(path.join(ROOT, 'digitalizador.html'), 'utf8');
  const match = html.match(/<script>([\s\S]*?)<\/script>/);
  if (!match) throw new Error('No se encontró el <script> inline en digitalizador.html');
  return match[1];
})();

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

function makeLocalStorage(initial) {
  const store = { ...initial };
  return {
    getItem: k => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: k => { delete store[k]; },
  };
}

function loadDigitalizador(plantillasPrevias) {
  const sandbox = { console, setTimeout, clearTimeout, clearInterval, setInterval, Promise, URLSearchParams };
  sandbox.document = makeStub();
  sandbox.window = sandbox;
  sandbox.localStorage = makeLocalStorage({ skf_plantillas: JSON.stringify(plantillasPrevias || []) });
  sandbox.navigator = makeStub();
  sandbox.location = makeStub();
  sandbox.history = makeStub();

  vm.createContext(sandbox);
  vm.runInContext(FIELD_TYPES_SRC, sandbox, { filename: 'field-types.js' });
  vm.runInContext(MAIN_SRC, sandbox, { filename: 'digitalizador-inline.js' });
  return sandbox;
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

// --- normalizeCodigo() ---------------------------------------------------

check('normalizeCodigo: quita tildes, mayúsculas, símbolos no alfanuméricos', () => {
  const sandbox = loadDigitalizador([]);
  const got = vm.runInContext("normalizeCodigo('Inspección Sanitaria #2!')", sandbox);
  assert(got === 'INSPECCION-SANITARIA-2', `obtuve: ${got}`);
});

check('normalizeCodigo: colapsa separadores y recorta a 32 caracteres', () => {
  const sandbox = loadDigitalizador([]);
  const got = vm.runInContext("normalizeCodigo('   a---b   c   '.padEnd(50,'x'))", sandbox);
  assert(got.length <= 32, `largo inesperado: ${got.length}`);
  assert(!got.includes('--'), `quedaron separadores dobles: ${got}`);
  assert(!/^-|-$/.test(got), `quedó con guion al borde: ${got}`);
});

check('normalizeCodigo: cadena vacía o solo símbolos da string vacío', () => {
  const sandbox = loadDigitalizador([]);
  const got = vm.runInContext("normalizeCodigo('   ¡¡¡   ')", sandbox);
  assert(got === '', `esperaba vacío, obtuve: "${got}"`);
});

// --- ensureCodigo() / genNextCodigo() en init -----------------------------

check('una plantilla nueva (sin códigos previos) arranca en FORM-0001', () => {
  const sandbox = loadDigitalizador([]);
  const cod = vm.runInContext('tmpl.codigo', sandbox);
  assert(cod === 'FORM-0001', `código inicial inesperado: ${cod}`);
});

check('el siguiente código es max(existentes)+1, no count+1', () => {
  const previas = [
    { id: 'a', nombre: 'A', codigo: 'FORM-0001' },
    { id: 'b', nombre: 'B', codigo: 'FORM-0007' },
  ];
  const sandbox = loadDigitalizador(previas);
  const cod = vm.runInContext('tmpl.codigo', sandbox);
  assert(cod === 'FORM-0008', `esperaba FORM-0008, obtuve: ${cod}`);
});

check('ensureCodigo() no pisa un código ya asignado', () => {
  const sandbox = loadDigitalizador([{ id: 'a', nombre: 'A', codigo: 'FORM-0001' }]);
  vm.runInContext("tmpl.codigo = 'MI-CODIGO-A-MANO'; ensureCodigo();", sandbox);
  const cod = vm.runInContext('tmpl.codigo', sandbox);
  assert(cod === 'MI-CODIGO-A-MANO', `ensureCodigo() sobrescribió un código existente: ${cod}`);
});

check('códigos que no siguen el patrón FORM-#### no rompen la numeración automática', () => {
  const previas = [{ id: 'a', nombre: 'A', codigo: 'INSPECCION-EPP' }];
  const sandbox = loadDigitalizador(previas);
  const cod = vm.runInContext('tmpl.codigo', sandbox);
  assert(cod === 'FORM-0001', `esperaba FORM-0001 (ignorando código no estándar), obtuve: ${cod}`);
});

console.log(`\n${pass} pasaron, ${fail} fallaron (de ${pass + fail})`);
if (fail > 0) process.exit(1);
