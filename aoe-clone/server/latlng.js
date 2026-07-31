// Flat tangent-plane conversion between GPS coordinates and local meters,
// centered on a match's origin point. Accurate enough for play areas up to
// a few kilometers across (equirectangular approximation).

const M_PER_DEG_LAT = 110574;

function metersPerDegLng(originLat) {
  return 111320 * Math.cos((originLat * Math.PI) / 180);
}

function toLocal(lat, lng, origin) {
  return {
    x: (lng - origin.lng) * metersPerDegLng(origin.lat),
    y: (lat - origin.lat) * M_PER_DEG_LAT,
  };
}

function toLatLng(x, y, origin) {
  return {
    lat: origin.lat + y / M_PER_DEG_LAT,
    lng: origin.lng + x / metersPerDegLng(origin.lat),
  };
}

module.exports = { toLocal, toLatLng };
