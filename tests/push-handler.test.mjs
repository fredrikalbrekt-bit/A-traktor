// Kör notisfunktionen i Node med låtsas-Deno, låtsas-Supabase och låtsas-notistjänster.
// node tests/push-handler.test.mjs
// Testet gör ett eget nyckelpar och sätter in den publika nyckeln i en kopia av funktionen,
// så att den riktiga privata nyckeln aldrig behövs här. Den finns bara i Supabase.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
let fails = 0;
const ok = (c, what) => { console.log((c ? 'ok   ' : 'FEL  ') + what); if (!c) fails++; };
const sub = crypto.subtle;
const b64u = b => Buffer.from(b).toString('base64url');
console.error = () => {}; console.warn = () => {};   // funktionens loggar syns inte i testet

// En telefon med riktiga nycklar, så att meddelandet går att dekryptera
const phone = await sub.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
const phonePub = new Uint8Array(await sub.exportKey('raw', phone.publicKey));
const phoneAuth = crypto.getRandomValues(new Uint8Array(16));
const ID = '7a1b2c3d-1111-2222-3333-444455556666', SECRET = 'a'.repeat(64);
const row = ep => ({ endpoint: ep, p256dh: b64u(phonePub), auth: b64u(phoneAuth), lang: 'sv', title: 'Biltema', group_name: 'Leffe', creator_nick: 'kunksgrillen', starts_at: new Date(Date.now() + 2 * 36e5).toISOString() });
let rows = [row('https://web.push.apple.com/abc'), row('https://fcm.googleapis.com/fcm/send/gone1'), row('https://evil.example/x')];

const calls = [];
let dbDown = null;   // ett fel som databasen kastar, för krascher
globalThis.fetch = async (url, opt = {}) => {
  url = String(url); calls.push({ url, opt });
  if (url.includes('/rest/v1/rpc/push_job')) {
    const b = JSON.parse(opt.body);
    if (b.p_secret === 'krasch') { await new Promise(r => setTimeout(r, 50)); throw new Error('databasen nere vid /hemlig/sokvag'); }
    if (b.p_secret !== SECRET) return new Response(JSON.stringify({ message: 'bad secret' }), { status: 403 });
    if (dbDown) { await new Promise(r => setTimeout(r, dbDown.wait || 0)); throw new Error(dbDown.msg); }
    return new Response(JSON.stringify(rows), { status: 200 });
  }
  if (url.includes('/rest/v1/rpc/push_gone')) return new Response(null, { status: 204 });
  if (url.includes('gone1')) return new Response('', { status: 410 });
  if (pushWait) await new Promise(r => setTimeout(r, pushWait));
  return new Response('', { status: 201 });
};
let pushWait = 0;
let handler = null;
const vapid = await sub.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign']);
const privateD = (await sub.exportKey('jwk', vapid.privateKey)).d;
const vapidPub = b64u(new Uint8Array(await sub.exportKey('raw', vapid.publicKey)));
const src = readFileSync(new URL('../supabase/functions/meetup-push/index.ts', import.meta.url), 'utf8');
if (!/const VAPID_PUBLIC = '[\w-]+';/.test(src)) throw new Error('VAPID_PUBLIC hittades inte i funktionen');
const dir = mkdtempSync(join(tmpdir(), 'slowlane-push-'));
const fnPath = join(dir, 'index.ts');
writeFileSync(fnPath, src.replace(/const VAPID_PUBLIC = '[\w-]+';/, `const VAPID_PUBLIC = '${vapidPub}';`));
let envKey = privateD, envHook;
globalThis.Deno = { serve: h => { handler = h; }, env: { get: k => ({ VAPID_PRIVATE_KEY: envKey, SLOWLANE_HOOK_SECRET: envHook, SB_REGION: 'eu-west-1' })[k] } };
try { await import(pathToFileURL(fnPath).href); } finally { rmSync(dir, { recursive: true, force: true }); }
ok(typeof handler === 'function', 'Deno.serve fick en funktion');
ok((await handler(new Request('https://x/', { method: 'GET' }))).headers.get('x-slowlane-fn') === '4', 'svaret visar kodens version 4');
const req = (body, secret, method = 'POST') => new Request('https://x/functions/v1/meetup-push', { method, body: method === 'POST' ? JSON.stringify(body) : undefined, headers: secret ? { 'x-slowlane-hook': secret } : {} });

