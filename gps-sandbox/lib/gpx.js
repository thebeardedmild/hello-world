function escapeXml(s) {
  return String(s).replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]));
}

// Minimal GPX 1.1 route export — useful for feeding a waypoint route into
// tools that accept GPX directly (e.g. Xcode Simulator's location simulation).
function routeToGpx(waypoints, name = 'GPS Sandbox Route') {
  const points = waypoints.map((w) => `    <rtept lat="${w.lat}" lon="${w.lng}"></rtept>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="gps-sandbox" xmlns="http://www.topografix.com/GPX/1/1">\n  <rte>\n    <name>${escapeXml(name)}</name>\n${points}\n  </rte>\n</gpx>\n`;
}

module.exports = { routeToGpx };
