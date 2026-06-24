import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
  if (!RESEND_API_KEY) {
    return new Response(JSON.stringify({ error: 'RESEND_API_KEY no configurada' }), { status: 500, headers: CORS });
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch {
    return new Response(JSON.stringify({ error: 'JSON inválido' }), { status: 400, headers: CORS });
  }

  const { correo, plantillaNombre, plantillaCodigo, llenadoPor, datos, numero } = body as {
    correo?: string; plantillaNombre?: string; plantillaCodigo?: string;
    llenadoPor?: string; datos?: Record<string, unknown>; numero?: number;
  };

  if (!correo) {
    return new Response(JSON.stringify({ ok: true, skipped: 'sin correo de notificación' }), { headers: CORS });
  }

  const filas = Object.entries(datos || {})
    .filter(([, v]) => v !== null && v !== '' && v !== undefined)
    .map(([k, v]) =>
      `<tr>
        <td style="padding:7px 12px;border-bottom:1px solid #f3f4f6;color:#6b7280;font-size:13px;white-space:nowrap">${k}</td>
        <td style="padding:7px 12px;border-bottom:1px solid #f3f4f6;font-size:13px">${v}</td>
      </tr>`
    ).join('');

  const html = `<!DOCTYPE html><html><body style="margin:0;background:#f9fafb;padding:24px 0">
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:580px;margin:0 auto">
    <div style="background:#1a56db;padding:22px 28px;border-radius:10px 10px 0 0">
      <p style="margin:0;color:rgba(255,255,255,.7);font-size:12px;text-transform:uppercase;letter-spacing:.08em">SEKaform · Nuevo envío</p>
      <h1 style="margin:6px 0 0;color:#fff;font-size:20px;font-weight:700">
        📋 ${plantillaNombre || 'Formulario'}${numero ? ` <span style="font-weight:400;font-size:15px">#${numero}</span>` : ''}
      </h1>
    </div>
    <div style="background:#fff;padding:24px 28px;border:1px solid #e5e7eb;border-top:none;border-radius:0 0 10px 10px">
      ${plantillaCodigo ? `<p style="margin:0 0 4px;font-size:13px;color:#6b7280">Código: <strong>${plantillaCodigo}</strong></p>` : ''}
      ${llenadoPor ? `<p style="margin:0 0 16px;font-size:13px;color:#6b7280">Llenado por: <strong>${llenadoPor}</strong></p>` : '<div style="margin-bottom:16px"></div>'}
      <table style="width:100%;border-collapse:collapse">
        <thead>
          <tr style="background:#f9fafb">
            <th style="padding:8px 12px;text-align:left;font-size:11px;color:#9ca3af;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e5e7eb">Campo</th>
            <th style="padding:8px 12px;text-align:left;font-size:11px;color:#9ca3af;text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid #e5e7eb">Respuesta</th>
          </tr>
        </thead>
        <tbody>${filas || '<tr><td colspan="2" style="padding:12px;color:#9ca3af;font-size:13px">Sin datos</td></tr>'}</tbody>
      </table>
      <p style="margin:20px 0 0;font-size:12px;color:#d1d5db;border-top:1px solid #f3f4f6;padding-top:16px">
        Enviado automáticamente por SEKaform
      </p>
    </div>
  </div>
  </body></html>`;

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'SEKaform <onboarding@resend.dev>',
      to: [correo],
      subject: `📋 ${plantillaNombre || 'Formulario'}${numero ? ` #${numero}` : ''} — nuevo envío`,
      html,
    }),
  });

  const result = await res.json();
  return new Response(JSON.stringify({ ok: res.ok, data: result }), {
    status: res.ok ? 200 : 500,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
