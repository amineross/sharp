// Sharp anonymous usage. Sharp posts when its payload changes, or monthly:
// {"id": random UUID, and only the fields the user left on}.
// IP addresses are never stored; country comes from Cloudflare when asked for.
const FIELDS = ['version', 'macos', 'model', 'role', 'link', 'display', 'mode', 'resolution'];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return new Response(null, { status: 405 });
    let body;
    try { body = await request.json(); } catch { return new Response(null, { status: 400 }); }
    if (!body || typeof body.id !== 'string' || !UUID.test(body.id)) return new Response(null, { status: 400 });

    const value = (key) => typeof body[key] === 'string' && body[key].length ? body[key].slice(0, 64) : null;
    const values = FIELDS.map(value);
    const country = body.country === true ? (request.cf?.country ?? null) : null;
    const now = new Date().toISOString();

    // Fields the user turned off are cleared, not kept from an earlier ping.
    await env.DB.prepare(
      `INSERT INTO sharp_installs (id, first_seen, last_seen, ${FIELDS.join(', ')}, country)
       VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
       ON CONFLICT(id) DO UPDATE SET last_seen = ?2, ${FIELDS.map((key, i) => `${key} = ?${i + 3}`).join(', ')}, country = ?11`
    ).bind(body.id.toLowerCase(), now, ...values, country).run();
    return new Response(null, { status: 204 });
  },
};
