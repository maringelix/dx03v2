import { createServer } from 'node:http';

const port = Number(process.env.ZAP_FIXTURE_PORT ?? 18081);
if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new Error(`invalid ZAP fixture port: ${port}`);
}

const server = createServer((request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(204, { 'Cache-Control': 'no-store' });
    response.end();
    return;
  }

  response.writeHead(200, {
    'Cache-Control': 'no-store',
    'Content-Type': 'text/html; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cross-Origin-Resource-Policy': 'same-origin',
  });
  response.end(
    '<!doctype html><html><head><title>ZAP negative fixture</title></head>' +
      '<body><h1>Deliberately missing Content-Security-Policy</h1></body></html>',
  );
});

server.listen(port, '127.0.0.1');
