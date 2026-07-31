# Empires Clone — multiplayer RTS server

A browser-playable, Age-of-Empires-style real-time strategy game with an
authoritative Node.js server. Run the server once (on your machine, a home
server, or a cloud box), then everyone — including you — connects with a web
browser and plays together in the same match.

Gameplay: gather wood/food/gold with villagers, build houses/barracks/archery
ranges, train militia and archers, and fight it out on a shared map.

## Requirements

- Node.js 18+

## Run it

```bash
cd aoe-clone
npm install
npm start
```

The server listens on port `3000` by default (override with `PORT=1234 npm start`).

Open `http://localhost:3000` in a browser, pick a name, and click **Join Game**.

## Playing with friends over the internet

Friends connect to whatever address reaches your machine on the server's port:

- **Same LAN / same house**: give them `http://<your-local-ip>:3000`.
- **Over the internet**: either port-forward TCP `3000` on your router to the
  machine running the server and share your public IP, or use a tunnel (e.g.
  `ssh -R` or a service like ngrok/Cloudflare Tunnel) if you don't want to
  touch router settings. Whoever hosts keeps the server process running for
  the whole match — everyone else just opens the URL in a browser and joins.
- **Cloud box**: run `npm start` on any VM with the port open in its
  firewall/security group, then share `http://<vm-ip>:3000`.

Every player who opens the page and clicks Join gets their own Town Center +
3 villagers on the map. Up to 8 players are supported (spawn points are
predefined around the map edges).

## Playing on iOS / over cellular data

The client works in mobile Safari with touch controls (see below), and
because each player's phone just makes an outbound WebSocket connection to
the host, playing over cellular data works the same as playing over wifi —
carrier-side NAT doesn't block outbound connections. A few tips for a
smoother cellular experience:

- **Prefer a tunnel that gives you HTTPS** (e.g. Cloudflare Tunnel, ngrok)
  over raw port-forwarding. Some cellular carriers/captive portals are
  fussier about plain HTTP on non-standard ports, and HTTPS avoids that.
  The client already auto-selects `wss://` when the page is loaded over
  `https://`, so no config changes are needed on your end.
- If you do port-forward instead, forwarding to the standard port `443` (set
  `PORT=443` when starting, may require `sudo`/root on some systems) tends to
  traverse carrier networks more reliably than an arbitrary high port.
- Add the page to the iOS home screen (Share → Add to Home Screen) for a
  full-screen, browser-chrome-free experience.

### Touch controls (iOS / mobile)

- **Tap**: select one of your own units/buildings, or — if you already have
  a selection — issue the context command on whatever you tapped (gather on
  a resource, attack an enemy, move to empty ground). This is the touch
  equivalent of desktop right-click.
- **Drag**: box-select multiple of your own units.
- **Pinch**: zoom in/out. **Two-finger drag**: pan the camera.
- **Build buttons**: pick a building, then tap the map to place it (a
  **Cancel** button appears while placing).
- **Deselect / Stop buttons**: appear whenever you have a selection.

## Desktop controls

- **Left-click**: select a unit or building.
- **Left-drag**: box-select multiple of your own units.
- **Right-click**: context action for the current selection —
  - on a resource node → gather (villagers only)
  - on an enemy unit/building → attack (military units only)
  - on empty ground → move (or set a rally point if a building is selected)
- **Build buttons** (appear when villagers are selected): pick a building,
  then click the map to place it — selected villagers walk over and
  construct it.
- **Train buttons** (appear when your own building is selected): queue units.
- **Arrow keys / WASD**: pan the camera. **Esc**: cancel building placement.

## Architecture

- `server/config.js` — map size, unit/building stats, costs, tuning knobs.
- `server/game.js` — authoritative simulation: movement, gathering,
  construction, training queues, combat, population cap, win/elimination
  tracking. Runs entirely server-side; clients cannot cheat by forging state.
- `server/index.js` — HTTP static file server (serves `public/`) + WebSocket
  server. Broadcasts the full game state to all connected clients 10 times
  per second.
- `public/` — the browser client: plain HTML5 canvas rendering, mouse/keyboard
  input, and a WebSocket connection to the server. No build step required.

## Known limitations (MVP scope)

- No pathfinding around obstacles — units move in straight lines.
- No fog of war — the whole map is visible to everyone.
- No auto-retaliation — units only fight when explicitly ordered to attack.
- Disconnecting removes your units/buildings from the match (no reconnect/resume).

These are reasonable follow-ups if you want to keep building on this.
