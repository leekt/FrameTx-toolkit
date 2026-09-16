// Serve only the static export. No source files, dotfiles, private keys, or open proxy.
import { createServer } from 'node:http';
import { readFile, realpath, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { extname, resolve, sep } from 'node:path';
const root = fileURLToPath(new URL('../dist/client/', import.meta.url));
const port = Number(process.env.PORT || 4181);
if (!Number.isInteger(port) || port < 1 || port > 65535)
  throw new Error('Invalid PORT');
const hosts = new Set([
  `127.0.0.1:${port}`,
  `localhost:${port}`,
  `${process.env.VFRAME_ALLOWED_HOST || 'leekt-macmini.tail45c85e.ts.net'}:${port}`,
]);
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.rsc': 'text/x-component',
  '.txt': 'text/plain; charset=utf-8',
};
await stat(resolve(root, 'index.html')).catch(() => {
  throw new Error('Run npm run build first.');
});
const realRoot = await realpath(root);
createServer(async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  if (!hosts.has((req.headers.host || '').toLowerCase())) {
    res.writeHead(403).end('Unrecognized host');
    return;
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' }).end();
    return;
  }
  try {
    const path = decodeURIComponent(
      new URL(req.url || '/', 'http://localhost').pathname,
    );
    if (
      path.split('/').some((part) => part.startsWith('.')) ||
      /\.(pem|key)$/i.test(path)
    ) {
      res.writeHead(403).end();
      return;
    }
    const file = resolve(
      root,
      `.${path.endsWith('/') ? path + 'index.html' : path}`,
    );
    if (
      !file.startsWith(realRoot + sep) ||
      !(await realpath(file)).startsWith(realRoot + sep)
    ) {
      res.writeHead(403).end();
      return;
    }
    const data = await readFile(file);
    res.writeHead(200, {
      'Content-Type': types[extname(file)] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
    });
    res.end(req.method === 'HEAD' ? undefined : data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
  }
}).listen(port, '127.0.0.1', () =>
  console.log(
    `vFrame: http://127.0.0.1:${port}/ (loopback; expose only through Tailscale)`,
  ),
);
