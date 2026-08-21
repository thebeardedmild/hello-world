//
//  UTM.swift
//  WGS84 -> UTM forward projection, used for LAS export so the cloud lands in a
//  metric, GIS-native coordinate reference system that CloudCompare, QGIS,
//  ArcGIS, Civil 3D and Recap all understand without a prompt.
//

import Foundation

struct UTMZone: Codable, Equatable {
    var number: Int          // 1...60
    var isNorthernHemisphere: Bool

    /// EPSG code for WGS84 / UTM.
    var epsgCode: Int { (isNorthernHemisphere ? 32_600 : 32_700) + number }

    var name: String { "WGS 84 / UTM zone \(number)\(isNorthernHemisphere ? "N" : "S")" }

    /// Central meridian in degrees.
    var centralMeridian: Double { Double(number) * 6.0 - 183.0 }

    static func containing(latitude: Double, longitude: Double) -> UTMZone {
        var lon = longitude
        while lon < -180 { lon += 360 }
        while lon >= 180 { lon -= 360 }
        var number = Int(floor((lon + 180.0) / 6.0)) + 1
        number = max(1, min(60, number))
        return UTMZone(number: number, isNorthernHemisphere: latitude >= 0)
    }
}

struct UTMCoordinate: Equatable {
    var easting: Double
    var northing: Double
    var zone: UTMZone
    /// Ellipsoidal height carried straight through; UTM does not touch Z.
    var height: Double
}

enum UTM {
    private static let k0 = 0.9996
    private static let falseEasting = 500_000.0
    private static let falseNorthingSouth = 10_000_000.0

    /// Forward projection. Accurate to a few millimetres inside a zone, which is
    /// well below the noise floor of anything a handheld LiDAR produces.
    ///
    /// Zones are the plain 6°-wide rule; the Norway/Svalbard exceptions are not
    /// applied, so a scan there should pin `forcedZone` explicitly.
    static func project(_ g: Geodetic, forcedZone: UTMZone? = nil) -> UTMCoordinate {
        let zone = forcedZone ?? UTMZone.containing(latitude: g.latitude, longitude: g.longitude)

        let a = WGS84.semiMajorAxis
        let e2 = WGS84.e2
        let ep2 = WGS84.ep2

        let phi = g.latitude * .pi / 180.0
        let lambda = g.longitude * .pi / 180.0
        let lambda0 = zone.centralMeridian * .pi / 180.0

        let sinPhi = sin(phi), cosPhi = cos(phi), tanPhi = tan(phi)

        let n = a / (1.0 - e2 * sinPhi * sinPhi).squareRoot()
        let t = tanPhi * tanPhi
        let c = ep2 * cosPhi * cosPhi

        // Keep the longitude difference in (-pi, pi] so a scan next to the
        // antimeridian does not blow up.
        var dLambda = lambda - lambda0
        while dLambda > .pi { dLambda -= 2 * .pi }
        while dLambda < -.pi { dLambda += 2 * .pi }
        let aTerm = dLambda * cosPhi

        // Meridional arc.
        let m = a * ((1.0 - e2 / 4.0 - 3.0 * e2 * e2 / 64.0 - 5.0 * e2 * e2 * e2 / 256.0) * phi
                     - (3.0 * e2 / 8.0 + 3.0 * e2 * e2 / 32.0 + 45.0 * e2 * e2 * e2 / 1024.0) * sin(2 * phi)
                     + (15.0 * e2 * e2 / 256.0 + 45.0 * e2 * e2 * e2 / 1024.0) * sin(4 * phi)
                     - (35.0 * e2 * e2 * e2 / 3072.0) * sin(6 * phi))

        let a2 = aTerm * aTerm
        let a3 = a2 * aTerm
        let a4 = a3 * aTerm
        let a5 = a4 * aTerm
        let a6 = a5 * aTerm

        let easting = k0 * n * (aTerm
                                + (1.0 - t + c) * a3 / 6.0
                                + (5.0 - 18.0 * t + t * t + 72.0 * c - 58.0 * ep2) * a5 / 120.0)
            + falseEasting

        var northing = k0 * (m + n * tanPhi * (a2 / 2.0
                                               + (5.0 - t + 9.0 * c + 4.0 * c * c) * a4 / 24.0
                                               + (61.0 - 58.0 * t + t * t + 600.0 * c - 330.0 * ep2) * a6 / 720.0))
        if !zone.isNorthernHemisphere || g.latitude < 0 {
            northing += falseNorthingSouth
        }

        return UTMCoordinate(easting: easting,
                             northing: northing,
                             zone: UTMZone(number: zone.number, isNorthernHemisphere: g.latitude >= 0),
                             height: g.ellipsoidalHeight)
    }

    /// OGC WKT1 for the zone, embedded in the LAS 1.4 projection VLR so the file
    /// is self-describing.
    static func wkt(for zone: UTMZone) -> String {
        let cm = zone.centralMeridian
        let falseNorthing = zone.isNorthernHemisphere ? 0.0 : falseNorthingSouth
        return """
        PROJCS["\(zone.name)",\
        GEOGCS["WGS 84",\
        DATUM["WGS_1984",\
        SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],\
        AUTHORITY["EPSG","6326"]],\
        PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],\
        UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],\
        AUTHORITY["EPSG","4326"]],\
        PROJECTION["Transverse_Mercator"],\
        PARAMETER["latitude_of_origin",0],\
        PARAMETER["central_meridian",\(Int(cm))],\
        PARAMETER["scale_factor",0.9996],\
        PARAMETER["false_easting",500000],\
        PARAMETER["false_northing",\(Int(falseNorthing))],\
        UNIT["metre",1,AUTHORITY["EPSG","9001"]],\
        AXIS["Easting",EAST],\
        AXIS["Northing",NORTH],\
        AUTHORITY["EPSG","\(zone.epsgCode)"]]
        """
    }
}
