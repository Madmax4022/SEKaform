// SEKaform — Agenda única: «qué se revisa, dónde, quién y cuándo».
//
// La app tenía tres maneras de decir lo mismo (Programadas, Asignaciones y Turnos).
// Aquí se juntan en UNA lista de pendientes con un solo vocabulario, que usan «Hoy»
// y «Plan». No cambia cómo se guarda cada cosa: solo cómo se presenta.
//
//   rutina  → inspección que se repite (antes «Programadas»): vence en una fecha.
//   encargo → formulario pedido a una persona (antes «Asignaciones»): pendiente hasta
//             que esa persona lo envía.
//   turno   → lo que se espera en el turno en curso (y lo que faltó en los de hoy).
//
// Cada ítem: { id, tipo, titulo, detalle, estado, cuando, dias, href }
//   estado: 'vencido' | 'hoy' | 'pronto' (≤7 días) | 'despues' | 'pendiente'
// Requiere form-library.js (skfEstadoTurnos) para los turnos; sin él, los omite.

var SKF_AGENDA_TIPOS = {
  rutina:  { ico: '🔁', nombre: 'Rutina' },
  encargo: { ico: '👤', nombre: 'Encargo' },
  turno:   { ico: '🕒', nombre: 'Turno' },
  equipo:  { ico: '🧯', nombre: 'Equipo' },
};
var SKF_FRECUENCIAS = { diaria: 'cada día', semanal: 'cada semana', quincenal: 'cada 15 días', mensual: 'cada mes',
  bimestral: 'cada 2 meses', trimestral: 'cada 3 meses', semestral: 'cada 6 meses', anual: 'cada año' };

function _agNorm(s) { return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim(); }
function _agFecha(e) { return new Date(e.enviado_en || e.enviadoEn || e.creado_en || e.creadoEn); }
function _agDias(fechaISO, ahora) {
  var hoy = new Date(ahora.getFullYear(), ahora.getMonth(), ahora.getDate());
  var d = new Date(String(fechaISO).slice(0, 10) + 'T00:00:00');
  return isNaN(d.getTime()) ? null : Math.round((d - hoy) / 864e5);
}
function _agEstado(dias) {
  if (dias === null) return 'pendiente';
  return dias < 0 ? 'vencido' : dias === 0 ? 'hoy' : dias <= 7 ? 'pronto' : 'despues';
}
function _agHora(d) { return d.toLocaleTimeString('es-CO', { hour: '2-digit', minute: '2-digit' }); }

