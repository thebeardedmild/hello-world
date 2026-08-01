const { moveToward, randomPointNear, bearingDegrees, toLatLng } = require('./geo');

/**
 * Simulated GPS receiver. Tracks a "true" position and reports a jittered
 * fix from it (consumer GPS is typically accurate to only ~5-15m), in one
 * of three modes:
 *   - stationary: sits at the current position
 *   - route: follows an ordered list of waypoints at a fixed speed
 *   - walk: picks random points within a radius and wanders between them,
 *     like a person walking around a park — useful for exercising
 *     location-based apps under continuous, unpredictable movement.
 */
class GpsSimulator {
  constructor({ lat, lng, altitude = 10, jitterM = 5, satellites = 8, hdop = 1.2 } = {}) {
    this.trueLat = lat;
    this.trueLng = lng;
    this.altitude = altitude;
    this.jitterM = jitterM;
    this.satellites = satellites;
    this.hdop = hdop;
    this.fixQuality = 1;

    this.mode = 'stationary';
    this.speedMps = 0;
    this.headingDeg = 0;

    this.route = null;
    this.routeIndex = 0;
    this.routeSpeedMps = 0;
    this.routeLoop = false;

    this.walkCenter = null;
    this.walkRadiusM = 0;
    this.walkSpeedMps = 0;
    this.walkTarget = null;
  }

  setPosition(lat, lng, altitude) {
    this.trueLat = lat;
    this.trueLng = lng;
    if (altitude !== undefined) this.altitude = altitude;
    this.mode = 'stationary';
    this.speedMps = 0;
    this.route = null;
    this.walkCenter = null;
  }

  setRoute(waypoints, speedMps = 1.4, loop = false) {
    if (!Array.isArray(waypoints) || waypoints.length === 0) throw new Error('route needs at least one waypoint');
    this.route = waypoints;
    this.routeIndex = 0;
    this.routeSpeedMps = speedMps;
    this.routeLoop = loop;
    this.mode = 'route';
    this.walkCenter = null;
  }

  startWalk(centerLat, centerLng, radiusM, speedMps = 1.4) {
    this.walkCenter = { lat: centerLat, lng: centerLng };
    this.walkRadiusM = radiusM;
    this.walkSpeedMps = speedMps;
    this.mode = 'walk';
    this.route = null;
    this.walkTarget = randomPointNear(this.walkCenter, this.walkRadiusM);
  }

  stop() {
    this.mode = 'stationary';
    this.speedMps = 0;
    this.route = null;
    this.walkCenter = null;
  }

  setJitter(meters) {
    this.jitterM = meters;
  }

  tick(dt) {
    if (dt <= 0) return;
    if (this.mode === 'route' && this.route) this._advanceRoute(dt);
    else if (this.mode === 'walk' && this.walkCenter) this._advanceWalk(dt);
    else this.speedMps = 0;
  }

  _advanceRoute(dt) {
    let remainingStep = this.routeSpeedMps * dt;
    let guard = 0; // avoid pathological infinite loops on zero-length legs
    while (remainingStep > 1e-6 && this.route && guard++ < 100) {
      const target = this.route[this.routeIndex];
      const from = { lat: this.trueLat, lng: this.trueLng };
      const res = moveToward(from, target, remainingStep);
      this.headingDeg = bearingDegrees(from, res.point);
      this.trueLat = res.point.lat;
      this.trueLng = res.point.lng;
      this.speedMps = this.routeSpeedMps;
      if (res.arrived) {
        remainingStep = res.remaining;
        this.routeIndex++;
        if (this.routeIndex >= this.route.length) {
          if (this.routeLoop) {
            this.routeIndex = 0;
          } else {
            this.mode = 'stationary';
            this.speedMps = 0;
            this.route = null;
            break;
          }
        }
      } else {
        remainingStep = 0;
      }
    }
  }

  _advanceWalk(dt) {
    let remainingStep = this.walkSpeedMps * dt;
    let guard = 0;
    while (remainingStep > 1e-6 && this.walkCenter && guard++ < 100) {
      const from = { lat: this.trueLat, lng: this.trueLng };
      const res = moveToward(from, this.walkTarget, remainingStep);
      this.headingDeg = bearingDegrees(from, res.point);
      this.trueLat = res.point.lat;
      this.trueLng = res.point.lng;
      this.speedMps = this.walkSpeedMps;
      if (res.arrived) {
        remainingStep = res.remaining;
        this.walkTarget = randomPointNear(this.walkCenter, this.walkRadiusM);
      } else {
        remainingStep = 0;
      }
    }
  }

  // The reported fix — true position plus jitter, as a real receiver would
  // report it with its own noise, not the ground truth.
  getFix() {
    let lat = this.trueLat;
    let lng = this.trueLng;
    if (this.jitterM > 0) {
      const angle = Math.random() * Math.PI * 2;
      const r = Math.random() * this.jitterM;
      const jittered = toLatLng({ lat, lng }, r * Math.sin(angle), r * Math.cos(angle));
      lat = jittered.lat;
      lng = jittered.lng;
    }
    return {
      lat, lng,
      altitude: this.altitude,
      speedMps: this.speedMps,
      headingDeg: this.headingDeg,
      time: new Date(),
      satellites: this.satellites,
      hdop: this.hdop,
      fixQuality: this.fixQuality,
    };
  }

  getStatus() {
    return {
      mode: this.mode,
      truePosition: { lat: this.trueLat, lng: this.trueLng },
      altitude: this.altitude,
      speedMps: this.speedMps,
      headingDeg: this.headingDeg,
      jitterM: this.jitterM,
      route: this.route ? { waypointCount: this.route.length, index: this.routeIndex, loop: this.routeLoop, speedMps: this.routeSpeedMps } : null,
      walk: this.walkCenter ? { center: this.walkCenter, radiusM: this.walkRadiusM, speedMps: this.walkSpeedMps, target: this.walkTarget } : null,
    };
  }
}

module.exports = { GpsSimulator };
