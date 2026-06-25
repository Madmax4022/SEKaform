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

  const { nombre, correo, plantillaNombre, plantillaCodigo, linkFormulario } = body as {
    nombre?: string; correo?: string; plantillaNombre?: string;
    plantillaCodigo?: string; linkFormulario?: string;
  };

  if (!correo) {
    return new Response(JSON.stringify({ ok: true, skipped: 'sin correo del asignado' }), { headers: CORS });
  }

  const html = `<!DOCTYPE html><html><body style="margin:0;background:#f9fafb;padding:24px 0">
  <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:560px;margin:0 auto">
    <div style="background:#1a56db;padding:22px 28px;border-radius:10px 10px 0 0">
      <p style="margin:0;color:rgba(255,255,255,.7);font-size:12px;text-transform:uppercase;letter-spacing:.08em">SEKaform · Nueva asignación</p>
      <h1 style="margin:6px 0 0;color:#fff;font-size:20px;font-weight:700">📋 Tienes un formulario pendiente</h1>
    </div>
    <div style="background:#fff;padding:28px;border:1px solid #e5e7eb;border-top:none;border-radius:0 0 10px 10px">
      <p style="margin:0 0 8px;font-size:15px">Hola${nombre ? ` <strong>${nombre}</strong>` : ''},</p>
      <p style="margin:0 0 20px;font-size:15px;color:#374151">
        Se te ha asignado el formulario <strong>${plantillaNombre || 'sin nombre'}${plantillaCodigo ? ` (${plantillaCodigo})` : ''}</strong>.
        Por favor complétalo haciendo clic en el botón de abajo.
      </p>
      ${linkFormulario
        ? `<a href="${linkFormulario}" style="display:inline-block;background:#1a56db;color:#fff;text-decoration:none;padding:13px 28px;border-radius:8px;font-size:15px;font-weight:600">Llenar formulario →</a>`
        : ''}
      <p style="margin:24px 0 0;font-size:12px;color:#9ca3af;border-top:1px solid #f3f4f6;padding-top:16px">
        Si ya lo completaste, ignora este mensaje.<br>
        Enviado automáticamente por SEKaform.
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
      subject: `📋 Formulario asignado: ${plantillaNombre || 'sin nombre'}`,
      html,
    }),
  });

  const result = await res.json();
  return new Response(JSON.stringify({ ok: res.ok, data: result }), {
    status: res.ok ? 200 : 500,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
