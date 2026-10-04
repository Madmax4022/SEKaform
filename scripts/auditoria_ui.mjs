// ═══════════════════════════════════════════════════════════════════════════
//  Auditoría de accesibilidad y usabilidad móvil de SEKaform.
//
//  Mide, en las 13 pantallas, con datos simulados (sin servidor real):
//    · contraste de texto (WCAG AA: 4.5:1, o 3:1 si el texto es grande)
//    · controles táctiles menores de 44 px (WCAG 2.5.5)
//    · campos sin etiqueta accesible e imágenes sin alt
//    · desborde horizontal a 320, 360, 411 y 768 px
//    · errores de JavaScript
//
//  Uso (desde la raíz, con la app servida en BASE):
//    python3 -m http.server 8199 &
//    npm i -D playwright   # una vez
//    CHROME=/ruta/a/chrome node scripts/auditoria_ui.mjs      # CHROME es opcional
//  Escribe auditoria-ui.json en SALIDA (por defecto, el directorio actual).
//
//  Límites: no evalúa los gráficos del Panel ni el contraste de emojis, y los
//  términos del glosario dentro de un párrafo se tratan como enlaces en línea
//  (exentos del mínimo táctil). Sirve para comparar antes/después de un cambio.
// ═══════════════════════════════════════════════════════════════════════════
import fs from 'node:fs';
import pw from 'playwright';
const SP=process.env.SALIDA||'.';
const BASE=process.env.BASE||'http://127.0.0.1:8199';
const b=await pw.chromium.launch(process.env.CHROME?{executablePath:process.env.CHROME}:{});
const DAY=86400000, iso=d=>new Date(Date.now()-d*DAY).toISOString();
const PL=['Lista de Verificación SST','Entrega de Elementos de Protección Personal (EPP)','Acta de Reunión — COPASST','Control de Temperatura HACCP','Entrega de Turno'].map((n,i)=>({id:'p'+i,nombre:n,codigo:'FORM-000'+(i+1),campos:[{id:'c',tipo:'texto',etiqueta:'Campo'}],publica:true,creado_en:iso(30),actualizado_en:iso(5)}));
const ENV=PL.flatMap((p,i)=>[3,20,60].map((d,j)=>({id:'e'+i+j,numero:i*3+j,plantilla_id:p.id,plantilla_nombre:p.nombre,estado:'enviado',datos:{},llenado_por:'Juan Pérez',enviado_en:iso(d),creado_en:iso(d),unidad_id:'u1'})));
const HZ=[{id:'h1',envio_id:'e00',plantilla_id:'p0',plantilla_nombre:PL[0].nombre,campo_etiqueta:'Extintor',severidad:'critico',descripcion:'Extintor vencido',estado:'abierto',creado_en:iso(5),unidad_id:'u1'}];
const boot={autenticado:true,usuario:{email:'t@x.co',orgId:'o1',rol:'dueno',puedeEscribir:true},organizacion:{nombre:'Empresa SAS',pais:'CO',turnos_config:{turnos:[{id:'m',nombre:'Mañana',inicio:'06:00',fin:'14:00'}],esperado:['p4']}},plantillas:PL,unidades:[{id:'u1',nombre:'Sede Principal',tipo:'sede'}],asignaciones:[],programadas:[]};
const PAGES=['index','plantillas','llenar','cumplimiento','turnos','hallazgos','dashboard','digitalizador','asignaciones','programadas','unidades','organizacion','bienvenida'];
async function ctx(w,scheme='dark'){
  const c=await b.newContext({viewport:{width:w,height:900},colorScheme:scheme,deviceScaleFactor:1});
  await c.route('**/api/**',r=>{const u=r.request().url(); const body=u.includes('/api/yo')?{autenticado:true,usuario:boot.usuario}:u.includes('/api/bootstrap')?boot:u.includes('/api/envios')?{envios:ENV}:u.includes('/api/hallazgos')?{hallazgos:HZ,acciones:[]}:{ok:true};
    r.fulfill({contentType:'application/json',body:JSON.stringify(body)});});
  await c.addInitScript((d)=>{localStorage.setItem('skf_plantillas',JSON.stringify(d.pl));localStorage.setItem('skf_perfil:t@x.co',JSON.stringify({completo:true}));},{pl:PL});
  return c;
}
const MEDIR=()=>{
  const parse=s=>{const m=s.match(/rgba?\(([^)]+)\)/);if(!m)return null;const p=m[1].split(',').map(x=>parseFloat(x));return{r:p[0],g:p[1],b:p[2],a:p.length>3?p[3]:1};};
  const over=(f,bg)=>({r:f.r*f.a+bg.r*(1-f.a),g:f.g*f.a+bg.g*(1-f.a),b:f.b*f.a+bg.b*(1-f.a),a:1});
  const lum=c=>{const f=v=>{v/=255;return v<=.03928?v/12.92:Math.pow((v+.055)/1.055,2.4)};return .2126*f(c.r)+.7152*f(c.g)+.0722*f(c.b);};
  const bgDe=el=>{let capas=[];for(let e=el;e;e=e.parentElement){const cs=getComputedStyle(e);if(cs.backgroundImage&&cs.backgroundImage!=='none'&&!cs.backgroundImage.includes('gradient(rgba'))return null;const c=parse(cs.backgroundColor);if(c&&c.a>0){capas.push(c);if(c.a===1)break;}}
    let base=capas.length&&capas[capas.length-1].a===1?capas.pop():{r:15,g:23,b:42,a:1};while(capas.length)base=over(capas.pop(),base);return base;};
  const out=[]; const vistos=new Set();
  document.querySelectorAll('body *').forEach(el=>{
    if(!el.childNodes||![...el.childNodes].some(n=>n.nodeType===3&&n.nodeValue.trim().length>1))return;
    const r=el.getBoundingClientRect(); if(r.width<2||r.height<2)return; const cs=getComputedStyle(el);
    if(cs.visibility==='hidden'||cs.display==='none'||parseFloat(cs.opacity)===0)return;
    if(el.closest('[hidden],script,style,.skf-help-pop'))return;
    const fg=parse(cs.color); const bg=bgDe(el); if(!fg||!bg)return;
    const f=over(fg,bg); const L1=lum(f),L2=lum(bg); const ratio=(Math.max(L1,L2)+.05)/(Math.min(L1,L2)+.05);
    const px=parseFloat(cs.fontSize), bold=parseInt(cs.fontWeight)>=700, grande=px>=24||(px>=18.66&&bold);
    const min=grande?3:4.5; if(ratio>=min)return;
    const clave=cs.color+'|'+JSON.stringify(bg)+'|'+px; if(vistos.has(clave))return; vistos.add(clave);
    out.push({texto:el.textContent.trim().replace(/\s+/g,' ').slice(0,38),ratio:Math.round(ratio*100)/100,min,px:Math.round(px*10)/10,color:cs.color});});
  return out;};
