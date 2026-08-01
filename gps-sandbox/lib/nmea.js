// Builders for standard NMEA 0183 sentences. Field layouts follow the
// commonly-implemented subset most GPS parsers (gpsd, GPS Test apps, chart
// plotters, etc.) expect. All builders take a "fix" object:
//   { lat, lng, altitude, speedMps, headingDeg, time, satellites, hdop, fixQuality }
// fixQuality: 0 = no fix, 1 = GPS fix, 2 = DGPS fix (mirrors real receivers).

function pad(n, width) {
  return String(n).padStart(width, '0');
}

function toNmeaLat(lat) {
  const hemi = lat >= 0 ? 'N' : 'S';
  const abs = Math.abs(lat);
  const deg = Math.floor(abs);
  const min = (abs - deg) * 60;
  return { value: pad(deg, 2) + min.toFixed(5).padStart(8, '0'), hemi };
}

function toNmeaLng(lng) {
  const hemi = lng >= 0 ? 'E' : 'W';
  const abs = Math.abs(lng);
  const deg = Math.floor(abs);
  const min = (abs - deg) * 60;
  return { value: pad(deg, 3) + min.toFixed(5).padStart(8, '0'), hemi };
}

function nmeaTime(date) {
  const cs = pad(Math.floor(date.getUTCMilliseconds() / 10), 2);
  return `${pad(date.getUTCHours(), 2)}${pad(date.getUTCMinutes(), 2)}${pad(date.getUTCSeconds(), 2)}.${cs}`;
}

function nmeaDate(date) {
  return `${pad(date.getUTCDate(), 2)}${pad(date.getUTCMonth() + 1, 2)}${pad(date.getUTCFullYear() % 100, 2)}`;
}

function checksum(body) {
  let cs = 0;
  for (let i = 0; i < body.length; i++) cs ^= body.charCodeAt(i);
  return cs.toString(16).toUpperCase().padStart(2, '0');
}

function frame(body) {
  return `$${body}*${checksum(body)}\r\n`;
}

function buildGGA(fix) {
  const { value: latVal, hemi: latHemi } = toNmeaLat(fix.lat);
  const { value: lngVal, hemi: lngHemi } = toNmeaLng(fix.lng);
  const fixQuality = fix.fixQuality ?? 1;
  const numSat = pad(fix.satellites ?? 8, 2);
  const hdop = (fix.hdop ?? 1.2).toFixed(1);
  const alt = (fix.altitude ?? 10).toFixed(1);
  return frame(
    `GPGGA,${nmeaTime(fix.time)},${latVal},${latHemi},${lngVal},${lngHemi},${fixQuality},${numSat},${hdop},${alt},M,0.0,M,,`,
  );
}

function buildRMC(fix) {
  const { value: latVal, hemi: latHemi } = toNmeaLat(fix.lat);
  const { value: lngVal, hemi: lngHemi } = toNmeaLng(fix.lng);
  const status = (fix.fixQuality ?? 1) > 0 ? 'A' : 'V';
  const speedKnots = (fix.speedMps * 1.94384).toFixed(1);
  const course = (fix.headingDeg ?? 0).toFixed(1);
  return frame(
    `GPRMC,${nmeaTime(fix.time)},${status},${latVal},${latHemi},${lngVal},${lngHemi},${speedKnots},${course},${nmeaDate(fix.time)},,,A`,
  );
}

function buildVTG(fix) {
  const course = (fix.headingDeg ?? 0).toFixed(1);
  const speedKnots = (fix.speedMps * 1.94384).toFixed(1);
  const speedKmh = (fix.speedMps * 3.6).toFixed(1);
  return frame(`GPVTG,${course},T,,M,${speedKnots},N,${speedKmh},K,A`);
}

function buildGSA(fix) {
  const hdop = (fix.hdop ?? 1.2).toFixed(1);
  const pdop = (fix.hdop * 1.4 || 1.7).toFixed(1);
  const vdop = (fix.hdop * 1.0 || 1.2).toFixed(1);
  const fixType = (fix.fixQuality ?? 1) > 0 ? 3 : 1; // 1 = no fix, 3 = 3D fix
  // Fixed, plausible set of satellite PRNs — this is a simulator, not a
  // real almanac, so these are illustrative rather than geographically real.
  return frame(`GPGSA,A,${fixType},04,09,12,15,18,21,24,27,,,,,${pdop},${hdop},${vdop}`);
}

function buildGLL(fix) {
  const { value: latVal, hemi: latHemi } = toNmeaLat(fix.lat);
  const { value: lngVal, hemi: lngHemi } = toNmeaLng(fix.lng);
  const status = (fix.fixQuality ?? 1) > 0 ? 'A' : 'V';
  return frame(`GPGLL,${latVal},${latHemi},${lngVal},${lngHemi},${nmeaTime(fix.time)},${status},A`);
}

function buildGSV(fix) {
  const numSat = fix.satellites ?? 8;
  // One sentence, up to 4 satellites — enough to be a plausible, parseable
  // "satellites in view" report without simulating a full constellation.
  return frame(`GPGSV,1,1,${pad(numSat, 2)},04,45,180,42,09,60,090,40,12,30,270,38,15,75,000,44`);
}

function buildAll(fix) {
  return [buildGGA(fix), buildRMC(fix), buildVTG(fix), buildGSA(fix), buildGLL(fix), buildGSV(fix)];
}

module.exports = {
  toNmeaLat, toNmeaLng, nmeaTime, nmeaDate, checksum, frame,
  buildGGA, buildRMC, buildVTG, buildGSA, buildGLL, buildGSV, buildAll,
};