// ---------- Fas A: utan SLOWLANE_HOOK_SECRET kontrollerar databasen hemligheten (som version 3) ----------
ok((await handler(req({ meetup: ID }, null))).status === 403, 'utan hemlighet: 403');
ok(calls.length === 0, '... inga anrop alls');
ok((await handler(req({ meetup: ID }, SECRET, 'GET'))).status === 403, 'GET: 403');
ok((await handler(req({ meetup: 42 }, SECRET))).status === 400, 'id som inte är text: 400');
ok((await handler(req({ meetup: ID }, 'fel'))).status === 403, 'fel hemlighet: databasen säger nej och funktionen svarar 403');

// Trasig nyckel: träffen förbrukas inte, och den som inte visat rätt hemlighet får inga detaljer
calls.length = 0;
for (const [bad, what] of [[undefined, 'saknas'], ['', 'tom'], [privateD.slice(0, 40), 'för kort'], ['A'.repeat(43), 'fel nyckel']]) {
  envKey = bad;
  const r = await handler(req({ meetup: ID }, 'fel')), j = await r.json().catch(() => ({}));
  ok(r.status === 500 && j.error === 'internal error', `nyckeln ${what}: 500 utan detaljer (${j.error})`);
}
ok(!calls.some(c => c.url.includes('push_job')), 'trasig nyckel: push_job anropas inte, så träffen kan skickas när nyckeln är rättad');
envKey = '"' + privateD + '"\n';   // inklistrad med citattecken och radbrytning

// Krasch före kontrollen: inga detaljer
dbDown = { msg: 'databasen nere vid /hemlig/sokvag' };
{ const r = await handler(req({ meetup: ID }, SECRET)), t = await r.text();
  ok(r.status === 500 && t.includes('internal error') && !t.includes('sokvag'), 'krasch innan hemligheten är kontrollerad: 500 utan detaljer (' + t + ')'); }
dbDown = null;

// ---------- Fas B: SLOWLANE_HOOK_SECRET finns, inklistrad med citattecken och radbrytning ----------
envHook = '"' + SECRET + '"\n';
calls.length = 0;
{ const r = await handler(req({ meetup: ID }, 'fel')), t = await r.text();
  ok(r.status === 403 && t === 'not allowed', 'fel hemlighet: 403 "not allowed" utan detaljer');
  ok(calls.length === 0, '... och ingen fråga till databasen'); }
{ const r = await handler(req({ meetup: ID }, SECRET.slice(0, 63) + 'b')); ok(r.status === 403 && calls.length === 0, 'nästan rätt hemlighet: 403 utan fråga till databasen'); }
for (const [bad, what] of [[undefined, 'saknas'], ['A'.repeat(43), 'fel nyckel']]) {
  envKey = bad; calls.length = 0;
  const r = await handler(req({ meetup: ID }, SECRET)), j = await r.json().catch(() => ({}));
  ok(r.status === 500 && /VAPID_PRIVATE_KEY/.test(j.error || '') && calls.length === 0, `rätt hemlighet, nyckeln ${what}: 500 med förklaring och ingen fråga till databasen (${j.error})`);
}
envKey = privateD;
dbDown = { msg: 'databasen nere' };
{ const r = await handler(req({ meetup: ID }, SECRET)), t = await r.text();
  ok(r.status === 500 && t.includes('databasen nere'), 'krasch efter rätt hemlighet: detaljerna syns för databasen'); }

// Två samtidiga utan SLOWLANE_HOOK_SECRET: en främling väntar på databasen, som kraschar efter 50 ms.
// Under tiden blir ett riktigt anrop betrott och skickar notiser i 150 ms. Främlingen får ändå inga detaljer.
envHook = undefined; dbDown = null; pushWait = 150;
{ const b = handler(req({ meetup: ID }, 'krasch'));
  await new Promise(r => setTimeout(r, 5));
  const a = handler(req({ meetup: ID }, SECRET));
  const tb = await (await b).text(), ra = await a;
  ok(tb === '{"error":"internal error"}' && ra.status === 200, 'samtidiga anrop delar inte på förtroendet (främlingen fick ' + tb + ')'); }
