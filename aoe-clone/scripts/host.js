#!/usr/bin/env node
// Convenience launcher for game nights: starts the server, and if the
// `cloudflared` binary is on PATH, opens a free HTTPS tunnel and prints the
// shareable link as both text and a scannable QR code. HTTPS matters here,
// not just for reliability: browsers only expose the Geolocation API on
// secure origins (https) or localhost, so a plain http://<lan-ip> link will
// generally fail to get a location on your friends' phones.
const { spawn, spawnSync } = require('child_process');
const path = require('path');
const qrcode = require('qrcode-terminal');

const PORT = process.env.PORT || 3000;
const TUNNEL_URL_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;

function hasCloudflared() {
  const check = spawnSync('cloudflared', ['--version'], { stdio: 'ignore' });
  return !check.error;
}

console.log(`Starting Empires Clone server on port ${PORT}...\n`);
const server = spawn(process.execPath, [path.join(__dirname, '..', 'server', 'index.js')], {
  env: { ...process.env, PORT },
  stdio: 'inherit',
});

let tunnel = null;

if (hasCloudflared()) {
  console.log('cloudflared found — opening a free HTTPS tunnel so location works on everyone\'s phones...\n');
  tunnel = spawn('cloudflared', ['tunnel', '--url', `http://localhost:${PORT}`]);
  let printed = false;
  const onData = (buf) => {
    const text = buf.toString();
    const match = text.match(TUNNEL_URL_RE);
    if (match && !printed) {
      printed = true;
      const url = match[0];
      console.log('\n' + '='.repeat(60));
      console.log('Share this link (and/or QR code) with your friends:');
      console.log('  ' + url);
      console.log('='.repeat(60) + '\n');
      qrcode.generate(url, { small: true });
      console.log('\nEveryone should open that link, allow location access, and Join.');
      console.log('Keep this terminal open for the whole game — closing it ends the tunnel.\n');
    }
  };
  tunnel.stdout.on('data', onData);
  tunnel.stderr.on('data', onData); // cloudflared logs to stderr by default
} else {
  console.log([
    'cloudflared was not found on your PATH, so no automatic HTTPS tunnel was started.',
    'Location access will likely fail on your friends\' phones over a plain http:// link',
    '(browsers restrict Geolocation to HTTPS or localhost).',
    '',
    'To fix this, install cloudflared and re-run `npm run host`:',
    '  macOS:    brew install cloudflared',
    '  Windows:  winget install --id Cloudflare.cloudflared',
    '  Linux:    see https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/',
    '',
    'Or start a tunnel yourself in another terminal, e.g.:',
    `  cloudflared tunnel --url http://localhost:${PORT}`,
    '  (or `ngrok http ' + PORT + '` if you already use ngrok)',
    'and share the https:// URL it prints.',
  ].join('\n') + '\n');
}

function shutdown() {
  server.kill();
  if (tunnel) tunnel.kill();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
