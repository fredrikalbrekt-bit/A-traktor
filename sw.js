// Slowlane service worker
const VERSION = 'slowlane-v23';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png', './epa-hero.webp', './epa-fog.webp', './moped2-hero.webp', './moped2-rain.webp', './moped2-cool.webp', './moped2-cold.webp', './dust.webp', './mopedbil-hero.webp', './moped1-hero.webp'];
const LIBS = ['cdn.jsdelivr.net', 'unpkg.com', 'fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Appen själv: hämta alltid senaste versionen, använd cachen bara offline
  if (req.mode === 'navigate' || (url.origin === location.origin && SHELL.some(p => url.pathname.endsWith(p.replace('./', '/')) && p !== './'))) {
    e.respondWith(
      fetch(req).then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req.mode === 'navigate' ? './index.html' : req, copy)); }
        return res;
      }).catch(() => caches.match(req.mode === 'navigate' ? './index.html' : req).then(r => r || caches.match('./index.html')))
    );
    return;
  }

  // Gröna vägar: visa sparad fil direkt, hämta ny i bakgrunden
  if (url.origin === location.origin && url.pathname.endsWith('grona-vagar.json')) {
    e.respondWith(caches.open(VERSION).then(async c => {
      const hit = await c.match(req, { ignoreSearch: true });
      const net = fetch(req).then(res => { if (res.ok) c.put(req, res.clone()); return res; }).catch(() => hit);
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
