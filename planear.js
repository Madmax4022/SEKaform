// SEKaform — «＋ Planear»: una sola conversación para decir qué se revisa, cada cuánto,
// dónde y quién. Reemplaza tener que elegir antes entre «Programadas», «Asignaciones» y
// «Turnos» (tres pantallas, tres formularios distintos para la misma idea).
//
// Según la respuesta a «¿cada cuánto?» guarda lo mismo que guardaban esas pantallas:
//   Se repite      → rutina   (skf_inspecciones · sync 'inspeccion')
//   Una sola vez   → encargo  (skf_asignaciones · sync 'asignacion', uno por persona)
//   En cada turno  → turno    (organizations.turnos_config.esperado · solo administradores)
// Requiere skf-api.js, sidebar.js (skfSheet) y agenda.js (SKF_FRECUENCIAS).

var SKF_PW_FRECS = [['diaria', 'Cada día'], ['semanal', 'Cada semana'], ['quincenal', 'Cada 15 días'], ['mensual', 'Cada mes'],
  ['trimestral', 'Cada 3 meses'], ['semestral', 'Cada 6 meses'], ['anual', 'Cada año']];

function _pwEsc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;'); }
function _pwLee(k, def) { try { var v = JSON.parse(localStorage.getItem(k) || 'null'); return v == null ? def : v; } catch (e) { return def; } }
function _pwHoy() { var d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
function _pwFecha(iso) { return iso ? new Date(iso + 'T00:00:00').toLocaleDateString('es-CO', { weekday: 'short', day: 'numeric', month: 'short' }) : ''; }
function _pwLista(nombres) { return nombres.length <= 1 ? (nombres[0] || '') : nombres.slice(0, -1).join(', ') + ' y ' + nombres[nombres.length - 1]; }

// Frase que resume lo planeado, en palabras de la persona (se muestra antes de guardar).
function skfPlanFrase(st) {
  var f = '«' + (st.plantilla ? st.plantilla.nombre : '…') + '»';
  var lugar = st.lugarNombre ? ' en ' + st.lugarNombre : '';
  if (st.modo === 'turno') return f + ' se espera en cada turno' + (st.turnos && st.turnos.length ? ' (' + _pwLista(st.turnos) + ')' : '') + '.';
  if (st.modo === 'repite') {
    var fr = (SKF_PW_FRECS.find(function (x) { return x[0] === st.frecuencia; }) || [, ''])[1].toLowerCase();
    return f + ' se revisa ' + fr + lugar + (st.responsable ? ', a cargo de ' + st.responsable : '') + '. Primera vez: ' + _pwFecha(st.inicio) + '.';
  }
  var quienes = (st.personas || []).map(function (p) { return p.nombre; }).filter(Boolean);
  return f + lugar + ' — encargado a ' + (_pwLista(quienes) || '…') + (st.limite ? ', para el ' + _pwFecha(st.limite) : '') + '.';
}

async function skfPlanear(opts) {
  opts = opts || {};
  var plantillas = (opts.plantillas && opts.plantillas.length ? opts.plantillas : _pwLee('skf_plantillas', []))
    .filter(function (p) { return p && p.id && p.nombre; })
    .sort(function (a, b) { return (b.favorito ? 1 : 0) - (a.favorito ? 1 : 0) || String(a.nombre).localeCompare(String(b.nombre)); });
  var lugares = _pwLee('skf_unidades', []);
  var org = null, rol = null;
  try { org = typeof sbLoadOrg === 'function' ? await sbLoadOrg() : null; } catch (e) {}
  try { rol = typeof skfRol === 'function' ? await skfRol() : null; } catch (e) {}
  var cfgTurnos = (org && (org.turnosConfig || org.turnos_config)) || _pwLee('skf_turnos_cfg', null) || { turnos: [], esperado: [] };
  var hayTurnos = (cfgTurnos.turnos || []).length > 0, esAdmin = rol === 'dueno' || rol === 'admin';
  var demo = typeof skfDemoActivo === 'function' && skfDemoActivo();

  var st = { paso: 0, plantilla: opts.plantillaId ? plantillas.find(function (p) { return p.id === opts.plantillaId; }) || null : null,
    modo: opts.modo || null, frecuencia: 'mensual', inicio: _pwHoy(), limite: '', lugar: null, lugarNombre: '', nuevoLugar: '',
    personas: [{ nombre: '', correo: '' }], responsable: '', buscar: '',
    turnos: (cfgTurnos.turnos || []).map(function (t) { return t.nombre; }) };

  var PASOS = ['que', 'cuando', 'donde', 'quien', 'listo'];
  var pasos = function () { return st.modo === 'turno' ? ['que', 'cuando', 'listo'] : PASOS; };

  var guardado = false;
  var cuerpo = skfSheet('Planear', '<div id="pwPaso"></div>', opts.origen, function () { if (guardado && opts.alCerrar) opts.alCerrar(); });
  var hoja = cuerpo.closest('.skf-sheet');
  hoja.classList.add('pw-hoja');
  var pie = document.createElement('div');
  pie.className = 'pw-pie';
  pie.innerHTML = '<button type="button" class="pw-atras" id="pwAtras">‹ Atrás</button><button type="button" class="pw-sig" id="pwSig">Siguiente</button>';
  hoja.appendChild(pie);
  var $ = function (id) { return document.getElementById(id); };

  function valido() {
    var p = pasos()[st.paso];
    if (p === 'que') return !!st.plantilla;
    if (p === 'cuando') return st.modo === 'una' || (st.modo === 'repite' && st.frecuencia && st.inicio) || (st.modo === 'turno' && hayTurnos && esAdmin && !demo);
    if (p === 'donde') return st.lugar !== 'nuevo' || !!st.nuevoLugar.trim();
    if (p === 'quien') return st.modo !== 'una' || st.personas.some(function (x) { return x.nombre.trim(); });
    return true;
  }
  function refrescarPie() {
    var p = pasos()[st.paso];
    $('pwAtras').style.visibility = st.paso === 0 ? 'hidden' : 'visible';
    $('pwSig').textContent = p === 'listo' ? 'Guardar' : 'Siguiente';
    $('pwSig').disabled = !valido();
  }

  function pintar() {
    var p = pasos()[st.paso], n = pasos().length, html = '';
    html += '<div class="pw-prog" aria-hidden="true">' + pasos().map(function (_, i) { return '<span class="' + (i <= st.paso ? 'on' : '') + '"></span>'; }).join('') + '</div>';
    html += '<div class="pw-num">Paso ' + (st.paso + 1) + ' de ' + n + '</div>';

    if (p === 'que') {
      html += '<h3 class="pw-q">¿Qué se revisa?</h3>';
      if (!plantillas.length) {
        html += '<p class="pw-nota">Aún no tienes formularios. Agrega uno del catálogo y vuelve aquí.</p><a class="skf-opt" href="plantillas.html"><span class="so-ico">📚</span><span class="so-txt"><b>Formularios listos</b><small>Catálogo por norma</small></span><span class="so-arr">›</span></a>';
      } else {
        if (plantillas.length > 6) html += '<input class="pw-inp" id="pwBuscar" type="search" placeholder="Buscar formulario…" aria-label="Buscar formulario" value="' + _pwEsc(st.buscar) + '">';
        var b = st.buscar.trim().toLowerCase();
        html += '<div class="pw-lista" role="radiogroup" aria-label="Formulario">' + plantillas
          .filter(function (x) { return !b || x.nombre.toLowerCase().indexOf(b) !== -1; })
          .map(function (x) {
            var on = st.plantilla && st.plantilla.id === x.id;
            return '<button type="button" class="pw-op' + (on ? ' on' : '') + '" role="radio" aria-checked="' + on + '" data-pl="' + _pwEsc(x.id) + '"><span class="pw-ico">' + (x.favorito ? '⭐' : '📋') + '</span><span class="pw-t">' + _pwEsc(x.nombre) + '</span><span class="pw-ck" aria-hidden="true">' + (on ? '✓' : '') + '</span></button>';
          }).join('') + '</div><a class="skf-sheet-mas" href="plantillas.html">¿No está? Buscar en el catálogo ›</a>';
      }
    }

    if (p === 'cuando') {
      html += '<h3 class="pw-q">¿Cada cuánto?</h3>';
      var tile = function (k, ico, t, s, dis) {
        return '<button type="button" class="pw-tile' + (st.modo === k ? ' on' : '') + '" data-modo="' + k + '"' + (dis ? ' aria-disabled="true"' : '') + ' role="radio" aria-checked="' + (st.modo === k) + '"><span class="pw-ico">' + ico + '</span><span><b>' + t + '</b><small>' + s + '</small></span></button>';
      };
      html += '<div role="radiogroup" aria-label="Frecuencia">' +
        tile('repite', '🔁', 'Se repite', 'Ej.: cada mes, cada semana') +
        tile('una', '👤', 'Una sola vez, a una persona', 'Le encargas el formulario y ves si lo llenó') +
        tile('turno', '🕒', 'En cada turno', !hayTurnos ? 'Primero define tus turnos' : !esAdmin ? 'Solo un administrador puede cambiarlo' : demo ? 'No disponible en el modo ejemplo' : 'Se espera en ' + _pwLista(st.turnos), !hayTurnos || !esAdmin || demo) + '</div>';
      if (st.modo === 'turno' && !hayTurnos) html += '<a class="skf-sheet-mas" href="turnos.html">Definir mis turnos ›</a>';
      if (st.modo === 'repite') {
        html += '<div class="pw-sub">Frecuencia</div><div class="pw-chips">' + SKF_PW_FRECS.map(function (f) {
          return '<button type="button" class="pw-chip' + (st.frecuencia === f[0] ? ' on' : '') + '" data-frec="' + f[0] + '" aria-pressed="' + (st.frecuencia === f[0]) + '">' + f[1] + '</button>';
        }).join('') + '</div>';
        html += '<label class="pw-sub" for="pwInicio">¿Cuándo es la primera vez?</label><input class="pw-inp" type="date" id="pwInicio" value="' + st.inicio + '">';
      }
      if (st.modo === 'una') html += '<label class="pw-sub" for="pwLimite">¿Para cuándo? (opcional)</label><input class="pw-inp" type="date" id="pwLimite" value="' + st.limite + '" min="' + _pwHoy() + '">';
    }

    if (p === 'donde') {
      html += '<h3 class="pw-q">¿Dónde?</h3><div class="pw-chips">';
      html += '<button type="button" class="pw-chip' + (st.lugar === null ? ' on' : '') + '" data-lugar="" aria-pressed="' + (st.lugar === null) + '">En cualquier lugar</button>';
      html += lugares.map(function (u) { return '<button type="button" class="pw-chip' + (st.lugar === u.id ? ' on' : '') + '" data-lugar="' + _pwEsc(u.id) + '" aria-pressed="' + (st.lugar === u.id) + '">📍 ' + _pwEsc(u.nombre) + '</button>'; }).join('');
      html += '<button type="button" class="pw-chip' + (st.lugar === 'nuevo' ? ' on' : '') + '" data-lugar="nuevo" aria-pressed="' + (st.lugar === 'nuevo') + '">＋ Nuevo lugar</button></div>';
      if (st.lugar === 'nuevo') html += '<input class="pw-inp" id="pwNuevoLugar" placeholder="Ej.: Bodega, Sede Norte, Cocina" aria-label="Nombre del lugar nuevo" value="' + _pwEsc(st.nuevoLugar) + '">';
    }

    if (p === 'quien') {
      if (st.modo === 'una') {
        html += '<h3 class="pw-q">¿A quién se lo encargas?</h3><p class="pw-nota">Le compartes un enlace para llenarlo, sin cuenta. Cuando lo envíe con su nombre, el encargo se marca hecho.</p>';
        html += st.personas.map(function (x, i) {
          return '<div class="pw-persona"><input class="pw-inp" data-pn="' + i + '" placeholder="Nombre" aria-label="Nombre de la persona ' + (i + 1) + '" value="' + _pwEsc(x.nombre) + '">' +
            '<input class="pw-inp" data-pc="' + i + '" type="email" placeholder="Correo (opcional)" aria-label="Correo de la persona ' + (i + 1) + '" value="' + _pwEsc(x.correo) + '"></div>';
        }).join('') + '<button type="button" class="pw-mas" id="pwMasPersona">＋ Otra persona</button>';
      } else {
        html += '<h3 class="pw-q">¿Quién se encarga?</h3><p class="pw-nota">Opcional. Sirve para saber a quién preguntar si se atrasa.</p>';
        html += '<input class="pw-inp" id="pwResp" placeholder="Nombre del responsable" aria-label="Responsable" value="' + _pwEsc(st.responsable) + '">';
      }
    }

    if (p === 'listo') {
      html += '<h3 class="pw-q">¿Así está bien?</h3><div class="pw-resumen">' + _pwEsc(skfPlanFrase(st)) + '</div>';
      html += '<p class="pw-nota">' + (st.modo === 'repite' ? 'Aparecerá en «Hoy» cuando toque, y se da por cumplida al llenar el formulario.'
        : st.modo === 'una' ? 'Después de guardar te damos el enlace para enviárselo por WhatsApp o correo.'
        : 'Cada turno verás si se registró o si faltó.') + '</p>';
    }

    $('pwPaso').innerHTML = html;
    refrescarPie();
    var foco = $('pwPaso').querySelector('.pw-q');
    if (foco) { foco.setAttribute('tabindex', '-1'); foco.focus({ preventScroll: true }); }
  }

  // ── Eventos ───────────────────────────────────────────────────────────────
  $('pwPaso').addEventListener('click', function (e) {
    var t;
    if ((t = e.target.closest('[data-pl]'))) { st.plantilla = plantillas.find(function (x) { return x.id === t.dataset.pl; }); pintar(); return; }
    if ((t = e.target.closest('[data-modo]'))) { if (t.getAttribute('aria-disabled') === 'true' && t.dataset.modo === 'turno' && hayTurnos) return; st.modo = t.dataset.modo; pintar(); return; }
    if ((t = e.target.closest('[data-frec]'))) { st.frecuencia = t.dataset.frec; pintar(); return; }
    if ((t = e.target.closest('[data-lugar]'))) {
      st.lugar = t.dataset.lugar === '' ? null : t.dataset.lugar;
      var u = lugares.find(function (x) { return x.id === st.lugar; });
      st.lugarNombre = u ? u.nombre : ''; pintar();
      if (st.lugar === 'nuevo') $('pwNuevoLugar').focus();
      return;
    }
    if (e.target.closest('#pwMasPersona')) { st.personas.push({ nombre: '', correo: '' }); pintar(); var ins = $('pwPaso').querySelectorAll('[data-pn]'); ins[ins.length - 1].focus(); }
  });
  $('pwPaso').addEventListener('input', function (e) {
    var t = e.target;
    if (t.id === 'pwBuscar') { st.buscar = t.value; var pos = t.selectionStart; pintar(); var nb = $('pwBuscar'); nb.focus(); nb.setSelectionRange(pos, pos); return; }
    if (t.id === 'pwInicio') st.inicio = t.value;
    if (t.id === 'pwLimite') st.limite = t.value;
    if (t.id === 'pwNuevoLugar') { st.nuevoLugar = t.value; st.lugarNombre = t.value.trim(); }
    if (t.id === 'pwResp') st.responsable = t.value.trim();
    if (t.dataset.pn !== undefined) st.personas[+t.dataset.pn].nombre = t.value;
    if (t.dataset.pc !== undefined) st.personas[+t.dataset.pc].correo = t.value.trim();
    refrescarPie();
  });
  $('pwAtras').addEventListener('click', function () { if (st.paso > 0) { st.paso--; pintar(); } });
  $('pwSig').addEventListener('click', async function () {
    if (!valido()) return;
    if (pasos()[st.paso] !== 'listo') { st.paso++; pintar(); hoja.scrollTop = 0; return; }
    this.disabled = true; this.textContent = 'Guardando…';
    try { await guardar(); }
    catch (err) {
      this.disabled = false; this.textContent = 'Guardar';
      var m = document.createElement('p'); m.className = 'pw-err'; m.textContent = err && err.message ? err.message : 'No se pudo guardar. Inténtalo de nuevo.';
      $('pwPaso').appendChild(m);
    }
  });

  // ── Guardar: exactamente lo que guardaban las tres pantallas de antes ──────
  async function guardar() {
    var ahora = new Date().toISOString(), unidadId = st.lugar && st.lugar !== 'nuevo' ? st.lugar : null;
    if (st.lugar === 'nuevo' && st.modo !== 'turno') {
      var u = { id: skfUUID(), nombre: st.nuevoLugar.trim(), tipo: 'sede', padreId: null, creadoEn: ahora };
      localStorage.setItem('skf_unidades', JSON.stringify(_pwLee('skf_unidades', []).concat(u)));
      skfSyncOrQueue('unidad', u);
      unidadId = u.id;
    }
    var t = st.plantilla, frase = skfPlanFrase(st);

    if (st.modo === 'repite') {
      var ins = { id: skfUUID(), plantillaId: t.id, plantillaNombre: t.nombre, nombre: t.nombre + (st.lugarNombre ? ' — ' + st.lugarNombre : ''),
        unidadId: unidadId, frecuencia: st.frecuencia, proximoEn: st.inicio, responsable: st.responsable || null, correo: null,
        activa: true, ultimoCompletado: null, creadoEn: ahora };
      localStorage.setItem('skf_inspecciones', JSON.stringify(_pwLee('skf_inspecciones', []).concat(ins)));
      skfSyncOrQueue('inspeccion', ins);
      return terminar('🔁 Rutina creada', frase);
    }

    if (st.modo === 'turno') {
      var cfg = { turnos: (cfgTurnos.turnos || []).map(function (x) { return { id: x.id, nombre: x.nombre, inicio: x.inicio, fin: x.fin }; }),
        esperado: (cfgTurnos.esperado || []).slice() };
      if (cfg.esperado.indexOf(t.id) === -1) cfg.esperado.push(t.id);
      try { await _enviarUna('org', { turnos_config: cfg }); }
      catch (e) { throw new Error(e && e.reintentable === false ? e.message : 'Sin conexión: los turnos solo se guardan con señal. Inténtalo de nuevo.'); }
      try { localStorage.setItem('skf_turnos_cfg', JSON.stringify(cfg)); } catch (e) {}
      return terminar('🕒 Agregado a los turnos', frase);
    }

    // Encargo: el formulario necesita enlace público para que la persona lo llene sin cuenta.
    var lista = _pwLee('skf_plantillas', []), pl = lista.find(function (x) { return x.id === t.id; }) || t;
    if (!pl.publica || !pl.shareToken) {
      pl.publica = true;
      pl.shareToken = pl.shareToken || (crypto.randomUUID ? crypto.randomUUID() : 'tok_' + Date.now() + '_' + Math.random().toString(36).slice(2, 10));
      pl.actualizadoEn = ahora;
      localStorage.setItem('skf_plantillas', JSON.stringify(lista.map(function (x) { return x.id === pl.id ? pl : x; })));
      await skfSyncOrQueue('plantilla', pl);
    }
    var nuevas = st.personas.filter(function (x) { return x.nombre.trim(); }).map(function (x) {
      var a = { id: skfUUID(), plantillaId: pl.id, plantillaNombre: pl.nombre, unidadId: unidadId, nombre: x.nombre.trim(),
        correo: x.correo || null, fechaLimite: st.limite || null, creadoEn: ahora };
      skfSyncOrQueue('asignacion', a);
      return a;
    });
    localStorage.setItem('skf_asignaciones', JSON.stringify(_pwLee('skf_asignaciones', []).concat(nuevas)));
    var enlace = location.origin + '/llenar.html?pub=' + encodeURIComponent(pl.shareToken);
    return terminar('👤 Encargo creado', frase, { enlace: enlace, formulario: pl.nombre, personas: nuevas, limite: st.limite });
  }

  function terminar(titulo, frase, compartir) {
    guardado = true;
    pie.remove();
    var h = '<div class="pw-ok"><div class="pw-ok-ico">✓</div><h3 class="pw-q" tabindex="-1">' + titulo + '</h3><div class="pw-resumen">' + _pwEsc(frase) + '</div></div>';
    if (compartir) {
      var msg = 'Hola, te encargo llenar «' + compartir.formulario + '»' + (compartir.limite ? ' antes del ' + _pwFecha(compartir.limite) : '') + '. Es desde el celular, sin cuenta: ' + compartir.enlace;
      h += '<div class="pw-sub">Envíale el enlace</div>' +
        '<a class="skf-opt" target="_blank" rel="noopener" href="https://wa.me/?text=' + encodeURIComponent(msg) + '"><span class="so-ico">💬</span><span class="so-txt"><b>Enviar por WhatsApp</b><small>Con el mensaje ya escrito</small></span><span class="so-arr">›</span></a>' +
        (navigator.share ? '<button type="button" class="skf-opt pw-btnopt" id="pwShare"><span class="so-ico">📤</span><span class="so-txt"><b>Compartir…</b><small>Correo, mensajes u otra app</small></span><span class="so-arr">›</span></button>' : '') +
        '<button type="button" class="skf-opt pw-btnopt" id="pwCopiar"><span class="so-ico">🔗</span><span class="so-txt"><b>Copiar enlace</b><small id="pwCopiadoS">' + _pwEsc(compartir.enlace) + '</small></span><span class="so-arr">›</span></button>';
    }
    h += '<button type="button" class="pw-sig pw-fin" id="pwFin">Listo</button>';
    $('pwPaso').innerHTML = h;
    $('pwPaso').querySelector('.pw-q').focus({ preventScroll: true });
    try { if (navigator.vibrate) navigator.vibrate([10, 40, 10]); } catch (e) {}
    $('pwFin').onclick = function () { skfSheetCerrar(); };
    if (compartir) {
      if ($('pwShare')) $('pwShare').onclick = function () { navigator.share({ title: compartir.formulario, text: msg }).catch(function () {}); };
      $('pwCopiar').onclick = function () {
        (navigator.clipboard ? navigator.clipboard.writeText(compartir.enlace) : Promise.reject()).then(function () { $('pwCopiadoS').textContent = '✓ Copiado'; })
          .catch(function () { prompt('Copia el enlace:', compartir.enlace); });
      };
    }
    if (opts.alGuardar) opts.alGuardar();
  }

  pintar();
}

if (typeof module !== 'undefined') module.exports = { skfPlanFrase: skfPlanFrase };
