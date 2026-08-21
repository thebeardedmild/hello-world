//
//  ShaderBridge.swift
//
//  Swift-side names for the indices and modes declared in ShaderTypes.h.
//
//  The C enums come across the bridge with a shape that varies with how they are
//  declared, and code that has to write `Int(GSBufferIndexPoints.rawValue)`
//  everywhere reads badly. These constants are the single place the two sides are
//  kept in step — change one, change the other.
//

import Foundation

enum GSBuffer {
    static let points = 0
    static let unprojectUniforms = 1
    static let renderUniforms = 2
    static let pointCount = 3
}

enum GSTexture {
    static let y = 0
    static let cbcr = 1
    static let depth = 2
    static let confidence = 3
}

/// Must match GSColorMode in ShaderTypes.h.
enum PointColorMode: Float, CaseIterable, Identifiable {
    case rgb = 0
    case confidence = 1
    case height = 2
    case intensity = 3

    var id: Float { rawValue }

    var title: String {
        switch self {
        case .rgb: return "Colour"
        case .confidence: return "Confidence"
        case .height: return "Elevation"
        case .intensity: return "Mono"
        }
    }

    var symbolName: String {
        switch self {
        case .rgb: return "paintpalette"
        case .confidence: return "checkmark.seal"
        case .height: return "mountain.2"
        case .intensity: return "circle.lefthalf.filled"
        }
    }

    var explanation: String {
        switch self {
        case .rgb: return "Photographic colour sampled from the wide camera."
        case .confidence: return "Green is high LiDAR confidence, red is low. Use this to spot areas worth re-scanning."
        case .height: return "Elevation ramp across the scan's vertical extent."
        case .intensity: return "Luminance only — easier to read shape and edges."
        }
    }
}
