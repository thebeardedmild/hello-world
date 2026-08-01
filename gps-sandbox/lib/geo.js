// Flat tangent-plane conversion between GPS coordinates and local meters,
// centered on an arbitrary origin point. Accurate enough for the scale this
// simulator operates at (routes/walks up to a few km across).

const M_PER_DEG_LAT = 110574;

function metersPerDegLng(lat) {
  return 111320 * Math.cos((lat * Math.PI) / 180);
}

function toLocal(origin, point) {
  return {
    x: (point.lng - origin.lng) * metersPerDegLng(origin.lat),
    y: (point.lat - origin.lat) * M_PER_DEG_LAT,
  };
}

function toLatLng(origin, x, y) {
  return {
    lat: origin.lat + y / M_PER_DEG_LAT,
    lng: origin.lng + x / metersPerDegLng(origin.lat),
  };
}

function distanceMeters(a, b) {
  const local = toLocal(a, b);
  return Math.hypot(local.x, local.y);
}

// Bearing in degrees (0 = north, clockwise) from a to b.
function bearingDegrees(a, b) {
  const local = toLocal(a, b);
  const deg = (Math.atan2(local.x, local.y) * 180) / Math.PI;
  return (deg + 360) % 360;
}

// Moves `from` toward `to` by up to stepMeters. Returns the new point, whether
// the target was reached this step, and (if reached) the leftover distance
// that wasn't needed to arrive — used to carry movement into the next leg of
// a route within a single tick.
function moveToward(from, to, stepMeters) {
  const dist = distanceMeters(from, to);
  if (dist <= stepMeters || dist < 1e-6) {
    return { point: { lat: to.lat, lng: to.lng }, arrived: true, remaining: stepMeters - dist };
  }
  const local = toLocal(from, to);
  const scale = stepMeters / dist;
  const point = toLatLng(from, local.x * scale, local.y * scale);
  return { point, arrived: false, remaining: 0 };
}

// Random point uniformly within radiusM of center (simple, not area-uniform
// near the center, which is fine for a walk-around simulator).
function randomPointNear(center, radiusM) {
  const angle = Math.random() * Math.PI * 2;
  const r = Math.random() * radiusM;
  const x = r * Math.sin(angle);
  const y = r * Math.cos(angle);
  return toLatLng(center, x, y);
}

module.exports = { toLocal, toLatLng, distanceMeters, bearingDegrees, moveToward, randomPointNear };
