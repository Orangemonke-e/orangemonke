// Monke Icon Maker: "notify-update" Supabase Edge Function.
// Sends an update notification to every device that turned notifications on.
// Only admins can use it: the device list comes from admin_push_targets(), which checks the caller is an admin.
//
// Secrets it needs (Supabase dashboard > Edge Functions > Secrets):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT   (see GALLERY-SETUP.md)
// SUPABASE_URL is provided by Supabase automatically.
//
// Web Push is done with the standard Web Crypto API (RFC 8291 message encryption + RFC 8292 VAPID), no libraries.

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const PUSH_HOST = /^https:\/\/(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)\//;

const enc = new TextEncoder();
const b64u = (buf: ArrayBuffer | Uint8Array) => {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = ''; for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const unb64u = (s: string) => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4);
  return Uint8Array.from(atob(t), (c) => c.charCodeAt(0));
};
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; } return out;
};
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, length: number) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, length * 8));
}

// VAPID: a short signed note that proves the message comes from this site.
export async function vapidHeader(endpoint: string, publicKey: string, privateKey: string, subject: string) {
  const pub = unb64u(publicKey);
  const jwk = { kty: 'EC', crv: 'P-256', x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), d: privateKey, ext: true };
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const head = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const body = b64u(enc.encode(JSON.stringify({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: subject })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(head + '.' + body));
  return `vapid t=${head}.${body}.${b64u(sig)}, k=${publicKey}`;
}

// Encrypts the message so only the receiving browser can read it (aes128gcm).
export async function encryptPayload(p256dh: string, authSecret: string, payload: Uint8Array) {
  const uaPublic = unb64u(p256dh), auth = unb64u(authSecret);
  const asKeys = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', asKeys.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asKeys.privateKey, 256));
  const ikm = await hkdf(auth, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(payload, new Uint8Array([2]))));
  const header = new Uint8Array(21 + asPublic.length);
  header.set(salt, 0); new DataView(header.buffer).setUint32(16, 4096); header[20] = asPublic.length; header.set(asPublic, 21);
  return concat(header, cipher);
}

export async function sendPush(sub: { endpoint: string; p256dh: string; auth_secret: string }, message: object, vapid: { publicKey: string; privateKey: string; subject: string }) {
  if (!PUSH_HOST.test(sub.endpoint)) return 400;
  const body = await encryptPayload(sub.p256dh, sub.auth_secret, enc.encode(JSON.stringify(message)));
  const res = await fetch(sub.endpoint, {
    method: 'POST',
    headers: {
      'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '86400', Urgency: 'normal',
      Authorization: await vapidHeader(sub.endpoint, vapid.publicKey, vapid.privateKey, vapid.subject),
    },
    body,
  });
  await res.arrayBuffer().catch(() => {});
  return res.status;
}

const json = (data: object, status = 200) => new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

export async function handle(req: Request, env: (k: string) => string | undefined): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);
  const vapid = { publicKey: env('VAPID_PUBLIC_KEY') || '', privateKey: env('VAPID_PRIVATE_KEY') || '', subject: env('VAPID_SUBJECT') || '' };
  if (!vapid.publicKey || !vapid.privateKey || !vapid.subject) return json({ error: 'The VAPID secrets are not set up yet.' }, 500);
  let input: { title?: string; body?: string; url?: string };
  try { input = await req.json(); } catch { return json({ error: 'Bad request' }, 400); }
  const title = String(input.title || '').trim().slice(0, 60), text = String(input.body || '').trim().slice(0, 160);
  if (!title) return json({ error: 'Add a title.' }, 400);
  const url = String(input.url || './').slice(0, 300);

  // Ask the database for the device list as the person who called us (it refuses unless they're an admin).
  const base = env('SUPABASE_URL'), headers = {
    Authorization: req.headers.get('Authorization') || '', apikey: req.headers.get('apikey') || '', 'Content-Type': 'application/json',
  };
  const t = await fetch(`${base}/rest/v1/rpc/admin_push_targets`, { method: 'POST', headers, body: '{}' });
  if (!t.ok) return json({ error: 'Only admins can send notifications.' }, 403);
  const subs: { endpoint: string; p256dh: string; auth_secret: string }[] = await t.json();

  const message = { title, body: text, url };
  let sent = 0, failed = 0; const gone: string[] = [];
  for (let i = 0; i < subs.length; i += 10) {
    await Promise.all(subs.slice(i, i + 10).map(async (s) => {
      try {
        const status = await sendPush(s, message, vapid);
        if (status >= 200 && status < 300) sent++; else { failed++; if (status === 404 || status === 410 || status === 400) gone.push(s.endpoint); }
      } catch { failed++; }
    }));
  }
  if (gone.length) await fetch(`${base}/rest/v1/rpc/admin_remove_push`, { method: 'POST', headers, body: JSON.stringify({ p_endpoints: gone }) });
  return json({ sent, failed, removed: gone.length, devices: subs.length });
}

// @ts-ignore: Deno is provided by Supabase Edge Functions
if (typeof Deno !== 'undefined') Deno.serve((req: Request) => handle(req, (k) => Deno.env.get(k)));
