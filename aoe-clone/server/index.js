const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const { Game } = require('./game');
const { TICK_MS } = require('./config');

const PORT = process.env.PORT || 3000;
const PUBLIC_DIR = path.join(__dirname, '..', 'public');

const MIME = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.css': 'text/css',
};

const server = http.createServer((req, res) => {
  const urlPath = req.url.split('?')[0];
  const relPath = urlPath === '/' ? '/index.html' : urlPath;
  const fullPath = path.normalize(path.join(PUBLIC_DIR, relPath));
  if (!fullPath.startsWith(PUBLIC_DIR)) {
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
      playerId = game.addPlayer(msg.name, ws);
      ws.send(JSON.stringify({ type: 'welcome', playerId, ...game.getStaticInfo() }));
      console.log(`Player joined: id=${playerId} name=${msg.name}`);
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
  console.log(`Age of Empires clone server listening on http://localhost:${PORT}`);
  console.log('Share your IP/port (or a tunnel URL) with friends so they can connect.');
});
