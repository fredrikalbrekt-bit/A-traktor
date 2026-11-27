// Slowlane service worker
const VERSION = 'slowlane-v47';
// Det som första besöket visar: appen, de små ikonerna och fordonsbilderna i välkomststeget.
// Övriga bilder (väder, dimma, de stora ikonerna för installationen) hämtas första gången de behövs och sparas då.
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './apple-touch-icon.png', './epa-hero.webp', './moped2-hero.webp', './moped1-hero.webp', './mopedbil-hero.webp'];
// Gröna vägar i en egen cache som en ny version inte tömmer: filen ändras varje vecka, inte med appen
const DATA = 'slowlane-data';
const LIBS = ['cdn.jsdelivr.net', 'unpkg.com', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', e => {
  // no-cache: annars kan offline-kopian bli den gamla versionen från webbläsarens cache
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL.map(p => new Request(p, { cache: 'no-cache' })))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION && k !== DATA).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // Andra sidor (t.ex. integritet.html) går direkt mot nätet och sparas inte som appen
  const page = url.pathname.split('/').pop();
  if (req.mode === 'navigate' && page.endsWith('.html') && page !== 'index.html') return;

  const own = url.origin === location.origin;
  const shell = own && SHELL.some(p => url.pathname.endsWith(p.replace('./', '/')) && p !== './');
  // Bilderna byts bara i en ny version. En bild som inte redan finns sparas när den hämtas,
  // och visas sedan från cachen, även utan nät.
  if (own && /\.(webp|png)$/.test(url.pathname)) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(res => {
      if (res.ok) { const copy = res.clone(); e.waitUntil(caches.open(VERSION).then(c => c.put(req, copy))); }
      return res;
    })));
    return;
  }

  // Appen själv: hämta alltid senaste versionen.
  // GitHub Pages låter webbläsaren spara filerna i 10 minuter. no-cache frågar servern varje gång
  // (304 om inget ändrats), annars kan en ny version dröja 10 minuter.
  // Med svag signal kan svaret dröja länge: efter 3 s visas den sparade appen, och den nya sparas när den kommer.
  if (req.mode === 'navigate' || shell) {
    const nav = req.mode === 'navigate', key = nav ? './index.html' : req;
    const fresh = nav ? new Request(req.url, { cache: 'no-cache', credentials: 'same-origin' }) : new Request(req, { cache: 'no-cache' });
    let saved = Promise.resolve();
    const net = fetch(fresh).then(res => {
      if (res.ok) { const copy = res.clone(); saved = caches.open(VERSION).then(c => c.put(key, copy)); }
      return res;
    });
    const cached = () => caches.match(key).then(r => r || (nav ? caches.match('./index.html') : undefined));
    e.respondWith(new Promise(resolve => {
      let done = false;
      const answer = r => { if (r && !done) { done = true; clearTimeout(slow); resolve(r); } };
      const slow = setTimeout(() => cached().then(answer), 3000);
      net.then(answer, () => cached().then(r => { answer(r); if (!done) { done = true; resolve(Response.error()); } }));
    }));
    e.waitUntil(net.then(() => saved, () => {}).catch(() => {}));
    return;
  }

  // Gröna vägar: visa sparad fil direkt, hämta ny i bakgrunden
  if (own && url.pathname.endsWith('grona-vagar.json')) {
    e.respondWith(caches.open(DATA).then(async c => {
      const hit = await c.match(req, { ignoreSearch: true });
      let saved = Promise.resolve();
      const net = fetch(req).then(res => { if (res.ok) { const copy = res.clone(); saved = c.put(req, copy); } return res; }).catch(() => hit);
      // den nya filen hinner sparas även när sidan redan har fått den sparade
      e.waitUntil(net.then(() => saved).catch(() => {}));
      return hit || net;
    }));
    return;
  }

  // Kartbibliotek och typsnitt: visa från cache direkt, uppdatera i bakgrunden
  if (LIBS.includes(url.hostname)) {
    e.respondWith(caches.open(VERSION).then(async c => {
      const hit = await c.match(req);
      const net = fetch(req).then(res => { if (res.ok || res.type === 'opaque') c.put(req, res.clone()); return res; }).catch(() => hit);
      return hit || net;
    }));
  }
  // Allt annat (Google, Stadia, kartbrickor) går direkt mot nätet
});

// ---------- Notiser om nya träffar ----------
// Skickas av supabase/functions/meetup-push. Varje push måste visa en notis, annars kan iOS stänga av notiserna.
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch {}
  e.waitUntil(self.registration.showNotification(d.title || 'Slowlane', {
    body: d.body || '', tag: d.tag, icon: './icon-192.png', data: { meet: d.meet || null } }));
});

// Tryck på notisen: visa träffen i appen om den redan är öppen, annars öppna appen på träffen
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const meet = e.notification.data && e.notification.data.meet;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    const c = list.find(x => 'focus' in x);
    if (c) { if (meet) c.postMessage({ meet }); return c.focus(); }
    return self.clients.openWindow(new URL(meet ? './#m=' + meet : './', self.registration.scope).href);
  }));
});
