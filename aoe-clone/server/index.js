const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const { Game } = require('./game');
const { TICK_MS, FAR_JOIN_WARNING_M } = require('./config');

const PORT = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const LEAFLET_DIR = path.join(__dirname, '..', 'node_modules', 'leaflet', 'dist');

const MIME = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function serveFile(res, fullPath, baseDir) {
  if (!fullPath.startsWith(baseDir)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }
  fs.readFile(fullPath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    const ext = path.extname(fullPath);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  const urlPath = req.url.split('?')[0];
  // Self-host Leaflet's dist files instead of depending on a CDN — the map
  // still needs internet access to fetch live OpenStreetMap tiles, but the
  // library itself works even if unpkg/jsdelivr are unreachable.
  if (urlPath.startsWith('/vendor/leaflet/')) {
    const rel = urlPath.slice('/vendor/leaflet/'.length);
    serveFile(res, path.normalize(path.join(LEAFLET_DIR, rel)), LEAFLET_DIR);
    return;
  }
  const relPath = urlPath === '/' ? '/index.html' : urlPath;
  serveFile(res, path.normalize(path.join(PUBLIC_DIR, relPath)), PUBLIC_DIR);
});

const wss = new WebSocket.Server({ server });
const game = new Game();

wss.on('connection', (ws) => {
  let playerId = null;

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    if (msg.type === 'join' && playerId === null) {
      const result = game.addPlayer(msg.name, msg.lat, msg.lng, ws);
      if (!result) {
        ws.send(JSON.stringify({ type: 'error', message: 'A valid location (lat/lng) is required to join.' }));
        return;
      }
      playerId = result.playerId;
      ws.send(JSON.stringify({
        type: 'welcome',
        playerId,
        originLat: game.origin.lat,
        originLng: game.origin.lng,
        distanceFromOriginM: result.distanceFromOriginM,
        farFromOrigin: result.distanceFromOriginM > FAR_JOIN_WARNING_M,
        ...game.getStaticInfo(),
      }));
      console.log(`Player joined: id=${playerId} name=${msg.name} distanceFromOriginM=${result.distanceFromOriginM}`);
    } else if (msg.type === 'command' && playerId !== null) {
      game.handleCommand(playerId, msg.cmd);
    }
  });

  ws.on('close', () => {
    if (playerId !== null) {
      console.log(`Player left: id=${playerId}`);
      game.removePlayer(playerId);
    }
  });

  ws.on('error', () => {});
});

setInterval(() => {
  game.update(TICK_MS / 1000);
  const payload = JSON.stringify({ type: 'state', ...game.getState() });
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) client.send(payload);
  }
}, TICK_MS);

server.listen(PORT, () => {
  console.log(`Empires Clone (real-world mode) listening on http://localhost:${PORT}`);
  console.log('Share your IP/port (or a tunnel URL) with friends so they can connect from nearby.');
});