// d = { plantillas, inspecciones, asignaciones, envios, unidades, turnosConfig } (nube o local, cualquier forma)
function skfAgenda(d, ahora) {
  ahora = ahora || new Date();
  d = d || {};
  var plantillas = d.plantillas || [], envios = d.envios || [], unidades = d.unidades || [];
  var nombrePlantilla = function (id) { var p = plantillas.find(function (x) { return x.id === id; }); return p ? p.nombre : ''; };
  var nombreLugar = function (id) { var u = id && unidades.find(function (x) { return x.id === id; }); return u ? u.nombre : ''; };
  var llenar = function (pid) { return pid && plantillas.some(function (x) { return x.id === pid; }) ? 'llenar.html?tmpl=' + encodeURIComponent(pid) : 'llenar.html'; };
  var items = [];

  (d.inspecciones || []).forEach(function (i) {
    if (i.activa === false) return;
    var pid = i.plantilla_id || i.plantillaId, prox = i.proximo_en || i.proximoEn;
    var dias = prox ? _agDias(prox, ahora) : null;
    var partes = [SKF_FRECUENCIAS[i.frecuencia] || i.frecuencia, nombreLugar(i.unidad_id || i.unidadId), i.responsable]
      .filter(Boolean);
    items.push({ id: 'r:' + i.id, tipo: 'rutina', titulo: i.nombre || nombrePlantilla(pid) || 'Inspección',
      detalle: partes.join(' · '), estado: _agEstado(dias), cuando: prox || null, dias: dias,
      href: llenar(pid) + ((i.unidad_id || i.unidadId) && llenar(pid) !== 'llenar.html' ? '&unidad=' + encodeURIComponent(i.unidad_id || i.unidadId) : '') });
  });

  (d.asignaciones || []).forEach(function (a) {
    var pid = a.plantilla_id || a.plantillaId, creado = new Date(a.creado_en || a.creadoEn || 0), quien = a.nombre || '';
    var hecho = envios.some(function (e) {
      if ((e.plantilla_id || e.plantillaId) !== pid || _agFecha(e) < creado) return false;
      var correo = _agNorm(a.correo), ec = _agNorm(e.llenado_correo || e.llenadoCorreo);
      return _agNorm(e.llenado_por || e.llenadoPor) === _agNorm(quien) || (correo && ec === correo);
    });
    if (hecho || a.completado_en || a.completadoEn) return;
    var lim = a.fecha_limite || a.fechaLimite, dias = lim ? _agDias(lim, ahora) : null;
    items.push({ id: 'e:' + a.id, tipo: 'encargo', titulo: a.plantilla_nombre || a.plantillaNombre || nombrePlantilla(pid) || 'Formulario',
      detalle: ['Para ' + (quien || 'alguien'), nombreLugar(a.unidad_id || a.unidadId)].filter(Boolean).join(' · '),
      estado: _agEstado(dias), cuando: lim || null, dias: dias, href: llenar(pid) });
  });

  if (typeof skfEstadoTurnos === 'function' && d.turnosConfig && (d.turnosConfig.turnos || []).length) {
    // Desde ayer: el turno de noche que terminó esta mañana empezó ayer y también es «de hoy».
    var inicioHoy = new Date(ahora.getFullYear(), ahora.getMonth(), ahora.getDate());
    skfEstadoTurnos(d.turnosConfig, envios, ahora, 1).forEach(function (t) {
      if (t.estado !== 'en_curso' && t.estado !== 'omitido') return;
      if (t.fin < inicioHoy) return;
      t.faltan.forEach(function (pid) {
        items.push({ id: 't:' + t.turno.id + ':' + pid + ':' + t.inicio.getTime(), tipo: 'turno',
          titulo: nombrePlantilla(pid) || 'Formulario del turno',
          detalle: 'Turno ' + t.turno.nombre + (t.estado === 'en_curso' ? ' · hasta las ' + _agHora(t.fin) : ' · terminó sin registrarse'),
          estado: t.estado === 'en_curso' ? 'hoy' : 'vencido', cuando: t.fin.toISOString(), dias: 0, href: llenar(pid) });
      });
    });
  }

  // Equipos (EXT-001…): inspección mensual que toca en ≤7 días y recarga que vence en ≤30.
  // Requiere field-types.js; sin él, se omiten. Tres o más del mismo tipo y motivo se
  // juntan en un solo ítem, para que 20 extintores no tapen el resto del día.
  if (typeof skfEquiposEstado === 'function') {
    var grupos = {};
    skfEquiposEstado(envios, plantillas, ahora, d.equiposBaja).forEach(function (q) {
      var base = llenar(q.plantillaId);
      var href = base + (base !== 'llenar.html' ? '&equipo=' + encodeURIComponent(q.codigo) : '');
      var add = function (motivo, dias, cuando, titulo, detalle) {
        var k = q.tipo.prefijo + ':' + motivo + ':' + (dias < 0 ? 'v' : 'p');
        (grupos[k] = grupos[k] || []).push({ id: 'q' + motivo.charAt(0) + ':' + q.codigo, tipo: 'equipo', ico: q.tipo.ico, codigo: q.codigo,
          motivo: motivo, titulo: titulo, detalle: detalle, estado: _agEstado(dias), cuando: cuando, dias: dias, href: href });
      };
      var lugar = nombreLugar(q.unidadId);
      if (q.diasInspeccion !== null && q.diasInspeccion <= 7) {
        var hace = q.ultima ? -_agDias(q.ultima, ahora) : null;
        add('inspeccion', q.diasInspeccion, q.proxima, q.codigo + ' · inspección mensual',
          [q.tipo.nombre, lugar, hace !== null ? 'última hace ' + hace + ' día' + (hace !== 1 ? 's' : '') : ''].filter(Boolean).join(' · '));
      }
      if (q.diasRecarga !== null && q.diasRecarga <= 30) {
        add('recarga', q.diasRecarga, q.recarga, q.codigo + (q.diasRecarga < 0 ? ' · recarga vencida' : ' · recarga por vencer'),
          [q.tipo.nombre, lugar].filter(Boolean).join(' · '));
      }
    });
    Object.keys(grupos).forEach(function (k) {
      var g = grupos[k];
      if (g.length < 3) { items.push.apply(items, g); return; }
      g.sort(function (a, b) { return a.dias - b.dias; });
      var t = skfEquipoTipo(k.split(':')[0]), venc = g[0].dias < 0, cods = g.map(function (x) { return x.codigo; });
      items.push({ id: 'qg:' + k, tipo: 'equipo', ico: t.ico, titulo: g.length + ' ' + t.plural + ' · ' +
          (g[0].motivo === 'recarga' ? (venc ? 'recarga vencida' : 'recarga por vencer') : (venc ? 'sin inspección al día' : 'toca inspeccionar')),
        detalle: cods.slice(0, 4).join(', ') + (cods.length > 4 ? ' y ' + (cods.length - 4) + ' más' : ''),
        estado: g[0].estado, cuando: g[0].cuando, dias: g[0].dias, href: g[0].href });
    });
  }

  var orden = { vencido: 0, hoy: 1, pronto: 2, pendiente: 3, despues: 4 };
  return items.sort(function (a, b) {
    return (orden[a.estado] - orden[b.estado]) || ((a.dias === null ? 999 : a.dias) - (b.dias === null ? 999 : b.dias)) ||
      String(a.titulo).localeCompare(String(b.titulo));
  });
}

