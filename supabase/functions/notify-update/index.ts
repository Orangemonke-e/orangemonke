// Monke Icon Maker: "notify-update" Supabase Edge Function.
// Two jobs:
//  1. Update notifications: an admin sends a message to every device that turned notifications on
//     (the device list comes from admin_push_targets(), which checks the caller is an admin).
//  2. Comment notifications ({ type: 'comment', comment_id }): right after someone posts a comment, their browser asks
//     this function to tell the icon's owner, the other commenters, and (for a reply) the person replied to.
//     claim_comment_notification() checks the caller wrote that comment and that it hasn't been announced yet; the
//     device list is then read with the service key.
//  3. Follower notifications ({ type: 'follow', followee_id }): right after someone follows a person, their browser asks
//     this function to tell that person. claim_follow_notification() checks the follow is real and new (at most one
//     notice a day per pair); the device list is then read with the service key.
//  4. Like notifications ({ type: 'like', post_id }): right after someone likes an icon, their browser asks this function
//     to tell the icon's owner. claim_like_notification() checks the like is real and new (at most one notice a day).
//
// Secrets it needs (Supabase dashboard > Edge Functions > Secrets):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT   (see GALLERY-SETUP.md)
// SUPABASE_URL and the service key (SUPABASE_SERVICE_ROLE_KEY or SUPABASE_SECRET_KEYS) are provided by Supabase automatically.
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
  let input: { title?: string; body?: string; url?: string; type?: string; comment_id?: string; followee_id?: string; post_id?: string };
  try { input = await req.json(); } catch { return json({ error: 'Bad request' }, 400); }
  if (input.type === 'comment') return handleComment(req, env, vapid, String(input.comment_id || ''), String(input.url || ''));
  if (input.type === 'like') return handleLike(req, env, vapid, String(input.post_id || ''), String(input.url || ''));
  if (input.type === 'follow') return handleFollow(req, env, vapid, String(input.followee_id || ''), String(input.url || ''));
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

// The project's service key, used only to read the device list for comment notifications.
function serviceKey(env: (k: string) => string | undefined) {
  const legacy = env('SUPABASE_SERVICE_ROLE_KEY');
  if (legacy) return legacy;
  try { const keys = JSON.parse(env('SUPABASE_SECRET_KEYS') || '{}'); return keys.default || Object.values(keys)[0] || ''; } catch { return ''; }
}
const serviceHeaders = (key: string) => ({ apikey: key, 'Content-Type': 'application/json', ...(key.startsWith('eyJ') ? { Authorization: `Bearer ${key}` } : {}) });

async function handleComment(req: Request, env: (k: string) => string | undefined, vapid: { publicKey: string; privateKey: string; subject: string }, commentId: string, pageUrl: string) {
  if (!/^[0-9a-f-]{36}$/i.test(commentId)) return json({ error: 'Bad comment' }, 400);
  const base = env('SUPABASE_URL');
  // 1. As the person who called us: is this their brand-new comment, not announced yet? (Marks it announced.)
  const userHeaders = { Authorization: req.headers.get('Authorization') || '', apikey: req.headers.get('apikey') || '', 'Content-Type': 'application/json' };
  const claim = await fetch(`${base}/rest/v1/rpc/claim_comment_notification`, { method: 'POST', headers: userHeaders, body: JSON.stringify({ p_comment: commentId }) });
  if (!claim.ok || (await claim.json()) !== true) return json({ sent: 0, skipped: true });
  // 2. With the service key: the devices of the icon's owner and the other commenters.
  const key = serviceKey(env);
  if (!key) return json({ error: 'No service key available to the function.' }, 500);
  const t = await fetch(`${base}/rest/v1/rpc/comment_push_targets`, { method: 'POST', headers: serviceHeaders(key), body: JSON.stringify({ p_comment: commentId }) });
  if (!t.ok) return json({ error: 'Could not read the device list.' }, 500);
  const targets: { endpoint: string; p256dh: string; auth_secret: string; kind: string; author_name: string; post_title: string; body: string; post_id: string }[] = await t.json();
  let site = 'https://kaigroves15-hash.github.io/orangemonke/';
  try { const u = new URL(pageUrl); if (u.protocol === 'https:') site = u.origin + u.pathname.replace(/[^/]*$/, ''); } catch { /* keep the default */ }
  let sent = 0; const gone: string[] = [];
  await Promise.all(targets.map(async (s) => {
    // Like a messaging app: the icon in the title, and "Name: comment" in the message, so it's always clear who said it.
    const icon = s.post_title ? `"${s.post_title}"` : '';
    const title = s.kind === 'reply' ? `↩️ ${s.author_name} replied to you${icon ? ' on ' + icon : ''}`
      : s.kind === 'owner' ? `💬 New comment on your icon${icon ? ' ' + icon : ''}` : `💬 New comment on ${icon || 'an icon you commented on'}`;
    const text = `${s.author_name}: ${s.body}`;
    const message = { title: title.slice(0, 80), body: text.slice(0, 160), url: `${site}?comments=${s.post_id}`, tag: `monke-comments-${s.post_id}` };
    try { const status = await sendPush(s, message, vapid); if (status >= 200 && status < 300) sent++; else if ([400, 404, 410].includes(status)) gone.push(s.endpoint); } catch { /* skip */ }
  }));
  if (gone.length) await fetch(`${base}/rest/v1/rpc/service_remove_push`, { method: 'POST', headers: serviceHeaders(key), body: JSON.stringify({ p_endpoints: gone }) });
  return json({ sent, devices: targets.length, removed: gone.length });
}

