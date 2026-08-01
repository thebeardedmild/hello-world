const net = require('net');
const http = require('http');
const { buildAll } = require('./nmea');

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => {
      if (!data) { resolve({}); return; }
      try { resolve(JSON.parse(data)); } catch (err) { reject(err); }
    });
    req.on('error', reject);
  });
}

function sendJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) });
  res.end(text);
}

/**
 * Starts the two servers a real GPS receiver + configuration tool would
 * expose between them:
 *   - TCP: streams NMEA sentences to every connected client at rateHz
 *     (the standard way NMEA is delivered over a network — many GPS tools,
 *     gpsd, chart plotters, etc. can consume "network NMEA" directly).
 *   - HTTP: a small JSON control API for scripting the simulator live.
 */
function startServers(sim, { tcpPort = 10110, httpPort = 8880, rateHz = 1 } = {}) {
  const clients = new Set();

  const tcpServer = net.createServer((socket) => {
    clients.add(socket);
    socket.on('close', () => clients.delete(socket));
    socket.on('error', () => clients.delete(socket));
  });
  tcpServer.listen(tcpPort);

  let lastTick = Date.now();
  const tickTimer = setInterval(() => {
    const now = Date.now();
    const dt = (now - lastTick) / 1000;
    lastTick = now;
    sim.tick(dt);
    const payload = buildAll(sim.getFix()).join('');
    for (const socket of clients) {
      if (!socket.destroyed) socket.write(payload);
    }
  }, 1000 / rateHz);

  const httpServer = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (req.method === 'GET' && url.pathname === '/state') {
        sendJson(res, 200, { fix: sim.getFix(), status: sim.getStatus(), clients: clients.size });
        return;
      }
      if (req.method === 'POST' && url.pathname === '/position') {
        const body = await readJsonBody(req);
        if (!Number.isFinite(body.lat) || !Number.isFinite(body.lng)) return sendJson(res, 400, { error: 'lat and lng are required numbers' });
        sim.setPosition(body.lat, body.lng, body.altitude);
        return sendJson(res, 200, { ok: true, status: sim.getStatus() });
      }
      if (req.method === 'POST' && url.pathname === '/route') {
        const body = await readJsonBody(req);
        if (!Array.isArray(body.waypoints) || body.waypoints.length === 0) return sendJson(res, 400, { error: 'waypoints (non-empty array of {lat,lng}) is required' });
        sim.setRoute(body.waypoints, body.speedMps ?? 1.4, !!body.loop);
        return sendJson(res, 200, { ok: true, status: sim.getStatus() });
      }
      if (req.method === 'POST' && url.pathname === '/walk') {
        const body = await readJsonBody(req);
        if (!Number.isFinite(body.centerLat) || !Number.isFinite(body.centerLng) || !Number.isFinite(body.radiusM)) {
          return sendJson(res, 400, { error: 'centerLat, centerLng, and radiusM are required numbers' });
        }
        sim.startWalk(body.centerLat, body.centerLng, body.radiusM, body.speedMps ?? 1.4);
        return sendJson(res, 200, { ok: true, status: sim.getStatus() });
      }
      if (req.method === 'POST' && url.pathname === '/stop') {
        sim.stop();
        return sendJson(res, 200, { ok: true, status: sim.getStatus() });
      }
      if (req.method === 'POST' && url.pathname === '/jitter') {
        const body = await readJsonBody(req);
        if (!Number.isFinite(body.meters)) return sendJson(res, 400, { error: 'meters is a required number' });
        sim.setJitter(body.meters);
        return sendJson(res, 200, { ok: true, status: sim.getStatus() });
      }
      sendJson(res, 404, { error: 'not found', routes: ['GET /state', 'POST /position', 'POST /route', 'POST /walk', 'POST /stop', 'POST /jitter'] });
    } catch (err) {
      sendJson(res, 400, { error: err.message });
    }
  });
  httpServer.listen(httpPort);

  function close() {
    clearInterval(tickTimer);
    for (const socket of clients) socket.destroy();
    tcpServer.close();
    httpServer.close();
  }

  return { tcpServer, httpServer, close };
}

module.exports = { startServers };
