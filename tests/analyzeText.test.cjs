// Batería de regresión para analyzeText() (digitalizador.html).
//
// No usa dependencias externas: extrae el <script> inline del HTML real (más
// field-types.js, del que depende para TIPO_MAP) y lo ejecuta en un contexto
// vm con stubs mínimos para document/window/etc, así que prueba el código de
// producción tal cual, sin navegador ni red.
//
// Ejecutar: node tests/analyzeText.test.cjs

const vm = require('vm');
const fs = require('fs');
const path = require('path');

const HTML_PATH = path.join(__dirname, '..', 'digitalizador.html');
const FIELD_TYPES_PATH = path.join(__dirname, '..', 'field-types.js');

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

function loadAnalyzeText() {
  const html = fs.readFileSync(HTML_PATH, 'utf8');
  const match = html.match(/<script>([\s\S]*?)<\/script>/);
  if (!match) throw new Error('No se encontró el <script> inline en digitalizador.html');
  const mainScript = match[1];

  const sandbox = { console, setTimeout, clearTimeout, clearInterval, setInterval, Promise, URLSearchParams };
  sandbox.document = makeStub();
  sandbox.window = sandbox;
  sandbox.localStorage = makeStub();
  sandbox.navigator = makeStub();
  sandbox.location = makeStub();
  sandbox.history = makeStub();

  vm.createContext(sandbox);
  const fieldTypesScript = fs.readFileSync(FIELD_TYPES_PATH, 'utf8');
  vm.runInContext(fieldTypesScript, sandbox, { filename: 'field-types.js' });
  vm.runInContext(mainScript, sandbox, { filename: 'digitalizador-inline.js' });

  if (typeof sandbox.analyzeText !== 'function') {
    throw new Error('analyzeText no quedó definida tras ejecutar el script inline');
  }
  return sandbox.analyzeText;
}

// --- Casos de prueba -------------------------------------------------
// Cada caso fija los campos esperados (etiqueta, tipo, opciones) verificados
// manualmente contra el comportamiento real de la app durante las sesiones
// de corrección de heurísticas de OCR/checklist/radio.

const cases = [
  {
    name: 'Checklist con encabezado en minúsculas y lista numerada',
    text: `CHECKLIST DOCUMENTOS PERSONAL

informacion general
1. cedula de ciudadania
2. hoja de vida actualizada
3. certificado de estudios
4. certificado laboral
5. examen medico ocupacional
nombre del trabajador:
fecha de elaboracion
firma del responsable`,
    expected: [
      { etiqueta: 'CHECKLIST DOCUMENTOS PERSONAL', tipo: 'separador' },
      { etiqueta: 'Informacion general', tipo: 'separador' },
      { etiqueta: 'Cedula de ciudadania', tipo: 'numero' },
      { etiqueta: 'Hoja de vida actualizada', tipo: 'si_no' },
      { etiqueta: 'Certificado de estudios', tipo: 'si_no' },
      { etiqueta: 'Certificado laboral', tipo: 'si_no' },
      { etiqueta: 'Examen medico ocupacional', tipo: 'select' },
      { etiqueta: 'Nombre del trabajador', tipo: 'texto' },
      { etiqueta: 'Fecha de elaboracion', tipo: 'fecha_auto' },
      { etiqueta: 'Firma del responsable', tipo: 'firma' },
    ],
  },
  {
    name: 'Lista numerada con dos puntos NO debe forzarse a si_no (guarda de regresión)',
    text: `REGISTRO DE ASISTENCIA

1. Nombre completo:
2. Cargo:
3. Firma:
4. Telefono de contacto:`,
    expected: [
      { etiqueta: 'REGISTRO DE ASISTENCIA', tipo: 'separador' },
      { etiqueta: 'Nombre completo', tipo: 'texto' },
      { etiqueta: 'Cargo', tipo: 'select', opciones: ['Operario', 'Técnico', 'Auxiliar', 'Profesional', 'Supervisor', 'Coordinador', 'Jefe', 'Gerente', 'Otro'] },
      { etiqueta: 'Firma', tipo: 'firma' },
      { etiqueta: 'Telefono de contacto', tipo: 'telefono' },
    ],
  },
  {
    name: 'Glifos de radio/checkbox, paréntesis vacíos y desambiguación de etiquetas duplicadas',
    text: `FICHA CLINICA

Nombre:
Sexo ○Masculino ○Femenino
Estado civil: ○Soltero ○Casado ○Otro

Datos Clinicos
1. Diabetes
( ) E. Endocrinas
( ) Hipertension
¿Padece alguna enfermedad cronica? ○No ○Si (Cual)

CONTRATO DE COMPRA-VENTA
Vendedor
Nombre:
Direccion:
Comprador
Nombre:
Direccion:`,
    expected: [
      { etiqueta: 'FICHA CLINICA', tipo: 'texto' },
      { etiqueta: 'Nombre', tipo: 'texto' },
      { etiqueta: 'Sexo', tipo: 'radio', opciones: ['Masculino', 'Femenino'] },
      { etiqueta: 'Estado civil', tipo: 'radio', opciones: ['Soltero', 'Casado', 'Otro'] },
      { etiqueta: 'Datos Clinicos', tipo: 'separador' },
      { etiqueta: 'Diabetes', tipo: 'si_no' },
      { etiqueta: 'E. Endocrinas', tipo: 'si_no' },
      { etiqueta: 'Hipertension', tipo: 'si_no' },
      { etiqueta: '¿Padece alguna enfermedad cronica?', tipo: 'si_no' },
      { etiqueta: 'CONTRATO DE COMPRA-VENTA', tipo: 'texto' },
      { etiqueta: 'Vendedor', tipo: 'texto' },
      { etiqueta: 'Nombre (Vendedor)', tipo: 'texto' },
      { etiqueta: 'Direccion', tipo: 'texto' },
      { etiqueta: 'Comprador', tipo: 'texto' },
      { etiqueta: 'Nombre (Comprador)', tipo: 'texto' },
      { etiqueta: 'Direccion (Comprador)', tipo: 'texto' },
    ],
  },
];

// --- Runner mínimo -----------------------------------------------------

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function normalizeField(f) {
  return { etiqueta: f.etiqueta, tipo: f.tipo, opciones: f.opciones };
}

function run() {
  const analyzeText = loadAnalyzeText();
  let pass = 0;
  let fail = 0;

  for (const c of cases) {
    const actualFields = analyzeText(c.text).map(normalizeField);
    const expectedFields = c.expected.map(e => ({ etiqueta: e.etiqueta, tipo: e.tipo, opciones: e.opciones }));

    if (deepEqual(actualFields, expectedFields)) {
      pass++;
      console.log(`PASS: ${c.name}`);
    } else {
      fail++;
      console.log(`FAIL: ${c.name}`);
      console.log('  esperado:', JSON.stringify(expectedFields));
      console.log('  obtenido:', JSON.stringify(actualFields));
    }
  }

  console.log(`\n${pass} pasaron, ${fail} fallaron (de ${cases.length})`);
  if (fail > 0) process.exit(1);
}

run();