const siteFrom = (pageUrl: string) => {
  try { const u = new URL(pageUrl); if (u.protocol === 'https:') return u.origin + u.pathname.replace(/[^/]*$/, ''); } catch { /* use the default */ }
  return 'https://kaigroves15-hash.github.io/orangemonke/';
};

async function handleFollow(req: Request, env: (k: string) => string | undefined, vapid: { publicKey: string; privateKey: string; subject: string }, followeeId: string, pageUrl: string) {
  if (!/^[0-9a-f-]{36}$/i.test(followeeId)) return json({ error: 'Bad account' }, 400);
  const base = env('SUPABASE_URL');
  // 1. As the person who called us: did they really just follow this account, and not been announced in the last day?
  const userHeaders = { Authorization: req.headers.get('Authorization') || '', apikey: req.headers.get('apikey') || '', 'Content-Type': 'application/json' };
  const claim = await fetch(`${base}/rest/v1/rpc/claim_follow_notification`, { method: 'POST', headers: userHeaders, body: JSON.stringify({ p_followee: followeeId }) });
  const followerId = claim.ok ? await claim.json() : null;
  if (!followerId) return json({ sent: 0, skipped: true });
  // 2. With the service key: the devices of the person who was followed.
  const key = serviceKey(env);
  if (!key) return json({ error: 'No service key available to the function.' }, 500);
  const t = await fetch(`${base}/rest/v1/rpc/follow_push_targets`, { method: 'POST', headers: serviceHeaders(key), body: JSON.stringify({ p_follower: followerId, p_followee: followeeId }) });
  if (!t.ok) return json({ error: 'Could not read the device list.' }, 500);
  const targets: { endpoint: string; p256dh: string; auth_secret: string; follower_name: string; follower_username: string }[] = await t.json();
  const site = siteFrom(pageUrl);
  let sent = 0; const gone: string[] = [];
  await Promise.all(targets.map(async (s) => {
    const message = { title: '👥 New follower', body: `${s.follower_name} (@${s.follower_username}) started following you`.slice(0, 160), url: `${site}?profile=${followerId}`, tag: `monke-follow-${followerId}` };
    try { const status = await sendPush(s, message, vapid); if (status >= 200 && status < 300) sent++; else if ([400, 404, 410].includes(status)) gone.push(s.endpoint); } catch { /* skip */ }
  }));
  if (gone.length) await fetch(`${base}/rest/v1/rpc/service_remove_push`, { method: 'POST', headers: serviceHeaders(key), body: JSON.stringify({ p_endpoints: gone }) });
  return json({ sent, devices: targets.length, removed: gone.length });
}

async function handleLike(req: Request, env: (k: string) => string | undefined, vapid: { publicKey: string; privateKey: string; subject: string }, postId: string, pageUrl: string) {
  if (!/^[0-9a-f-]{36}$/i.test(postId)) return json({ error: 'Bad icon' }, 400);
  const base = env('SUPABASE_URL');
  // 1. As the person who called us: did they really just like this icon (not their own), and not announced in the last day?
  const userHeaders = { Authorization: req.headers.get('Authorization') || '', apikey: req.headers.get('apikey') || '', 'Content-Type': 'application/json' };
  const claim = await fetch(`${base}/rest/v1/rpc/claim_like_notification`, { method: 'POST', headers: userHeaders, body: JSON.stringify({ p_post: postId }) });
  const likerId = claim.ok ? await claim.json() : null;
  if (!likerId) return json({ sent: 0, skipped: true });
  // 2. With the service key: the icon owner's devices.
  const key = serviceKey(env);
  if (!key) return json({ error: 'No service key available to the function.' }, 500);
  const t = await fetch(`${base}/rest/v1/rpc/like_push_targets`, { method: 'POST', headers: serviceHeaders(key), body: JSON.stringify({ p_liker: likerId, p_post: postId }) });
  if (!t.ok) return json({ error: 'Could not read the device list.' }, 500);
  const targets: { endpoint: string; p256dh: string; auth_secret: string; liker_name: string; post_title: string }[] = await t.json();
  const site = siteFrom(pageUrl);
  let sent = 0; const gone: string[] = [];
  await Promise.all(targets.map(async (s) => {
    const message = { title: '♥ New like', body: `${s.liker_name} liked your icon${s.post_title ? ` "${s.post_title}"` : ''}`.slice(0, 160), url: `${site}?comments=${postId}`, tag: `monke-likes-${postId}` };
    try { const status = await sendPush(s, message, vapid); if (status >= 200 && status < 300) sent++; else if ([400, 404, 410].includes(status)) gone.push(s.endpoint); } catch { /* skip */ }
  }));
  if (gone.length) await fetch(`${base}/rest/v1/rpc/service_remove_push`, { method: 'POST', headers: serviceHeaders(key), body: JSON.stringify({ p_endpoints: gone }) });
  return json({ sent, devices: targets.length, removed: gone.length });
}

// @ts-ignore: Deno is provided by Supabase Edge Functions
if (typeof Deno !== 'undefined') Deno.serve((req: Request) => handle(req, (k) => Deno.env.get(k)));
