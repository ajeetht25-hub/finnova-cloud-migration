'use strict';

const http = require('node:http');
const { loadDbConfig } = require('./config');

const PORT = Number(process.env.PORT || 8080);
let ready = false;
let dbConfig = null;

// Re-read the mounted secret on demand so rotated credentials are picked up
// without a restart (CSI driver refreshes the file on rotation).
function refreshConfig() {
  try {
    dbConfig = loadDbConfig();
    ready = true;
  } catch (err) {
    ready = false;
    console.error(JSON.stringify({ level: 'error', msg: err.message }));
  }
}

function handler(req, res) {
  if (req.url === '/healthz') {
    // Liveness: process is up and event loop responsive.
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end('{"status":"alive"}');
  }
  if (req.url === '/readyz') {
    // Readiness: credentials are loaded (and, in the full app, DB pool is healthy).
    res.writeHead(ready ? 200 : 503, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ status: ready ? 'ready' : 'not-ready' }));
  }
  if (req.url.startsWith('/api/v1/inventory')) {
    // Placeholder for the real inventory API.
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ items: [], note: 'PoC skeleton' }));
  }
  res.writeHead(404);
  return res.end();
}

function start() {
  refreshConfig();
  setInterval(refreshConfig, 60_000).unref();

  const server = http.createServer(handler);
  server.listen(PORT, () => console.log(JSON.stringify({ level: 'info', msg: `listening on ${PORT}` })));

  // Graceful shutdown: stop accepting new connections, let in-flight finish.
  const shutdown = () => {
    ready = false;
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 25_000).unref();
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
  return server;
}

if (require.main === module) {
  start();
}

module.exports = { handler, start };
