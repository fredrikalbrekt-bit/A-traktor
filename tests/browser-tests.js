// Webbläsartester för Slowlane. Kör: node tests/serve.mjs och öppna http://localhost:5173/tests/run.html
// Varje test startar appen på nytt i en ram med tests/stub.js, som låtsas vara Supabase, Stadia, GPS och skärmlås.
// Resultatet syns på sidan, och sidans titel blir "OK n/n" eller "FEL x av n".
(() => {
  const frame = document.getElementById('app'), out = document.getElementById('out'), sum = document.getElementById('sum');
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  let w, d;   // appens fönster och dokument
  const $ = id => d.getElementById(id);
  const on = id => $(id).classList.contains('on');
  const expect = (ok, what) => { if (!ok) throw new Error(what); };
  async function until(fn, what, ms = 10000) {
    const t0 = Date.now();
    for (;;) {
      let v; try { v = fn(); } catch {}
      if (v) return v;
      if (Date.now() - t0 > ms) throw new Error('väntade förgäves på ' + what);
      await sleep(25);
    }
  }

  // Startar appen med de sparade värden testet behöver: inloggad, EPA, svenska. Allt från förra testet tas bort.
  async function boot(saved = {}, rpc = {}) {
    Object.keys(localStorage).filter(k => k.startsWith('atp.') || k.startsWith('__')).forEach(k => localStorage.removeItem(k));
    const base = { theme: 'epa', speed: 30, lang: 'sv', nick: 'Testare',
      supa: { token: 't', refresh: 'r', exp: Date.now() / 1000 + 3600, anon: false, email: 'test@example.invalid' } };
    Object.entries({ ...base, ...saved }).forEach(([k, v]) => { if (v !== undefined) localStorage.setItem('atp.' + k, JSON.stringify(v)); });
    localStorage.setItem('__rpc', JSON.stringify(rpc));
    frame.src = '/index.html?test=1&n=' + Math.random();
    await new Promise(r => { frame.onload = r; });
    w = frame.contentWindow; d = w.document;
    await until(() => on('v-plan') && !$('welcome').open, 'startsidan');
    w.__seen = [];
  }

  // Låtsad Stadia-sökning. Alla adresser som appen hämtar sparas i w.__seen.
  const PLACE = { lat: 59.3406, lng: 18.0812, name: 'Testgatan 1', area: 'Stockholm' };
  function fakeSearch(status = 200) {
    w.__intercept = url => {
      w.__seen.push(url);
      if (!url.includes('/geocoding/')) return undefined;
      if (status !== 200) return w.__json({}, status);
      return w.__json({ features: [{ geometry: { coordinates: [PLACE.lng, PLACE.lat] },
        properties: { gid: 'test:1', name: PLACE.name, label: PLACE.name + ', ' + PLACE.area, locality: PLACE.area } }] });
    };
  }
  async function typeTo(text = 'Testg') {
    $('to').click();
    await until(() => !$('search').hidden, 'sökvyn');
    $('sIn').value = text;
    $('sIn').dispatchEvent(new w.Event('input', { bubbles: true }));
  }
  async function chooseTo() {
    await typeTo();
    const b = await until(() => [...$('sugg').querySelectorAll('button')].find(x => x.textContent.includes(PLACE.name)), 'sökförslaget');
    b.click();
    await until(() => $('search').hidden && $('to').value, 'valt mål');
  }
  async function toResult() {
    fakeSearch(); await chooseTo();
    $('go').click();
    await until(() => on('v-res'), 'resultatvyn');
  }

  const tests = [];
  const test = (name, fn) => tests.push({ name, fn });

  test('Startsidan: Från är Min position, och positionen hämtas först när rutten räknas', async () => {
    await boot();
    expect($('from').value === 'Min position', 'Från är "' + $('from').value + '"');
    expect(!w.__geoCalls, 'positionen hämtades när appen startade');
    expect($('spVal').textContent === '30', 'maxhastigheten är ' + $('spVal').textContent);
  });

  test('Engelska: rubrik och knapp är översatta', async () => {
    await boot({ lang: 'en' });
    expect(d.querySelector('#v-plan h1').textContent === 'Where to?', 'rubriken är "' + d.querySelector('#v-plan h1').textContent + '"');
    expect($('go').textContent === 'Calculate route', 'knappen är "' + $('go').textContent + '"');
  });

  test('Sök: Till hämtar gröna vägar i förväg och visar förslag', async () => {
    await boot(); fakeSearch(); await typeTo();
    expect(w.__seen.some(u => u.includes('grona-vagar.json')), 'gröna vägar hämtades inte när Till öppnades');
    await until(() => $('sugg').textContent.includes(PLACE.name), 'sökförslaget');
  });

  test('Sök: gränsen hos Stadia (429) ger en egen text', async () => {
    await boot(); fakeSearch(429); await typeTo();
    await until(() => $('sugg').textContent.includes('Kartjänsten tar inte emot fler sökningar'), 'texten om gränsen');
  });

  test('Rutt: knappen visar stegen, resultatet kommer och fokus flyttas', async () => {
    await boot(); fakeSearch(); await chooseTo();
    const texts = [];
    const mo = new w.MutationObserver(() => texts.push($('go').textContent));
    mo.observe($('go'), { childList: true, subtree: true, characterData: true });
    $('go').click();
    await until(() => on('v-res'), 'resultatvyn');
    mo.disconnect();
    ['Hämtar position', 'Söker vägar', 'Kontrollerar motorvägar', 'Väger säkerhet'].forEach(s =>
      expect(texts.some(t => t.includes(s)), `steget "${s}" visades inte (${texts.join(' | ')})`));
    expect(w.__geoCalls === 1, 'positionen hämtades ' + w.__geoCalls + ' gånger');
    expect($('rName').textContent.includes(PLACE.name), 'ruttens namn är "' + $('rName').textContent + '"');
    await until(() => d.activeElement === $('rName'), 'fokus på ruttens namn');
    $('back').click();
    await until(() => on('v-plan') && d.activeElement === d.querySelector('#v-plan h1'), 'fokus på rubriken efter Tillbaka');
  });

  test('Rutt: ett tidigare mål räknas med ett tryck', async () => {
    await boot({ recent: [{ label: PLACE.name + ', ' + PLACE.area, short: PLACE.name, loc: { lat: PLACE.lat, lng: PLACE.lng } }] });
    const chip = await until(() => $('recent').querySelector('button'), 'det senaste målet');
    chip.click();
    await until(() => on('v-res'), 'resultatvyn');
  });

  test('Rutt: gränsen hos Stadia (429) ger en egen text', async () => {
    await boot(); fakeSearch(); await chooseTo();
    w.__route = () => w.__json({}, 429);
    $('go').click();
    await until(() => $('msg').textContent.includes('Kartjänsten tar inte emot fler sökningar'), 'texten om gränsen');
    expect(!on('v-res'), 'resultatvyn visades');
  });

  test('Avbryt: anropen stoppas, knappen blir som vanligt och inget visas efteråt', async () => {
    await boot(); fakeSearch(); await chooseTo();
    const signals = [];
    w.__route = (body, opt) => { signals.push(opt.signal); return new Promise((ok, no) => opt.signal.addEventListener('abort', () => no(new w.DOMException('avbruten', 'AbortError')))); };
    $('go').click();
    await until(() => signals.length && !$('goCancel').hidden, 'en pågående beräkning');
    $('goCancel').click();
    expect(!$('go').disabled && $('go').textContent === 'Beräkna rutt' && $('goCancel').hidden, 'knappen blev inte som vanligt');
    expect(signals.every(s => s.aborted), 'alla anrop stoppades inte');
    await sleep(400);
    expect(!on('v-res') && !$('msg').textContent, 'något visades efter Avbryt: "' + $('msg').textContent + '"');
    w.__route = null;
    $('go').click();
    await until(() => on('v-res'), 'en ny beräkning efter Avbryt');
  });

  test('Navigering: instruktionen syns och får fokus, framme vid målet, Avsluta stänger GPS:en', async () => {
    await boot(); await toResult();
    $('startNav').click();
    await until(() => on('v-nav'), 'navigeringen');
    expect($('nText').textContent.length > 2, 'ingen instruktion');
    await until(() => d.activeElement === $('nText'), 'fokus på instruktionen');
    // kör längs rutten i 30 km/h: en position var 25:e meter, 3 s emellan (appen bortser från orimliga hopp)
    const pts = w.__line([w.__geo.lat, w.__geo.lng], [PLACE.lat, PLACE.lng]), t0 = Date.now(), seen = new Set();
    for (const [i, [lat, lng]] of pts.entries()) {
      w.__fix({ lat, lng, acc: 5, speed: 8.3, t: t0 + i * 3000 });
      seen.add($('nText').textContent);
      await sleep(5);
    }
    expect(seen.has('Sväng höger in på Provvägen.'), 'svängen visades inte (' + [...seen].join(' | ') + ')');
    await until(() => $('nText').textContent === 'Du är framme.', '"Du är framme."');
    $('nEnd').click();
    await until(() => on('v-res'), 'resultatvyn efter Avsluta');
    expect(w.__activeWatchers() === 0, 'GPS-bevakningen är kvar');
  });

  test('Träff: nästa träff syns på startsidan och Kör hit räknar rutten', async () => {
    const starts = new Date(Date.now() + 2 * 36e5).toISOString();
    await boot({}, { meetup_list: [{ id: 'm1', title: 'Fika vid macken', group_id: 'g1', group_name: 'Testgruppen', starts_at: starts, coming: 3, my_answer: null, god: false, lat: PLACE.lat, lng: PLACE.lng }],
      group_list: [{ id: 'g1', name: 'Testgruppen', members: 4, owner: false }] });
    const card = await until(() => $('meetCards').querySelector('.meet-card'), 'träffkortet');
    expect(card.textContent.includes('Fika vid macken') && card.textContent.includes('Testgruppen'), 'kortet visar "' + card.textContent + '"');
    const go = [...card.querySelectorAll('button')].find(b => b.textContent === 'Kör hit');
    expect(go, 'ingen Kör hit-knapp');
    go.click();
    await until(() => on('v-res'), 'resultatvyn');
  });

  async function run() {
    let fails = 0;
    for (const [i, t] of tests.entries()) {
      const li = document.createElement('li'); li.textContent = t.name + ' …'; out.appendChild(li);
      sum.textContent = `Kör ${i + 1} av ${tests.length}`;
      try { await t.fn(); li.className = 'ok'; li.textContent = 'OK   ' + t.name; }
      catch (e) { fails++; li.className = 'fel'; li.textContent = 'FEL  ' + t.name + ': ' + e.message; }
    }
    document.title = sum.textContent = fails ? `FEL ${fails} av ${tests.length}` : `OK ${tests.length}/${tests.length}`;
  }
  run();
})();
