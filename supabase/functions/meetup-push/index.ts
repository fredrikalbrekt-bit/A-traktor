// Slowlane: skickar notiser när en träff skapas.
// Databasen anropar funktionen (meetup_push_hook i live-riders.sql) med träffens id och en hemlighet.
// Funktionen hämtar mottagarna med push_job, som kontrollerar hemligheten, och skickar en krypterad
// webbpush till varje telefon: innehållet enligt RFC 8291 och avsändaren enligt RFC 8292 (VAPID).
// Bara Web Crypto, inga bibliotek.
// Läggs in under Edge Functions med namnet meetup-push, med JWT-kontrollen avstängd (hemligheten ersätter den).
// Hemlig nyckel: VAPID_PRIVATE_KEY under Edge Functions → Secrets.

const SUPA_URL = 'https://whpfdexdxwumaiiriqkt.supabase.co';
const SUPA_KEY = 'sb_publishable_minOWomD8yovDIT35L9BQA_V2MN-aJD';
const VAPID_PUBLIC = 'BLgTk7XQhDGM2MTTXfhxbvDjz718ZHj14wWwiyLeROOWEUba2IQseDGsrCq9qPqcvAD4WbKSsK1KqYaf9X42vAo';
const VAPID_SUBJECT = 'mailto:slowlane@googlegroups.com';
// samma notistjänster som push_host_ok i databasen
const PUSH_HOSTS = /^https:\/\/(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)\//;

// ---------- Byte och base64url ----------
const bytes = (n: number) => new Uint8Array(n);
type Bytes = ReturnType<typeof bytes>;
function concat(...parts: Bytes[]): Bytes {
  const out = bytes(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
}
function utf8(s: string): Bytes { const e = new TextEncoder().encode(s); const b = bytes(e.length); b.set(e); return b; }
export function fromB64u(s: string): Bytes {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '') + '==='.slice((s.length + 3) % 4));
  const b = bytes(bin.length);
  for (let i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i);
  return b;
}
export function toB64u(b: Bytes): string {
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function hmac(key: Bytes, data: Bytes): Promise<Bytes> {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, data));
}
// En P-256-nyckel som JWK: x och y kommer ur den publika nyckeln (0x04 || x || y)
function p256Jwk(publicRaw: Bytes, d?: string): JsonWebKey {
  const jwk: JsonWebKey = { kty: 'EC', crv: 'P-256', x: toB64u(publicRaw.slice(1, 33)), y: toB64u(publicRaw.slice(33, 65)), ext: true };
  if (d) jwk.d = d;
  return jwk;
}

// ---------- Kryptering (RFC 8291, aes128gcm) ----------
// test: fast salt och fast avsändarnyckel, för att kunna jämföra med exemplet i RFC 8291
export async function encrypt(plain: Bytes, uaPublicB64: string, authB64: string,
                              test?: { salt: Bytes, asPublic: Bytes, asPrivate: string }): Promise<Bytes> {
  const uaPublic = fromB64u(uaPublicB64), authSecret = fromB64u(authB64);
  let asPublic: Bytes, asKey: CryptoKey;
  if (test) {
    asPublic = test.asPublic;
    asKey = await crypto.subtle.importKey('jwk', p256Jwk(asPublic, test.asPrivate), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  } else {
    const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
    asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
    asKey = pair.privateKey;
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asKey, 256));

  const prkKey = await hmac(authSecret, ecdh);
  const ikm = await hmac(prkKey, concat(utf8('WebPush: info'), bytes(1), uaPublic, asPublic, Uint8Array.of(1)));
  const salt = test ? test.salt : crypto.getRandomValues(bytes(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(utf8('Content-Encoding: aes128gcm'), bytes(1), Uint8Array.of(1)))).slice(0, 16);
  const nonce = (await hmac(prk, concat(utf8('Content-Encoding: nonce'), bytes(1), Uint8Array.of(1)))).slice(0, 12);

  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(plain, Uint8Array.of(2))));
  // salt || postens storlek (4096) || nyckelns längd || avsändarens publika nyckel
  const header = concat(salt, Uint8Array.of(0, 0, 16, 0), Uint8Array.of(asPublic.length), asPublic);
  return concat(header, sealed);
}

// ---------- Avsändaren (RFC 8292, VAPID) ----------
export async function vapidKey(privateD: string): Promise<CryptoKey> {
  return crypto.subtle.importKey('jwk', p256Jwk(fromB64u(VAPID_PUBLIC), privateD), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
}
export async function vapidAuth(endpoint: string, key: CryptoKey, now = Date.now()): Promise<string> {
  const part = (o: object) => toB64u(utf8(JSON.stringify(o)));
  const unsigned = part({ typ: 'JWT', alg: 'ES256' }) + '.' + part({ aud: new URL(endpoint).origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: VAPID_SUBJECT });
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, utf8(unsigned)));
  return `vapid t=${unsigned}.${toB64u(sig)}, k=${VAPID_PUBLIC}`;
}

