# Empires Clone — real-world multiplayer RTS

A browser-playable, Age-of-Empires-style real-time strategy game that's
mapped onto the real world, Pokémon-GO style: whoever starts the match sets
the play area at their real GPS location, and every friend who joins spawns
their base wherever *they're* physically standing. Everyone sees a live
OpenStreetMap view of the match and taps it to command their villagers and
army. There's also a native iOS AR companion scaffold that overlays the same
live match on your camera view (see `ios-ar/`).

Because bases spawn at players' real locations and unit movement/ranges are
tuned to real meters, **this only really works if everyone is physically
together** — a park, a campus, a backyard. It's not a remote-play game.

## Requirements

- Node.js 18+

## Run it

```bash
cd aoe-clone
npm install
npm start
```

The server listens on port `3000` by default (override with `PORT=1234 npm start`).

Open `http://localhost:3000` on a phone (or desktop, for testing), pick a
name, allow location access, and click **Join Game**. The first player to
join sets the match's origin point and the shared play area (a ~200m radius
around them, shown as a dashed circle on the map); everyone after that
spawns their own base at their own location. Up to 8 players are supported.

If location access fails or you're testing without GPS (e.g. indoors, or
from a machine with no location hardware), the join screen offers a **demo
location** fallback so you can still try the game out.

## Hosting for a group (the important part: HTTPS)

Browsers only expose the Geolocation API on **secure origins** — `https://`
or `localhost`. A plain `http://192.168.x.x:3000` link works for *you* (via
localhost) but will generally **fail to get a location on everyone else's
phones**, even on the same wifi. So for more than one person, you need
HTTPS, not just a reachable address.

The easiest way:

```bash
npm run host
```

This starts the server and, if you have
[`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
installed (`brew install cloudflared` on macOS, `winget install --id
Cloudflare.cloudflared` on Windows), automatically opens a free HTTPS
tunnel and prints a shareable link plus a QR code you can hold up for
everyone to scan — no typing a URL into 6 phones. If `cloudflared` isn't
found, `npm run host` still starts the server and prints the manual
install/usage instructions instead.

Keep the terminal running for the whole game — closing it drops everyone
(there's no reconnect yet, see Known limitations).

### Other ways to get HTTPS

- **ngrok** or another tunnel: `ngrok http 3000`, then share the `https://`
  URL it prints — works the same way as `cloudflared`, use whichever you
  already have.
- **Cloud VM**: run the server on a VM with a real domain + TLS (or a
  tunnel from the VM), then share `https://<your-domain>`.
- Add the page to your iOS home screen (Share → Add to Home Screen) for a
  full-screen, browser-chrome-free experience once everyone's joined.

Playing over cellular works the same as wifi once you have an HTTPS link —
each phone just makes an outbound connection, so carrier-side NAT doesn't
get in the way.

## Controls

- **Tap** a unit/building you own to select it. **Tap** anywhere else while
  you have a selection to issue the context-appropriate command: gather on a
  resource node, attack an enemy, move to open ground (or set a rally point
  if a building is selected).
- **Drag the map**: pan. **Pinch**: zoom. (Leaflet handles both natively.)
- **Select button**: toggles box-select mode — drag a rectangle over your
  own units to multi-select (this temporarily disables map panning so the
  drag doesn't conflict with it).
- **Build buttons** (appear when villagers are selected): pick a building,
  then tap the map to place it.
- **Train buttons** (appear when your own building is selected): queue
  units. **Stop** / **Deselect** buttons appear whenever you have a
  selection.

## Architecture

- `server/config.js` — unit/building stats, costs, and the meter-scale
  tuning knobs (ranges/speeds enlarged well past tile-game scale to stay
  usable despite consumer GPS accuracy of ~5-15m).
- `server/latlng.js` — flat tangent-plane conversion between GPS coordinates
  and local meters, centered on the match origin.
- `server/game.js` — authoritative simulation: movement, gathering,
  construction, training queues, combat, population cap, elimination
  tracking. Runs entirely in local meters internally; lat/lng only exist at
  the network boundary (player join, move/build/rally command targets,
  state serialization). The origin is set by the first player to join, and a
  small resource cluster is seeded near every player's spawn point.
- `server/index.js` — HTTP static file server (serves `public/`, plus
  Leaflet's own assets under `/vendor/leaflet/` so the client has no CDN
  dependency) + WebSocket server. Broadcasts full game state 10 times/sec.
- `public/` — browser client: a live [Leaflet](https://leafletjs.com) map
  over OpenStreetMap tiles, geolocation-based join flow, and a WebSocket
  connection to the server. No build step required.
- `scripts/host.js` (`npm run host`) — starts the server and, if
  `cloudflared` is installed, an HTTPS tunnel with the shareable link
  printed as text and a QR code.
- `ios-ar/` — native iOS AR companion app **scaffold** (Swift/SwiftUI/
  ARKit/RealityKit source + Xcode setup instructions). Speaks the same
  WebSocket protocol as `public/client.js`. See `ios-ar/README-ios-ar.md`
  for what it does, its limitations, and setup steps — this environment
  can't compile or run Swift, so treat it as an unverified first draft to
  finish in Xcode.

## Known limitations (MVP scope)

- No pathfinding around obstacles (real or simulated) — units move in
  straight lines.
- No fog of war — the whole map is visible to everyone.
- No auto-retaliation — units only fight when explicitly ordered to attack.
- Disconnecting removes your units/buildings from the match (no
  reconnect/resume).
- A joining player far from the match origin (>1.5km) gets a warning banner
  but can still join — their base will just be out of practical reach.
- AR placement in the iOS companion is GPS+compass-approximate, not a true
  shared/persistent AR world — see `ios-ar/README-ios-ar.md`.

These are reasonable follow-ups if you want to keep building on this.