// Lo que hay que mirar HOY: lo vencido, lo de hoy y los encargos abiertos sin fecha.
function skfAgendaHoy(items) {
  return (items || []).filter(function (i) { return i.estado === 'vencido' || i.estado === 'hoy' || i.estado === 'pendiente'; });
}

function skfAgendaCuando(i) {
  if (i.tipo === 'turno') return i.estado === 'vencido' ? 'Faltó' : 'Ahora';
  if (i.dias === null) return 'Sin fecha';
  if (i.dias < 0) return 'Venció hace ' + (-i.dias) + ' día' + (i.dias !== -1 ? 's' : '');
  if (i.dias === 0) return 'Hoy';
  if (i.dias === 1) return 'Mañana';
  if (i.dias <= 7) return 'En ' + i.dias + ' días';
  return new Date(String(i.cuando).slice(0, 10) + 'T00:00:00').toLocaleDateString('es-CO', { day: 'numeric', month: 'short' });
}

// Carga todo lo que la agenda necesita: de la nube si hay, si no del dispositivo.
async function skfAgendaDatos() {
  var local = function (k) { try { return JSON.parse(localStorage.getItem(k) || '[]'); } catch (e) { return []; } };
  var nube = async function (fn) { try { return typeof window[fn] === 'function' ? await window[fn]() : null; } catch (e) { return null; } };
  var r = await Promise.all(['sbLoadPlantillas', 'sbLoadInspecciones', 'sbLoadAsignaciones', 'sbLoadEnvios', 'sbLoadUnidades', 'sbLoadOrg', 'sbLoadEquiposBaja'].map(nube));
  var o = r[5] || {};
  var unir = function (cloud, loc) {   // la nube manda; lo local que aún no subió también cuenta
    if (!Array.isArray(cloud)) return loc;
    var ids = {}; cloud.forEach(function (x) { ids[x.id] = 1; });
    return cloud.concat(loc.filter(function (x) { return !ids[x.id]; }));
  };
  return {
    plantillas: unir(r[0], local('skf_plantillas')),
    // Una rutina recién cumplida en este dispositivo puede no haber subido aún: gana la más reciente.
    inspecciones: unir(r[1], local('skf_inspecciones')).map(function (i) {
      var l = local('skf_inspecciones').find(function (x) { return x.id === i.id; });
      return l && l !== i && String(l.ultimoCompletado || '') > String(i.ultimo_completado || i.ultimoCompletado || '') ? l : i;
    }),
    asignaciones: unir(r[2], local('skf_asignaciones')),
    envios: unir(r[3], local('skf_envios')),
    unidades: unir(r[4], local('skf_unidades')),
    turnosConfig: o.turnos_config || o.turnosConfig || null,
    equiposBaja: Array.isArray(r[6]) ? r[6] : local('skf_equipos_baja'),
    org: r[5],
  };
}

// ── Rutinas: llenar el formulario ES cumplir la rutina ────────────────────────
// Antes había que ir a «Programadas» y marcarla a mano; si no, el plan la seguía mostrando
// atrasada aunque la inspección ya estuviera hecha. Al enviar un formulario se completan las
// rutinas de ese formulario (en ese lugar, o sin lugar) que vencen en ≤7 días o ya vencieron.
var _SKF_PASO = { diaria: [0, 1], semanal: [0, 7], quincenal: [0, 15], mensual: [1, 0], bimestral: [2, 0],
  trimestral: [3, 0], semestral: [6, 0], anual: [12, 0] };
