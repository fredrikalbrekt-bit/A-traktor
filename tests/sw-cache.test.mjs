// Kör sw.js i en låtsad service worker med riktiga, namngivna cacher och kontrollerar
// vad installationen hämtar, vad en ny version behåller, och bilder och gröna vägar.
import fs from 'node:fs';
import vm from 'node:vm';

const inRepo = p => new URL('../' + p, import.meta.url);
const src = fs.readFileSync(inRepo('sw.js'), 'utf8');
const VERSION = src.match(/VERSION = '([^']+)'/)[1];
const SCOPE = 'https://fredrikalbrekt-bit.github.io/A-traktor/';
const abs = k => new URL(typeof k === 'string' ? k : k.url, SCOPE).href.split('?')[0];

// cacher: namn -> Map(url -> text)
const stores = new Map();
const cacheObj = name => {
  if (!stores.has(name)) stores.set(name, new Map());
  const m = stores.get(name);
  return {
    put: async (k, res) => { m.set(abs(k), await res.text()); },
    match: async k => m.has(abs(k)) ? new Response(m.get(abs(k))) : undefined,
    addAll: async reqs => { installed = reqs.map(r => abs(r).replace(SCOPE, './')); for (const r of reqs) { const res = await fetchMock(r); if (!res.ok) throw new Error('addAll ' + res.status); m.set(abs(r), await res.text()); } }
  };
};
let installed = [];
const caches = {
  open: async name => cacheObj(name),
  match: async k => { for (const m of stores.values()) if (m.has(abs(k))) return new Response(m.get(abs(k))); },
  keys: async () => [...stores.keys()],
  delete: async name => stores.delete(name)
};

// nätet: url -> { body, status, delay, fail }
let net = {}, netDown = false;
const fetches = [];
const fetchMock = r => {
  const u = abs(r); fetches.push(u.replace(SCOPE, ''));
  const o = net[u.replace(SCOPE, '')] || {};
  return new Promise((ok, no) => setTimeout(() => netDown || o.fail ? no(new TypeError('Failed to fetch'))
    : ok(new Response(o.body ?? 'NET:' + u.replace(SCOPE, ''), { status: o.status || 200 })), o.delay || 5));
};

const handlers = {};
class Req extends Request { constructor(input, init) { super(typeof input === 'string' ? new URL(input, SCOPE).href : input, init); } }
const self = { addEventListener: (t, f) => { handlers[t] = f; }, location: new URL(SCOPE + 'sw.js'), registration: { scope: SCOPE }, skipWaiting() {}, clients: { claim() {} } };
vm.runInNewContext(src, { self, caches, fetch: fetchMock, Request: Req, Response, URL, setTimeout, clearTimeout, location: self.location, Promise, console });

const life = async (type, extra = {}) => { const ps = []; handlers[type]({ waitUntil: p => ps.push(p), ...extra }); await Promise.all(ps); };
async function get(path) {
  let resP; const ps = [];
  handlers.fetch({ request: new Req(SCOPE + path), respondWith: p => { resP = p; }, waitUntil: p => ps.push(p) });
  if (!resP) return { passed: true };
  const res = await resP; const body = await res.text(); await Promise.all(ps);
  return { body, status: res.status };
}
const results = [];
const check = (name, ok, info = '') => { results.push(ok); console.log(ok ? 'OK  ' : 'FEL ', name, info && JSON.stringify(info)); };
const has = (name, path) => stores.has(name) && stores.get(name).has(SCOPE + path);

// ---------- Installation: bara det som första besöket visar ----------
await life('install');
const must = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './apple-touch-icon.png', './epa-hero.webp', './moped2-hero.webp', './moped1-hero.webp', './mopedbil-hero.webp'];
const never = ['./icon-512.png', './icon-maskable-512.png', './moped2-rain.webp', './moped2-cool.webp', './moped2-cold.webp', './dust.webp', './epa-fog.webp'];
check('installationen hämtar appen, små ikoner och fordonsbilderna', must.every(p => installed.includes(p)), installed);
check('installationen hämtar inte väderbilder, dimma eller stora ikoner', !never.some(p => installed.includes(p)));
check('alla filer i installationen finns i repot', must.filter(p => p !== './').every(p => fs.existsSync(inRepo(p.slice(2)))));

// ---------- Bilder ----------
fetches.length = 0;
let r = await get('epa-hero.webp');
check('fordonsbild visas från cachen utan nät', r.body === 'NET:epa-hero.webp' && fetches.length === 0, fetches);
r = await get('moped2-rain.webp');
check('väderbild hämtas första gången', r.body === 'NET:moped2-rain.webp' && fetches.includes('moped2-rain.webp'));
check('... och sparas i versionens cache', has(VERSION, 'moped2-rain.webp'));
netDown = true; fetches.length = 0;
r = await get('moped2-rain.webp');
check('... och visas sedan utan nät', r.body === 'NET:moped2-rain.webp' && fetches.length === 0);
netDown = false;
net['epa-fog.webp'] = { status: 404, body: 'nope' };
r = await get('epa-fog.webp');
check('en bild som saknas (404) sparas inte', r.status === 404 && !has(VERSION, 'epa-fog.webp'));
delete net['epa-fog.webp'];

// ---------- Gröna vägar ----------
net['grona-vagar.json'] = { body: 'GRÖN v1' };
r = await get('grona-vagar.json');
check('gröna vägar hämtas och sparas i en egen cache', r.body === 'GRÖN v1' && has('slowlane-data', 'grona-vagar.json') && !has(VERSION, 'grona-vagar.json'));
net['grona-vagar.json'] = { body: 'GRÖN v2', delay: 300 };
const t0 = Date.now();
r = await get('grona-vagar.json');
check('sparad fil visas direkt, även med långsamt nät', r.body === 'GRÖN v1');
check('... och den nya sparas i bakgrunden', stores.get('slowlane-data').get(SCOPE + 'grona-vagar.json') === 'GRÖN v2', { ms: Date.now() - t0 });
netDown = true;
r = await get('grona-vagar.json');
check('utan nät: sparad fil', r.body === 'GRÖN v2');
netDown = false;

// ---------- Ny version: versionens cache töms, gröna vägar blir kvar ----------
stores.set('slowlane-v1', new Map([[SCOPE + 'index.html', 'GAMMAL']]));
await life('activate');
const keys = [...stores.keys()].sort();
check('ny version tar bort gamla versioners cacher', !keys.includes('slowlane-v1'), keys);
check('... men behåller versionens egen och gröna vägar', keys.includes(VERSION) && keys.includes('slowlane-data'));
check('gröna vägar finns kvar efter en ny version', stores.get('slowlane-data').get(SCOPE + 'grona-vagar.json') === 'GRÖN v2');

console.log(results.every(Boolean) ? '\nALLA OK' : '\n' + results.filter(x => !x).length + ' FEL');
process.exit(results.every(Boolean) ? 0 : 1);
