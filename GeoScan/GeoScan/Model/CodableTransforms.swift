//
//  CodableTransforms.swift
//  simd matrices are not Codable, and a scan is worthless without its camera
//  poses, so wrap them in something JSON can hold. Column-major, matching simd.
//

import Foundation
import simd

struct Matrix4x4Codable: Codable, Equatable {
    var columns: [Float]   // 16 values, column-major

    init(_ m: simd_float4x4) {
        columns = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                   m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                   m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                   m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }

    var matrix: simd_float4x4 {
        guard columns.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(SIMD4(columns[0], columns[1], columns[2], columns[3]),
                             SIMD4(columns[4], columns[5], columns[6], columns[7]),
                             SIMD4(columns[8], columns[9], columns[10], columns[11]),
                             SIMD4(columns[12], columns[13], columns[14], columns[15]))
    }
}

struct Matrix3x3Codable: Codable, Equatable {
    var columns: [Float]   // 9 values, column-major

    init(_ m: simd_float3x3) {
        columns = [m.columns.0.x, m.columns.0.y, m.columns.0.z,
                   m.columns.1.x, m.columns.1.y, m.columns.1.z,
                   m.columns.2.x, m.columns.2.y, m.columns.2.z]
    }

    var matrix: simd_float3x3 {
        guard columns.count == 9 else { return matrix_identity_float3x3 }
        return simd_float3x3(SIMD3(columns[0], columns[1], columns[2]),
                             SIMD3(columns[3], columns[4], columns[5]),
                             SIMD3(columns[6], columns[7], columns[8]))
    }
}

extension simd_float4x4 {
    /// Translation column.
    var position: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
    /// ARKit camera looks down its own -Z.
    var forward: SIMD3<Float> { -SIMD3(columns.2.x, columns.2.y, columns.2.z) }
    var right: SIMD3<Float> { SIMD3(columns.0.x, columns.0.y, columns.0.z) }
    var up: SIMD3<Float> { SIMD3(columns.1.x, columns.1.y, columns.1.z) }

    init(translation t: SIMD3<Float>) {
        self.init(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(SIMD4(x, 0, 0, 0),
                             SIMD4(0, y, 0, 0),
                             SIMD4(0, 0, z, -1),
                             SIMD4(0, 0, z * near, 0))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        var upAxis = up
        // Guard the degenerate case where the view direction is parallel to up.
        if abs(simd_dot(f, simd_normalize(upAxis))) > 0.999 { upAxis = SIMD3(0, 0, 1) }
        let s = simd_normalize(simd_cross(f, upAxis))
        let u = simd_cross(s, f)
        return simd_float4x4(SIMD4(s.x, u.x, -f.x, 0),
                             SIMD4(s.y, u.y, -f.y, 0),
                             SIMD4(s.z, u.z, -f.z, 0),
                             SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1))
    }
}
