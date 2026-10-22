// Agenda única (agenda.js): rutinas, encargos y turnos en una sola lista ordenada.
// Ejecutar: node tests/agenda.test.cjs
const fs = require('fs'), path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'form-library.js'), 'utf8') + '\n' +
  fs.readFileSync(path.join(__dirname, '..', 'agenda.js'), 'utf8').replace(/if \(typeof module[^\n]*\n?$/, '') +
  ';module.exports={skfPersonas,skfAgenda,skfAgendaHoy,skfAgendaCuando,skfAvanzarFecha,skfRutinasCompletadas};';
const m = { exports: {} };
new Function('module', 'require', src)(m, require);
const { skfPersonas, skfAgenda, skfAgendaHoy, skfAgendaCuando, skfAvanzarFecha, skfRutinasCompletadas } = m.exports;

let ok = 0, fail = 0;
function t(n, fn) { try { fn(); ok++; } catch (e) { fail++; console.log('FAIL: ' + n + '\n   ' + e.message); } }
function eq(a, b, msg) { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error((msg || '') + ' esperado ' + JSON.stringify(b) + ' pero fue ' + JSON.stringify(a)); }

const AHORA = new Date(2026, 9, 22, 10, 0);       // 22-oct-2026 10:00 local
const F = d => { const x = new Date(2026, 9, 22 + d); return x.getFullYear() + '-' + String(x.getMonth() + 1).padStart(2, '0') + '-' + String(x.getDate()).padStart(2, '0'); };
const PL = [{ id: 'p1', nombre: 'Lista SST' }, { id: 'p2', nombre: 'Extintores' }, { id: 'p3', nombre: 'Entrega de turno' }];
const UN = [{ id: 'u1', nombre: 'Bodega' }];

t('rutinas: vencida, hoy, pronto, después; formas nube y local', () => {
  const a = skfAgenda({ plantillas: PL, unidades: UN, inspecciones: [
    { id: 'a', plantilla_id: 'p2', nombre: 'Extintores', proximo_en: F(-3), frecuencia: 'mensual', unidad_id: 'u1' },
    { id: 'b', plantillaId: 'p1', proximoEn: F(0), frecuencia: 'semanal' },
    { id: 'c', plantillaId: 'p1', proximoEn: F(5) },
    { id: 'd', plantillaId: 'p1', proximoEn: F(30) },
    { id: 'e', plantillaId: 'p1', proximoEn: F(-1), activa: false },
  ] }, AHORA);
  eq(a.map(i => i.estado), ['vencido', 'hoy', 'pronto', 'despues']);
  eq(a[0].detalle, 'cada mes · Bodega');
  eq(a[1].titulo, 'Lista SST', 'sin nombre propio usa el del formulario');
  eq(a[0].href, 'llenar.html?tmpl=p2&unidad=u1');
});

t('encargos: pendiente hasta que ESA persona envía, después de encargarlo', () => {
  const asg = [{ id: 'x', plantillaId: 'p1', nombre: 'Ana Pérez', creadoEn: '2026-10-20T00:00:00' },
               { id: 'y', plantillaId: 'p1', nombre: 'Beto', creadoEn: '2026-10-20T00:00:00' },
               { id: 'z', plantillaId: 'p1', nombre: 'Cris', creadoEn: '2026-10-20T00:00:00' }];
  const env = [{ plantillaId: 'p1', llenadoPor: 'ana perez', creadoEn: '2026-10-21T00:00:00' },   // Ana: hecho (sin tildes/mayúsculas)
               { plantillaId: 'p1', llenadoPor: 'Beto', creadoEn: '2026-10-19T00:00:00' }];      // Beto: antes del encargo → no cuenta
  const a = skfAgenda({ plantillas: PL, asignaciones: asg, envios: env }, AHORA);
  eq(a.map(i => i.detalle), ['Para Beto', 'Para Cris']);
  eq(a.every(i => i.estado === 'pendiente'), true, 'sin fecha límite → pendiente');
});

t('encargo con fecha límite vencida se ordena primero', () => {
  const a = skfAgenda({ plantillas: PL, asignaciones: [
    { id: 'x', plantillaId: 'p1', nombre: 'Ana', creadoEn: '2026-10-01', fecha_limite: F(-2) }],
    inspecciones: [{ id: 'b', plantillaId: 'p1', proximoEn: F(0) }] }, AHORA);
  eq(a.map(i => i.tipo), ['encargo', 'rutina']);
});

t('turnos: lo que falta del turno en curso y lo omitido hoy', () => {
  const cfg = { turnos: [{ id: 'n', nombre: 'Noche', inicio: '22:00', fin: '06:00' }, { id: 'm', nombre: 'Mañana', inicio: '06:00', fin: '14:00' }],
                esperado: ['p3'] };
  const a = skfAgenda({ plantillas: PL, turnosConfig: cfg, envios: [] }, AHORA);
  eq(a.map(i => [i.tipo, i.estado, i.titulo]), [['turno', 'vencido', 'Entrega de turno'], ['turno', 'hoy', 'Entrega de turno']]);
  const b = skfAgenda({ plantillas: PL, turnosConfig: cfg,
    envios: [{ plantillaId: 'p3', enviadoEn: new Date(2026, 9, 22, 7).toISOString() }] }, AHORA);
  eq(b.map(i => i.estado), ['vencido'], 'el turno en curso ya cumplió; solo queda el de la noche');
});

t('sin datos: lista vacía, sin errores', () => { eq(skfAgenda({}, AHORA), []); eq(skfAgenda(null, AHORA), []); });

t('Hoy = vencido + hoy + encargos sin fecha (no lo de la semana)', () => {
  const a = skfAgenda({ plantillas: PL,
    inspecciones: [{ id: 'a', plantillaId: 'p1', proximoEn: F(-1) }, { id: 'c', plantillaId: 'p1', proximoEn: F(3) }],
    asignaciones: [{ id: 'x', plantillaId: 'p1', nombre: 'Ana', creadoEn: '2026-10-01' }] }, AHORA);
  eq(skfAgendaHoy(a).map(i => i.estado), ['vencido', 'pendiente']);
});

t('textos de cuándo', () => {
  eq(skfAgendaCuando({ tipo: 'rutina', dias: -1 }), 'Venció hace 1 día');
  eq(skfAgendaCuando({ tipo: 'rutina', dias: -4 }), 'Venció hace 4 días');
  eq(skfAgendaCuando({ tipo: 'rutina', dias: 0 }), 'Hoy');
  eq(skfAgendaCuando({ tipo: 'rutina', dias: 1 }), 'Mañana');
  eq(skfAgendaCuando({ tipo: 'encargo', dias: null }), 'Sin fecha');
  eq(skfAgendaCuando({ tipo: 'turno', estado: 'vencido' }), 'Faltó');
});

t('formulario borrado: el enlace cae en la lista, no en uno inexistente', () => {
  const a = skfAgenda({ plantillas: [], inspecciones: [{ id: 'a', plantillaId: 'zz', nombre: 'X', proximoEn: F(0) }] }, AHORA);
  eq(a[0].href, 'llenar.html');
});

t('avanzar fechas: días, semanas y meses sin desbordar el fin de mes', () => {
  eq(skfAvanzarFecha('2026-10-22', 'diaria'), '2026-10-23');
  eq(skfAvanzarFecha('2026-10-22', 'semanal'), '2026-10-29');
  eq(skfAvanzarFecha('2026-10-22', 'quincenal'), '2026-11-06');
  eq(skfAvanzarFecha('2026-01-31', 'mensual'), '2026-02-28');
  eq(skfAvanzarFecha('2028-01-31', 'mensual'), '2028-02-29', 'bisiesto');
  eq(skfAvanzarFecha('2026-11-30', 'trimestral'), '2027-02-28');
  eq(skfAvanzarFecha('2026-10-22', 'anual'), '2027-10-22');
});

t('llenar el formulario completa la rutina de ese formulario y lugar', () => {
  const ins = [
    { id: 'a', plantillaId: 'p2', unidadId: 'u1', frecuencia: 'mensual', proximoEn: F(-3) },   // vencida, mismo lugar → sí
    { id: 'b', plantillaId: 'p2', unidadId: 'u2', frecuencia: 'mensual', proximoEn: F(0) },    // otro lugar → no
    { id: 'c', plantillaId: 'p2', frecuencia: 'semanal', proximoEn: F(2) },                    // sin lugar, vence pronto → sí
    { id: 'd', plantillaId: 'p2', frecuencia: 'mensual', proximoEn: F(20) },                   // aún lejos → no
    { id: 'e', plantillaId: 'p1', frecuencia: 'mensual', proximoEn: F(0) },                    // otro formulario → no
    { id: 'f', plantillaId: 'p2', frecuencia: 'mensual', proximoEn: F(0), activa: false },     // inactiva → no
  ];
  const r = skfRutinasCompletadas(ins, 'p2', 'u1', AHORA);
  eq(r.map(i => i.id), ['a', 'c']);
  eq(r[0].proximoEn, '2026-11-19', 'vencida el 19-oct: la próxima es el 19-nov');
  eq(r[1].proximoEn, '2026-10-31', 'semanal del 24-oct: la próxima es el 31-oct');
  eq(!!r[0].ultimoCompletado, true);
  eq(ins[0].proximoEn, F(-3), 'no modifica la lista original');
});

t('una rutina atrasada varios ciclos salta hasta una fecha futura', () => {
  const r = skfRutinasCompletadas([{ id: 'a', plantillaId: 'p', frecuencia: 'semanal', proximoEn: F(-20) }], 'p', null, AHORA);
  eq(r[0].proximoEn, F(1), '2-oct + 7 + 7 + 7 = 23-oct');
});

t('la rutina con lugar abre el formulario con ese lugar elegido', () => {
  const a = skfAgenda({ plantillas: PL, inspecciones: [{ id: 'a', plantillaId: 'p2', unidadId: 'u1', proximoEn: F(0) }] }, AHORA);
  eq(a[0].href, 'llenar.html?tmpl=p2&unidad=u1');
});

t('encargo a alguien con cuenta: se cumple cuando lo llena desde la app (por su correo)', () => {
  const asg = [{ id: 'x', plantillaId: 'p1', nombre: 'Luisa', correo: 'luisa@x.co', creadoEn: '2026-10-20T00:00:00' }];
  const env = [{ plantillaId: 'p1', llenadoPor: 'Luisa Fernanda Ríos', llenadoCorreo: 'LUISA@x.co', creadoEn: '2026-10-21T00:00:00' }];
  eq(skfAgenda({ plantillas: PL, asignaciones: asg, envios: env }, AHORA).length, 0);
});

t('Personas: una lista sin duplicados, equipo primero, contactos con sus pendientes', () => {
  const equipo = { miembros: [{ id: 'u1', email: 'ana@x.co', nombre: 'Ana Pérez', rol: 'dueno', soyYo: true },
                              { id: 'u2', email: 'luis@x.co', nombre: 'Luis', rol: 'editor' }],
                   invitaciones: [{ id: 'i1', email: 'nuevo@x.co', rol: 'lector' }] };
  const d = { plantillas: PL,
    asignaciones: [{ id: 'a1', plantillaId: 'p1', nombre: 'luis', correo: 'LUIS@x.co', creadoEn: '2026-10-20' },   // = Luis (por correo)
                   { id: 'a2', plantillaId: 'p1', nombre: 'Carlos Ruiz', creadoEn: '2026-10-20' },
                   { id: 'a3', plantillaId: 'p2', nombre: 'carlos ruiz', creadoEn: '2026-10-20' }],                 // = Carlos (por nombre)
    inspecciones: [{ id: 'r1', plantillaId: 'p2', responsable: 'Carlos Ruiz', proximoEn: F(5) },
                   { id: 'r2', plantillaId: 'p2', responsable: 'Marta', proximoEn: F(5), activa: false }],
    envios: [] };
  const ps = skfPersonas(d, equipo);
  eq(ps.map(p => [p.tipo, p.nombre || p.correo]), [['cuenta', 'Ana Pérez'], ['cuenta', 'Luis'], ['invitado', 'nuevo@x.co'], ['contacto', 'Carlos Ruiz']]);
  eq(ps[1].pendientes, 1, 'el encargo de Luis cuenta para Luis');
  eq([ps[3].pendientes, ps[3].rutinas], [2, 1]);
  eq(ps[0].soyYo, true);
});

t('Personas sin conexión (sin equipo): solo los contactos', () => {
  const ps = skfPersonas({ asignaciones: [{ id: 'a', plantillaId: 'p1', nombre: 'Eva', creadoEn: '2026-10-20' }] }, null);
  eq(ps.map(p => p.tipo + ':' + p.nombre), ['contacto:Eva']);
});

console.log(`${ok} pasaron, ${fail} fallaron (de ${ok + fail})`);
process.exit(fail ? 1 : 0);