function _agISO(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
function skfAvanzarFecha(fechaISO, frecuencia) {
  var p = _SKF_PASO[frecuencia] || _SKF_PASO.mensual;
  var d = new Date(String(fechaISO).slice(0, 10) + 'T00:00:00');
  if (isNaN(d.getTime())) return fechaISO;
  if (p[0]) {                       // meses: el 31 de enero + 1 mes = 28/29 de febrero, no 3 de marzo
    var dia = d.getDate(); d.setDate(1); d.setMonth(d.getMonth() + p[0]);
    d.setDate(Math.min(dia, new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate()));
  } else d.setDate(d.getDate() + p[1]);
  return _agISO(d);
}
// Devuelve las rutinas que este envío completa, ya actualizadas (no modifica las originales).
function skfRutinasCompletadas(inspecciones, plantillaId, unidadId, ahora) {
  ahora = ahora || new Date();
  return (inspecciones || []).filter(function (i) {
    if (i.activa === false || (i.plantillaId || i.plantilla_id) !== plantillaId) return false;
    var u = i.unidadId || i.unidad_id || null;
    if (u && u !== unidadId) return false;
    var dias = _agDias(i.proximoEn || i.proximo_en, ahora);
    return dias !== null && dias <= 7;
  }).map(function (i) {
    var n = Object.assign({}, i), hoy = _agISO(ahora), prox = n.proximoEn || n.proximo_en;
    do { prox = skfAvanzarFecha(prox, n.frecuencia); } while (prox <= hoy);
    n.proximoEn = prox; delete n.proximo_en;
    n.ultimoCompletado = ahora.toISOString();
    return n;
  });
}

// ── Personas: UNA lista con el equipo (con cuenta), las invitaciones y los contactos sin
// cuenta que ya aparecen en encargos y rutinas. Así se elige a alguien en vez de escribirlo
// cada vez. equipo = respuesta de /api/equipo (o null sin conexión / sin migración).
function skfPersonas(d, equipo) {
  d = d || {}; var porClave = {}, out = [];
  var agregar = function (p) {
    var k = p.correo ? 'c:' + _agNorm(p.correo) : 'n:' + _agNorm(p.nombre);
    var kn = 'n:' + _agNorm(p.nombre);
    var ya = porClave[k] || (p.nombre && porClave[kn]);
    if (ya) {                                  // misma persona: se completa lo que falte
      if (!ya.correo && p.correo) { ya.correo = p.correo; porClave['c:' + _agNorm(p.correo)] = ya; }
      if (ya.tipo === 'contacto' && p.tipo !== 'contacto') { ya.tipo = p.tipo; ya.rol = p.rol; ya.userId = p.userId; ya.invId = p.invId; ya.soyYo = p.soyYo; }
      if (!ya.nombre && p.nombre) ya.nombre = p.nombre;
      return ya;
    }
    var n = Object.assign({ pendientes: 0, rutinas: 0 }, p);
    porClave[k] = n; if (n.nombre) porClave[kn] = porClave[kn] || n; out.push(n); return n;
  };
  ((equipo && equipo.miembros) || []).forEach(function (m) { agregar({ tipo: 'cuenta', nombre: m.nombre || m.email, correo: m.email, rol: m.rol, userId: m.id, soyYo: !!m.soyYo }); });
  ((equipo && equipo.invitaciones) || []).forEach(function (i) { agregar({ tipo: 'invitado', nombre: '', correo: i.email, rol: i.rol, invId: i.id, expira: i.expira }); });
  var pend = {}; skfAgenda(d, new Date()).forEach(function (i) { if (i.tipo === 'encargo') pend[i.id.slice(2)] = 1; });
  (d.asignaciones || []).forEach(function (a) {
    if (!a.nombre) return;
    var p = agregar({ tipo: 'contacto', nombre: a.nombre, correo: a.correo || '' });
    if (pend[a.id]) p.pendientes++;
  });
  (d.inspecciones || []).forEach(function (i) {
    if (!i.responsable || i.activa === false) return;
    var p = agregar({ tipo: 'contacto', nombre: i.responsable, correo: i.correo || '' }); p.rutinas++;
  });
  var orden = { cuenta: 0, invitado: 1, contacto: 2 };
  return out.sort(function (a, b) { return (orden[a.tipo] - orden[b.tipo]) || String(a.nombre || a.correo).localeCompare(String(b.nombre || b.correo)); });
}

if (typeof module !== 'undefined') module.exports = { skfPersonas: skfPersonas, skfAgenda: skfAgenda, skfAgendaHoy: skfAgendaHoy, skfAgendaCuando: skfAgendaCuando, skfAvanzarFecha: skfAvanzarFecha, skfRutinasCompletadas: skfRutinasCompletadas };
