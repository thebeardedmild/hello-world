//
//  Geodesy.swift
//  WGS84 geodetic <-> ECEF <-> local tangent plane (ENU) conversions.
//
//  Everything in the app is captured in ARKit's gravity-aligned world frame
//  (metres, +Y up). Georeferencing is a *late* step: a GeoSolution maps that
//  world frame onto an East/North/Up tangent plane whose origin has a known
//  latitude, longitude and ellipsoidal height. Keeping the raw cloud in world
//  space means a scan can be re-solved with better GPS afterwards without
//  touching a single point.
//

import Foundation
import simd

/// WGS84 reference ellipsoid.
enum WGS84 {
    static let semiMajorAxis: Double = 6_378_137.0
    static let inverseFlattening: Double = 298.257_223_563
    static let flattening: Double = 1.0 / inverseFlattening
    static let semiMinorAxis: Double = semiMajorAxis * (1.0 - flattening)
    /// First eccentricity squared.
    static let e2: Double = flattening * (2.0 - flattening)
    /// Second eccentricity squared.
    static let ep2: Double = e2 / (1.0 - e2)
}

struct Geodetic: Codable, Equatable, Hashable {
    /// Degrees, positive north.
    var latitude: Double
    /// Degrees, positive east.
    var longitude: Double
    /// Metres above the WGS84 ellipsoid (*not* mean sea level).
    var ellipsoidalHeight: Double

    static let zero = Geodetic(latitude: 0, longitude: 0, ellipsoidalHeight: 0)
}

struct ECEF: Equatable {
    var x: Double
    var y: Double
    var z: Double
}

/// A local tangent-plane offset in metres.
struct ENU: Codable, Equatable {
    var east: Double
    var north: Double
    var up: Double

    static let zero = ENU(east: 0, north: 0, up: 0)

    var horizontalLength: Double { (east * east + north * north).squareRoot() }
    var length: Double { (east * east + north * north + up * up).squareRoot() }
}

enum Geodesy {

    // MARK: - Geodetic <-> ECEF

    static func ecef(from g: Geodetic) -> ECEF {
        let lat = g.latitude * .pi / 180.0
        let lon = g.longitude * .pi / 180.0
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)
        // Radius of curvature in the prime vertical.
        let n = WGS84.semiMajorAxis / (1.0 - WGS84.e2 * sinLat * sinLat).squareRoot()
        let h = g.ellipsoidalHeight
        return ECEF(x: (n + h) * cosLat * cosLon,
                    y: (n + h) * cosLat * sinLon,
                    z: (n * (1.0 - WGS84.e2) + h) * sinLat)
    }

    /// Bowring's method — converges to sub-millimetre in a handful of iterations
    /// for any height a phone will ever see.
    static func geodetic(from e: ECEF) -> Geodetic {
        let a = WGS84.semiMajorAxis
        let b = WGS84.semiMinorAxis
        let p = (e.x * e.x + e.y * e.y).squareRoot()
        let lon = atan2(e.y, e.x)

        if p < 1e-9 {
            // On the polar axis.
            let lat = e.z >= 0 ? Double.pi / 2 : -Double.pi / 2
            return Geodetic(latitude: lat * 180.0 / .pi,
                            longitude: lon * 180.0 / .pi,
                            ellipsoidalHeight: abs(e.z) - b)
        }

        var lat = atan2(e.z, p * (1.0 - WGS84.e2))
        var height = 0.0
        for _ in 0..<8 {
            let sinLat = sin(lat)
            let n = a / (1.0 - WGS84.e2 * sinLat * sinLat).squareRoot()
            height = p / cos(lat) - n
            let next = atan2(e.z, p * (1.0 - WGS84.e2 * n / (n + height)))
            if abs(next - lat) < 1e-13 { lat = next; break }
            lat = next
        }
        let sinLat = sin(lat)
        let n = a / (1.0 - WGS84.e2 * sinLat * sinLat).squareRoot()
        height = p / cos(lat) - n

        return Geodetic(latitude: lat * 180.0 / .pi,
                        longitude: lon * 180.0 / .pi,
                        ellipsoidalHeight: height)
    }

    // MARK: - Tangent plane

    /// ENU offset of `point` relative to `origin`.
    static func enu(of point: Geodetic, from origin: Geodetic) -> ENU {
        let o = ecef(from: origin)
        let p = ecef(from: point)
        return enu(ecefDelta: ECEF(x: p.x - o.x, y: p.y - o.y, z: p.z - o.z), at: origin)
    }

    static func enu(ecefDelta d: ECEF, at origin: Geodetic) -> ENU {
        let lat = origin.latitude * .pi / 180.0
        let lon = origin.longitude * .pi / 180.0
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)
        return ENU(east:  -sinLon * d.x + cosLon * d.y,
                   north: -sinLat * cosLon * d.x - sinLat * sinLon * d.y + cosLat * d.z,
                   up:     cosLat * cosLon * d.x + cosLat * sinLon * d.y + sinLat * d.z)
    }

    /// Inverse of `enu(of:from:)`.
    static func geodetic(enu e: ENU, from origin: Geodetic) -> Geodetic {
        let lat = origin.latitude * .pi / 180.0
        let lon = origin.longitude * .pi / 180.0
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)

        let dx = -sinLon * e.east - sinLat * cosLon * e.north + cosLat * cosLon * e.up
        let dy =  cosLon * e.east - sinLat * sinLon * e.north + cosLat * sinLon * e.up
        let dz =  cosLat * e.north + sinLat * e.up

        let o = ecef(from: origin)
        return geodetic(from: ECEF(x: o.x + dx, y: o.y + dy, z: o.z + dz))
    }

    // MARK: - Convenience

    /// Great-circle-ish ground distance between two fixes, good to a few cm at
    /// the scales a handheld scan covers.
    static func groundDistance(_ a: Geodetic, _ b: Geodetic) -> Double {
        Geodesy.enu(of: b, from: a).horizontalLength
    }

    /// Metres per degree of latitude/longitude at a given latitude. Handy for
    /// sanity-checking GPS noise without a full projection.
    static func metersPerDegree(atLatitude latitude: Double) -> (lat: Double, lon: Double) {
        let phi = latitude * .pi / 180.0
        let sinPhi = sin(phi)
        let denom = (1.0 - WGS84.e2 * sinPhi * sinPhi)
        let m = WGS84.semiMajorAxis * (1.0 - WGS84.e2) / pow(denom, 1.5)   // meridional radius
        let n = WGS84.semiMajorAxis / denom.squareRoot()                    // prime vertical radius
        return (m * .pi / 180.0, n * cos(phi) * .pi / 180.0)
    }
}
