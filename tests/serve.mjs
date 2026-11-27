// Lokal server för webbläsartesterna: node tests/serve.mjs, öppna sedan http://localhost:5173/tests/run.html
// Svarar utan cache, som en ny sida från GitHub Pages. Med ?test=1 körs tests/stub.js före appen,
// så att Supabase, Stadia, GPS och skärmlåset är låtsade och inget går ut på nätet.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.PORT) || 5173;
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.webp': 'image/webp', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };

http.createServer((q, r) => {
  let u = decodeURIComponent(q.url.split('?')[0]);
  if (u.endsWith('/')) u += 'index.html';
  // Ingen service worker här: den kan spara testversionen av appen. sw.js testas i Node.
  if (u === '/sw.js') { r.writeHead(404); return r.end(); }
  const fp = path.join(root, u);
  if (!fp.startsWith(root + path.sep)) { r.writeHead(403); return r.end(); }
  fs.readFile(fp, (e, d) => {
    if (e) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { 'Content-Type': types[path.extname(fp)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    if (u === '/index.html' && q.url.includes('test=1')) d = Buffer.from(String(d).replace('<head>', '<head><script src="/tests/stub.js"></script>'));
    r.end(d);
  });
}).listen(PORT, () => console.log(`Slowlane-tester: http://localhost:${PORT}/tests/run.html`));
