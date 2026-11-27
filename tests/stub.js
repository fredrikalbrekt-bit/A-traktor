// Test harness for Slowlane: runs before the app script. Fakes Supabase, Stadia, GPS, wake lock and confirm().
(() => {
  const realFetch = window.fetch.bind(window);
  const realNow = Date.now.bind(Date);
  window.__shift = 0; Date.now = () => realNow() + window.__shift;
  window.__log = [];
  window.__rpc = { meetup_list: [], group_list: [], god_me: false, ride_ping: [] };
  // låtsas vara en annan telefon: localStorage.__ua = 'Mozilla/5.0 (iPhone; ...)'
  try { const ua = localStorage.getItem('__ua'); if (ua) Object.defineProperty(navigator, 'userAgent', { get: () => ua, configurable: true }); } catch {}
  // svar som ska finnas redan när appen startar: localStorage.__rpc = '{"group_list":[...]}'
  try { Object.assign(window.__rpc, JSON.parse(localStorage.getItem('__rpc') || '{}')); } catch {}
  window.__auth = null;
  window.__route = null;
  const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } });
  window.__json = json;
  window.fetch = async (u, opt = {}) => {
    const url = String((u && u.url) || u);
    let body = null; try { body = opt.body ? JSON.parse(opt.body) : null; } catch {}
    // window.__intercept = url => Response | undefined: tar över vilket anrop som helst, t.ex. 429 från Stadia
    if (window.__intercept) { const r = window.__intercept(url, body, opt); if (r) { window.__log.push({ intercepted: url }); return r; } }
    if (url.includes('supabase.co/rest/v1/rpc/')) {
      const fn = url.split('/rpc/')[1]; window.__log.push({ rpc: fn, body, auth: opt.headers && opt.headers.Authorization });
      const v = window.__rpc[fn]; return typeof v === 'function' ? v(body) : json(v === undefined ? null : v);
    }
    if (url.includes('supabase.co/auth/v1/')) { window.__log.push({ auth: url.split('/auth/v1/')[1], body }); return window.__auth ? window.__auth(body) : json({}, 400); }
    if (url.includes('supabase.co')) return json({});
    if (url.includes('api.stadiamaps.com/route/v1')) { window.__log.push({ route: body }); return window.__route ? window.__route(body, opt) : json(window.__tripFor(body)); }
    if (url.includes('api.stadiamaps.com')) return json({}, 400);
    if (/open-meteo|overpass|mail\.ru|kumi|private\.coffee|photon|nominatim/.test(url)) return json({}, 503);
    return realFetch(u, opt);
  };

  // GPS
  window.__geo = { lat: 59.3326, lng: 18.0649, acc: 10 };
  window.__watchers = [];
  const mk = g => ({ coords: { latitude: g.lat, longitude: g.lng, accuracy: g.acc ?? 10, heading: g.heading ?? null, speed: g.speed ?? null }, timestamp: g.t ?? Date.now() });
  const geo = {
    // __geoFail: true = ingen position i tid (kod 2), 1 = nekad, 3 = tidsgräns. __geoCalls räknar frågorna.
    getCurrentPosition: (ok, no) => { window.__geoCalls = (window.__geoCalls || 0) + 1; setTimeout(() => window.__geoFail ? no && no({ code: typeof window.__geoFail === 'number' ? window.__geoFail : 2 }) : ok(mk(window.__geo)), 30); },
    watchPosition: (ok, no) => { window.__watchers.push(ok); (window.__watchErr = window.__watchErr || []).push(no); return window.__watchers.length; },
    clearWatch: id => { window.__watchers[id - 1] = null; }
  };
  Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true });
  window.__fix = g => window.__watchers.forEach(w => w && w(mk(g)));
  window.__activeWatchers = () => window.__watchers.filter(Boolean).length;

  // Skärmlås
  window.__wakeOk = true; window.__wakeReqs = 0;
  Object.defineProperty(navigator, 'wakeLock', { configurable: true, value: { request: () => { window.__wakeReqs++;
    return window.__wakeOk ? Promise.resolve(Object.assign(new EventTarget(), { release() { this.dispatchEvent(new Event('release')); return Promise.resolve(); } })) : Promise.reject(new Error('denied')); } } });
  window.__confirm = true; window.__confirms = 0; window.confirm = () => { window.__confirms++; return window.__confirm; };
  window.alert = m => window.__log.push({ alert: m });

  // Valhalla-resor: polyline6 och manövrar
  const enc = pts => { let out = '', pl = 0, pg = 0; const e = v => { v = v < 0 ? ~(v << 1) : v << 1; let s = ''; while (v >= 0x20) { s += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5; } return s + String.fromCharCode(v + 63); };
    pts.forEach(([la, lo]) => { const a = Math.round(la * 1e6), b = Math.round(lo * 1e6); out += e(a - pl) + e(b - pg); pl = a; pg = b; }); return out; };
  const R = 6371000, rad = d => d * Math.PI / 180;
  const hav = (a, b) => { const dl = rad(b[0] - a[0]), dg = rad(b[1] - a[1]); const h = Math.sin(dl / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(dg / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(h)); };
  window.__hav = hav;
  // Rak linje med en punkt var ~25:e meter, en sväng i mitten
  window.__line = (a, b) => { const n = Math.max(2, Math.ceil(hav(a, b) / 25)); return Array.from({ length: n + 1 }, (_, i) => [a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n]); };
  window.__trip = (pts, kmh = 40) => {
    let m = 0; for (let i = 1; i < pts.length; i++) m += hav(pts[i - 1], pts[i]);
    const km = m / 1000, s = m / (kmh / 3.6), mid = Math.floor(pts.length / 2);
    const half = (a, b) => { let x = 0; for (let i = a + 1; i <= b; i++) x += hav(pts[i - 1], pts[i]); return x / 1000; };
    const maneuvers = [
      { type: 1, instruction: 'Kör norrut på Testgatan.', verbal_pre_transition_instruction: 'Kör norrut.', begin_shape_index: 0, length: half(0, mid), time: s / 2, street_names: ['Testgatan'] },
      { type: 10, instruction: 'Sväng höger in på Provvägen.', verbal_transition_alert_instruction: 'Sväng snart höger.', verbal_pre_transition_instruction: 'Sväng höger.', begin_shape_index: mid, length: half(mid, pts.length - 1), time: s / 2, street_names: ['Provvägen'] },
      { type: 4, instruction: 'Du är framme.', begin_shape_index: pts.length - 1, length: 0, time: 0 }
    ];
    return { trip: { legs: [{ shape: enc(pts), maneuvers, summary: { length: km, time: s } }], summary: { length: km, time: s }, locations: [] } };
  };
  window.__tripFor = body => { const [a, b] = body.locations; return window.__trip(window.__line([a.lat, a.lon], [b.lat, b.lon])); };
})();
