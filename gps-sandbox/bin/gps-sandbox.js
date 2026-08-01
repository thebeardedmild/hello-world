#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { GpsSimulator } = require('../lib/simulator');
const { startServers } = require('../lib/server');
const { routeToGpx } = require('../lib/gpx');

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith('--')) {
      args[key] = next;
      i++;
    } else {
      args[key] = true;
    }
  }
  return args;
}

function usage() {
  console.log(`gps-sandbox — standalone GPS/NMEA simulator

Usage:
  gps-sandbox [--lat 37.7699] [--lng -122.4670] [--alt 10] [--jitter 5]
              [--tcp-port 10110] [--http-port 8880] [--rate 1]
              [--route <file.json> [--loop]] [--walk-radius <meters>]
              [--speed <m/s>]

  gps-sandbox --route <file.json> --gpx <out.gpx>
      Export a waypoint route (JSON array of {"lat":..,"lng":..}) as a
      .gpx file instead of running the simulator.

Examples:
  gps-sandbox --lat 37.7699 --lng -122.4670
  gps-sandbox --route examples/park-loop.json --loop --speed 1.4
  gps-sandbox --lat 37.7699 --lng -122.4670 --walk-radius 60 --speed 1.2
  gps-sandbox --route examples/park-loop.json --gpx park-loop.gpx
`);
}

const args = parseArgs(process.argv.slice(2));

if (args.help || args.h) {
  usage();
  process.exit(0);
}

if (args.gpx) {
  if (!args.route) {
    console.error('--gpx requires --route <file.json>');
    process.exit(1);
  }
  const waypoints = JSON.parse(fs.readFileSync(args.route, 'utf8'));
  fs.writeFileSync(args.gpx, routeToGpx(waypoints, path.basename(args.route)));
  console.log(`Wrote GPX route (${waypoints.length} waypoints) to ${args.gpx}`);
  process.exit(0);
}

const lat = parseFloat(args.lat ?? '37.7699');
const lng = parseFloat(args.lng ?? args.lon ?? '-122.4670');
const altitude = parseFloat(args.alt ?? '10');
const jitterM = parseFloat(args.jitter ?? '5');
const tcpPort = parseInt(args['tcp-port'] ?? '10110', 10);
const httpPort = parseInt(args['http-port'] ?? '8880', 10);
const rateHz = parseFloat(args.rate ?? '1');
const speedMps = parseFloat(args.speed ?? '1.4');

const sim = new GpsSimulator({ lat, lng, altitude, jitterM });

if (args.route) {
  const waypoints = JSON.parse(fs.readFileSync(args.route, 'utf8'));
  sim.setRoute(waypoints, speedMps, !!args.loop);
  console.log(`Following route from ${args.route} (${waypoints.length} waypoints) at ${speedMps} m/s${args.loop ? ', looping' : ''}`);
} else if (args['walk-radius']) {
  const radiusM = parseFloat(args['walk-radius']);
  sim.startWalk(lat, lng, radiusM, speedMps);
  console.log(`Random-walking within ${radiusM}m of ${lat},${lng} at ${speedMps} m/s`);
} else {
  console.log(`Stationary at ${lat},${lng} (use --route or --walk-radius to move)`);
}

const servers = startServers(sim, { tcpPort, httpPort, rateHz });

console.log(`\nNMEA broadcasting on tcp://localhost:${tcpPort} at ${rateHz}Hz (jitter: ${jitterM}m)`);
console.log(`Control API on http://localhost:${httpPort}`);
console.log(`\nTry:`);
console.log(`  nc localhost ${tcpPort}                          # watch raw NMEA sentences`);
console.log(`  curl http://localhost:${httpPort}/state           # current fix + status as JSON`);
console.log(`  curl -X POST http://localhost:${httpPort}/stop    # freeze in place`);

process.on('SIGINT', () => { servers.close(); process.exit(0); });
process.on('SIGTERM', () => { servers.close(); process.exit(0); });