pushWait = 0;
envHook = SECRET;
calls.length = 0;

// ---------- Rätt anrop ----------
const res = await handler(req({ meetup: ID }, SECRET));
const out = await res.json();
ok(res.status === 200 && out.sent === 1 && out.gone === 1 && out.of === 3 && out.region === 'eu-west-1', 'svar: 1 skickad, 1 borta, 3 mottagare, Irland (fick ' + JSON.stringify(out) + ')');
ok(!calls.some(c => c.url.includes('evil.example')), 'okänd notistjänst får ingenting');
const gone = calls.find(c => c.url.includes('push_gone'));
ok(gone && JSON.parse(gone.opt.body).p_endpoints.join() === 'https://fcm.googleapis.com/fcm/send/gone1' && JSON.parse(gone.opt.body).p_secret === SECRET, 'adressen som svarade 410 tas bort');
const job = calls.find(c => c.url.includes('push_job'));
ok(job.opt.headers.apikey.startsWith('sb_publishable_') && job.opt.headers.Authorization === 'Bearer ' + job.opt.headers.apikey, 'databasen anropas med den publika nyckeln');

const apple = calls.find(c => c.url.startsWith('https://web.push.apple.com/'));
const h = apple.opt.headers;
ok(h['Content-Encoding'] === 'aes128gcm' && h['Content-Type'] === 'application/octet-stream' && h.Urgency === 'high', 'rubriker: aes128gcm, octet-stream, Urgency high');
ok(+h.TTL > 7000 && +h.TTL <= 7200, 'TTL: tills träffen börjar, ungefär 2 timmar (fick ' + h.TTL + ')');
ok(/^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=B[\w-]{86}$/.test(h.Authorization), 'VAPID-rubrik');
ok(JSON.parse(Buffer.from(h.Authorization.split('.')[1], 'base64url')).aud === 'https://web.push.apple.com', 'VAPID aud = Apples origin');

// Dekryptera som telefonen
const body = new Uint8Array(apple.opt.body);
const salt = body.slice(0, 16), asPub = body.slice(21, 86), sealed = body.slice(86);
const asKey = await sub.importKey('raw', asPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
const ecdh = await sub.deriveBits({ name: 'ECDH', public: asKey }, phone.privateKey, 256);
const hkdf = async (s, ikm, info, len) => new Uint8Array(await sub.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: s, info }, await sub.importKey('raw', ikm, 'HKDF', false, ['deriveBits']), len * 8));
const te = s => new TextEncoder().encode(s);
const ikm = await hkdf(phoneAuth, ecdh, Buffer.concat([te('WebPush: info\0'), phonePub, asPub]), 32);
const plain = new Uint8Array(await sub.decrypt({ name: 'AES-GCM', iv: await hkdf(salt, ikm, te('Content-Encoding: nonce\0'), 12) },
  await sub.importKey('raw', await hkdf(salt, ikm, te('Content-Encoding: aes128gcm\0'), 16), 'AES-GCM', false, ['decrypt']), sealed));
const msg = JSON.parse(new TextDecoder().decode(plain.slice(0, -1)));
ok(msg.title === 'Ny träff i Leffe', 'telefonen läser rubriken: ' + msg.title);
ok(/^🏁 Biltema · (idag|imorgon) \d\d:\d\d · av kunksgrillen$/.test(msg.body), 'telefonen läser texten: ' + msg.body);
ok(msg.meet === ID && msg.tag === 'meet-' + ID, 'notisen pekar på träffen');

// Inga mottagare: inga utskick
rows = []; calls.length = 0;
const empty = await (await handler(req({ meetup: ID }, SECRET))).json();
ok(empty.sent === 0 && calls.length === 1, 'inga mottagare: bara anropet till databasen');

console.log(fails ? `\n${fails} FEL` : '\nALLA OK');
process.exit(fails ? 1 : 0);
