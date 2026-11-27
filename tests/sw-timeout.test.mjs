// Kör sw.js i en låtsad service worker och kontrollerar att den sparade appen visas efter 3 s när nätet är långsamt.
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(new URL('../sw.js', import.meta.url), 'utf8');
const ORIGIN = 'https://fredrikalbrekt-bit.github.io';
const store = new Map();   // url -> body text
const keyOf = k => new URL(typeof k === 'string' ? k : k.url, ORIGIN + '/A-traktor/').href;
const caches = {
  open: async () => ({ put: async (k, res) => { store.set(keyOf(k), await res.text()); }, match: async k => store.has(keyOf(k)) ? new Response(store.get(keyOf(k))) : undefined, addAll: async () => {} }),
  match: async k => store.has(keyOf(k)) ? new Response(store.get(keyOf(k))) : undefined,
  keys: async () => [], delete: async () => true
};
let net = { delay: 0, fail: false, body: 'NEW' }, fetches = 0;
const fetchMock = () => { fetches++; return new Promise((ok, no) => setTimeout(() => net.fail ? no(new TypeError('Failed to fetch')) : ok(new Response(net.body)), net.delay)); };
const handlers = {};
const self = { addEventListener: (t, f) => { handlers[t] = f; }, location: new URL(ORIGIN + '/A-traktor/sw.js'), registration: { scope: ORIGIN + '/A-traktor/' }, skipWaiting() {}, clients: { claim() {} } };
vm.runInNewContext(src, { self, caches, fetch: fetchMock, Request, Response, URL, setTimeout, clearTimeout, location: self.location, Promise, console });

async function run(req) {
  let resP, life = [];
  const t0 = Date.now();
  handlers.fetch({ request: req, respondWith: p => { resP = p; }, waitUntil: p => life.push(p) });
  if (!resP) return { passed: true };
  const res = await resP;
  const ms = Date.now() - t0;
  const body = res.type === 'error' ? 'ERROR' : await res.text();
  await Promise.all(life);
  return { body, ms, stored: store.get(ORIGIN + '/A-traktor/index.html') };
}
const nav = { method: 'GET', url: ORIGIN + '/A-traktor/', mode: 'navigate' };
const results = [];
const check = (name, ok, info) => { results.push(ok); console.log(ok ? 'OK  ' : 'FEL ', name, JSON.stringify(info)); };

store.set(ORIGIN + '/A-traktor/index.html', 'OLD');
net = { delay: 100, fail: false, body: 'NEW1' };
let r = await run(nav); check('snabbt nät ger ny version', r.body === 'NEW1' && r.ms < 1000 && r.stored === 'NEW1', r);

net = { delay: 6000, fail: false, body: 'NEW2' };
r = await run(nav); check('långsamt nät: sparad app efter ~3 s, ny sparas sedan', r.body === 'NEW1' && r.ms >= 2900 && r.ms < 3600 && r.stored === 'NEW2', r);

net = { delay: 50, fail: true };
r = await run(nav); check('inget nät: sparad app direkt', r.body === 'NEW2' && r.ms < 1000, r);

store.clear();
net = { delay: 4500, fail: false, body: 'NEW3' };
r = await run(nav); check('långsamt nät utan sparad app: väntar på nätet', r.body === 'NEW3' && r.ms >= 4400, r);

store.clear();
net = { delay: 50, fail: true };
r = await run(nav); check('varken nät eller sparad app: fel', r.body === 'ERROR', r);

store.set(ORIGIN + '/A-traktor/epa-hero.webp', 'IMG'); fetches = 0;
net = { delay: 50, fail: false, body: 'IMG-NEW' };
r = await run(new Request(ORIGIN + '/A-traktor/epa-hero.webp')); check('bild från cachen utan nät', r.body === 'IMG' && fetches === 0, { ...r, fetches });

process.exit(results.every(Boolean) ? 0 : 1);