// ---------- Texten ----------
type Row = { endpoint: string, p256dh: string, auth: string, lang: string, title: string, group_name: string, creator_nick: string | null, starts_at: string };
export function texts(r: Row, now = Date.now()): { title: string, body: string } {
  const sv = r.lang !== 'en', loc = sv ? 'sv-SE' : 'en-GB', tz = 'Europe/Stockholm', d = new Date(r.starts_at);
  const day = (x: Date) => x.toLocaleDateString('sv-SE', { timeZone: tz });
  const hm = d.toLocaleTimeString(loc, { timeZone: tz, hour: '2-digit', minute: '2-digit' });
  const when = day(d) === day(new Date(now)) ? (sv ? 'idag' : 'today')
    : day(d) === day(new Date(now + 864e5)) ? (sv ? 'imorgon' : 'tomorrow')
    : d.toLocaleDateString(loc, { timeZone: tz, weekday: 'short', day: 'numeric', month: 'short' });
  const by = r.creator_nick ? (sv ? ' · av ' : ' · by ') + r.creator_nick : '';
  return { title: (sv ? 'Ny träff i ' : 'New meetup in ') + r.group_name, body: `🏁 ${r.title} · ${when} ${hm}${by}` };
}

// ---------- Skicka ----------
async function rpc(fn: string, args: object): Promise<Response> {
  return fetch(`${SUPA_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { apikey: SUPA_KEY, Authorization: `Bearer ${SUPA_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
}
async function sendPush(r: Row, payload: string, ttl: number, key: CryptoKey): Promise<number> {
  const body = await encrypt(utf8(payload), r.p256dh, r.auth);
  const res = await fetch(r.endpoint, {
    method: 'POST', body,
    headers: { 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: String(ttl), Urgency: 'high',
               Authorization: await vapidAuth(r.endpoint, key) } });
  await res.body?.cancel();
  return res.status;
}

// Felet syns i svaret (net._http_response i databasen) och i funktionens loggar
function fail(error: string): Response {
  console.error('meetup-push:', error);
  return Response.json({ error }, { status: 500 });
}

async function handle(req: Request): Promise<Response> {
  const secret = req.headers.get('x-slowlane-hook');
  if (req.method !== 'POST' || !secret) return new Response('not allowed', { status: 403 });
  let body: { meetup?: unknown } = {};
  try { body = await req.json(); } catch { /* fel format */ }
  const meetup = typeof body.meetup === 'string' ? body.meetup : '';
  if (!meetup) return new Response('bad request', { status: 400 });

  // Nyckeln först: push_job markerar träffen, så med en trasig nyckel skulle notiserna gå förlorade.
  // Mellanslag, radbrytningar och citattecken från inklistringen tas bort.
  const privateD = (Deno.env.get('VAPID_PRIVATE_KEY') || '').replace(/[\s"']/g, '');
  if (!/^[\w-]{43}$/.test(privateD)) return fail('VAPID_PRIVATE_KEY saknas eller är inte 43 tecken (är ' + privateD.length + ')');
  let key: CryptoKey;
  try { key = await vapidKey(privateD); } catch (e) { return fail('VAPID_PRIVATE_KEY går inte att läsa: ' + String(e)); }

  const job = await rpc('push_job', { p_meetup: meetup, p_secret: secret });
  if (!job.ok) return new Response('push_job ' + job.status, { status: job.status === 403 ? 403 : 502 });
  const rows: Row[] = await job.json();
  const region = Deno.env.get('SB_REGION');   // ska vara eu-west-1, se meetup_push_hook
  if (!rows.length) return Response.json({ sent: 0, region });

  // Notisen får vänta på en avstängd telefon tills träffen börjar, högst 4 veckor
  const ttl = Math.max(600, Math.min(2419200, Math.round((Date.parse(rows[0].starts_at) - Date.now()) / 1000)));
  const gone: string[] = [];
  let sent = 0;
  await Promise.all(rows.map(async r => {
    if (!PUSH_HOSTS.test(r.endpoint)) return;
    try {
      const status = await sendPush(r, JSON.stringify({ ...texts(r), tag: 'meet-' + meetup, meet: meetup }), ttl, key);
      if (status === 404 || status === 410) gone.push(r.endpoint);
      else if (status < 300) sent++;
      else console.warn('push', new URL(r.endpoint).host, status);
    } catch (e) { console.warn('push', new URL(r.endpoint).host, String(e)); }
  }));
  if (gone.length) await rpc('push_gone', { p_endpoints: gone, p_secret: secret });
  return Response.json({ sent, gone: gone.length, of: rows.length, region });
}

// I Supabase. Utan Deno (testerna i Node) laddas bara funktionerna ovan.
// x-slowlane-fn visar vilken version av koden som är inlagd. Öka den när koden ändras.
const FN_VERSION = '3';
if (typeof Deno !== 'undefined') Deno.serve(async req => {
  const res = await handle(req).catch(e => fail(String(e && e.stack || e)));
  res.headers.set('x-slowlane-fn', FN_VERSION);
  return res;
});
