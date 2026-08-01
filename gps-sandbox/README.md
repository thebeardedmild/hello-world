# gps-sandbox

A standalone GPS/NMEA simulator. No dependency on anything else in this
repo — reusable for testing any location-based app or tool, not just the
game next door.

It broadcasts standard **NMEA 0183** sentences over TCP the way a real GPS
receiver (or a serial-to-network bridge, or `gpsd`) would, and exposes a
small HTTP control API so you can script movement live: sit still, follow a
waypoint route, or wander randomly within a radius — with realistic GPS
jitter layered on top of whatever the "true" simulated position is.

## Requirements

Node.js 18+. Zero npm dependencies.

## Run it

```bash
cd gps-sandbox
node bin/gps-sandbox.js
```

By default it sits stationary at `37.7699, -122.4670` (San Francisco),
broadcasting NMEA at 1Hz on `tcp://localhost:10110` with a control API on
`http://localhost:8880`.

```bash
# Watch the raw sentence stream:
nc localhost 10110

# Check the current fix + simulator status as JSON:
curl http://localhost:8880/state
```

### Moving it around

**Follow a waypoint route** (JSON array of `{"lat":..,"lng":..}`, see
`examples/park-loop.json`):

```bash
node bin/gps-sandbox.js --route examples/park-loop.json --loop --speed 1.4
```

**Wander randomly within a radius** (like a person walking around a park —
useful for exercising an app under continuous, unpredictable movement):

```bash
node bin/gps-sandbox.js --lat 37.7699 --lng -122.4670 --walk-radius 60 --speed 1.2
```

**Export a route as GPX** instead of running the simulator (e.g. to drop
into Xcode Simulator's location simulation):

```bash
node bin/gps-sandbox.js --route examples/park-loop.json --gpx park-loop.gpx
```

### CLI flags

| Flag | Default | Meaning |
|---|---|---|
| `--lat`, `--lng` | `37.7699`, `-122.4670` | Starting position |
| `--alt` | `10` | Altitude in meters |
| `--jitter` | `5` | GPS noise radius in meters, applied per report |
| `--tcp-port` | `10110` | NMEA broadcast port |
| `--http-port` | `8880` | Control API port |
| `--rate` | `1` | NMEA update rate in Hz |
| `--route <file>` | — | JSON waypoint file to follow |
| `--loop` | off | Loop the route instead of stopping at the end |
| `--walk-radius <m>` | — | Random-walk radius around `--lat/--lng` |
| `--speed <m/s>` | `1.4` | Movement speed for route/walk modes (1.4 ≈ walking pace) |
| `--gpx <out.gpx>` | — | Export `--route` as GPX and exit (no server) |

## Live control (HTTP API)

Change what the simulator is doing while it's already running and clients
are connected — no restart needed:

```bash
# Jump to an exact position
curl -X POST http://localhost:8880/position -d '{"lat":37.7690,"lng":-122.4670}'

# Follow a route
curl -X POST http://localhost:8880/route -d '{"waypoints":[{"lat":37.769,"lng":-122.467},{"lat":37.770,"lng":-122.468}],"speedMps":1.4,"loop":true}'

# Wander within a radius
curl -X POST http://localhost:8880/walk -d '{"centerLat":37.769,"centerLng":-122.467,"radiusM":50,"speedMps":1.2}'

# Freeze in place
curl -X POST http://localhost:8880/stop

# Adjust GPS noise
curl -X POST http://localhost:8880/jitter -d '{"meters":15}'

# Current fix + status
curl http://localhost:8880/state
```

(All POST bodies are JSON — add `-H 'Content-Type: application/json'` if
your `curl` doesn't infer it.)

## NMEA sentences

Broadcasts the standard set most GPS parsers expect, once per tick:
**GGA** (fix data), **RMC** (position/speed/course), **VTG** (course and
speed over ground), **GSA** (DOP and active satellites), **GLL**
(lat/lng + time), **GSV** (satellites in view). Checksums are computed
correctly per spec — verified in testing by independently recomputing and
comparing against every sentence's `*XX` suffix, not just trusting the
generator.

Satellite PRNs/DOP values are plausible placeholders, not a real almanac —
this is a movement/position simulator, not a satellite-geometry simulator.

## Architecture

- `lib/geo.js` — flat-earth lat/lng ⇄ local-meters conversion, distance/
  bearing, and "move toward a point" helpers.
- `lib/nmea.js` — sentence builders + checksum, pure functions of a `fix`
  object.
- `lib/simulator.js` — `GpsSimulator`: stationary/route/walk movement
  modes, jitter.
- `lib/server.js` — TCP NMEA broadcaster (multi-client) + HTTP control API.
- `bin/gps-sandbox.js` — CLI wiring the above together, plus the GPX export
  mode.

## Known limitations

- Jitter is a simple random offset per report, not a realistic GPS error
  model (real GPS error is correlated over time, not independent noise
  each sample) — fine for testing tolerance to inaccurate positioning, not
  for anything wanting statistically realistic GPS error.
- No support for multiple simulated satellites' worth of real ephemeris
  data, DGPS/RTK correction simulation, or altitude-specific error models.
- The TCP server broadcasts identically to every connected client — no
  per-client scripting.