const TAP=()=>{
  const out=[];document.querySelectorAll('a[href],button,input:not([type=hidden]),select,textarea,[role=button],[onclick]').forEach(el=>{
    let r=el.getBoundingClientRect(); if(r.width<2||r.height<2)return; const cs=getComputedStyle(el); if(cs.visibility==='hidden'||cs.display==='none')return; if(el.closest('[hidden]'))return;
    if(el.classList.contains('skf-term'))return;
    if(el.type==='checkbox'||el.type==='radio'){const lb=(el.labels&&el.labels[0])||el.closest('label'); if(lb){const lr=lb.getBoundingClientRect(); if(lr.height>=44&&lr.width>=44)return; r=lr;}}
    if(el.tagName==='A'&&el.textContent.trim().length>0&&cs.display==='inline'&&el.closest('p,li,.s,.hint,.cfg-hint,span,footer,.pg-sub'))return; // enlace dentro de un párrafo
    if(r.height<44||r.width<44) out.push({el:(el.tagName+'.'+(el.className||'').toString().split(' ')[0]).slice(0,40),txt:(el.textContent||el.getAttribute('aria-label')||el.placeholder||'').trim().slice(0,22),w:Math.round(r.width),h:Math.round(r.height)});});
  return out;};
const LAB=()=>{
  const out=[];document.querySelectorAll('input:not([type=hidden]):not([type=checkbox]):not([type=radio]),select,textarea').forEach(el=>{
    const r=el.getBoundingClientRect(); if(r.width<2||el.closest('[hidden]'))return;
    const tiene=el.getAttribute('aria-label')||el.getAttribute('aria-labelledby')||(el.id&&document.querySelector('label[for="'+el.id+'"]'))||el.closest('label');
    if(!tiene)out.push((el.tagName+'#'+(el.id||'(sin id)')+' '+(el.placeholder||'')).slice(0,50));});
  const imgs=[...document.images].filter(i=>!i.hasAttribute('alt')).length; return {sinEtiqueta:out,imgsSinAlt:imgs};};
const res={contraste:{},toque:{},etiquetas:{},desborde:{},errores:{}};
for(const pg of PAGES){
  const c=await ctx(411); const p=await c.newPage(); const errs=[]; p.on('pageerror',e=>errs.push(e.message));
  await p.goto(BASE+'/'+pg+'.html',{waitUntil:'networkidle'}).catch(()=>{}); await p.waitForTimeout(1100);
  res.contraste[pg]=await p.evaluate(MEDIR); res.toque[pg]=await p.evaluate(TAP); res.etiquetas[pg]=await p.evaluate(LAB); res.errores[pg]=errs;
  await c.close();
  res.desborde[pg]=[];
  for(const w of [320,360,411,768]){ const c2=await ctx(w); const q=await c2.newPage(); await q.goto(BASE+'/'+pg+'.html',{waitUntil:'networkidle'}).catch(()=>{}); await q.waitForTimeout(500);
    const d=await q.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth); if(d>1)res.desborde[pg].push(w+'px(+'+d+')'); await c2.close(); }
}
fs.writeFileSync(SP+'/auditoria-ui.json',JSON.stringify(res,null,1));
await b.close();
console.log('auditoría terminada');
