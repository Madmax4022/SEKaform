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
      detalle: partes.join(' · '), estado: _agEstado(dias), cuando: prox || null, dias: dias, href: llenar(pid) });
  });

  (d.asignaciones || []).forEach(function (a) {
    var pid = a.plantilla_id || a.plantillaId, creado = new Date(a.creado_en || a.creadoEn || 0), quien = a.nombre || '';
    var hecho = envios.some(function (e) {
      return (e.plantilla_id || e.plantillaId) === pid && _agFecha(e) >= creado &&
        _agNorm(e.llenado_por || e.llenadoPor) === _agNorm(quien);
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
  var r = await Promise.all(['sbLoadPlantillas', 'sbLoadInspecciones', 'sbLoadAsignaciones', 'sbLoadEnvios', 'sbLoadUnidades', 'sbLoadOrg'].map(nube));
  var o = r[5] || {};
  var unir = function (cloud, loc) {   // la nube manda; lo local que aún no subió también cuenta
    if (!Array.isArray(cloud)) return loc;
    var ids = {}; cloud.forEach(function (x) { ids[x.id] = 1; });
    return cloud.concat(loc.filter(function (x) { return !ids[x.id]; }));
  };
  return {
    plantillas: unir(r[0], local('skf_plantillas')),
    inspecciones: unir(r[1], local('skf_inspecciones')),
    asignaciones: unir(r[2], local('skf_asignaciones')),
    envios: unir(r[3], local('skf_envios')),
    unidades: unir(r[4], local('skf_unidades')),
    turnosConfig: o.turnos_config || o.turnosConfig || null,
    org: r[5],
  };
}

if (typeof module !== 'undefined') module.exports = { skfAgenda: skfAgenda, skfAgendaHoy: skfAgendaHoy, skfAgendaCuando: skfAgendaCuando };
