//
//  MotionLogger.swift
//
//  ARKit already fuses the IMU internally for pose, so the value of reading it
//  directly is in the two things ARKit does not hand back:
//
//    1. A shake/blur gate. Above roughly 1 rad/s the rolling shutter smears the
//       frame badly enough that colour lands on the wrong geometry, so we stop
//       accumulating until the phone settles. This is the single biggest win for
//       point cloud colour quality.
//    2. A barometric altitude trace, which is far steadier than GPS altitude over
//       a few minutes and is used to sanity-check the vertical solution.
//

import Foundation
import Combine
import CoreMotion
import simd

struct MotionSample: Codable {
    var timestamp: TimeInterval
    var attitude: SIMD3<Double>        // roll, pitch, yaw (radians)
    var rotationRate: SIMD3<Double>    // radians / s
    var userAcceleration: SIMD3<Double> // g, gravity removed
    var relativeAltitude: Double?      // metres since start, barometric
}

@MainActor
final class MotionLogger: ObservableObject {

    /// Rotation rate above which frames are considered motion-blurred.
    var blurAngularRateThreshold: Double = 1.0
    /// Acceleration above which the operator is basically swinging the phone.
    var blurAccelerationThreshold: Double = 0.7

    @Published private(set) var angularSpeed: Double = 0
    @Published private(set) var accelerationMagnitude: Double = 0
    @Published private(set) var isSteady: Bool = true
    @Published private(set) var relativeAltitude: Double?
    @Published private(set) var isRunning = false

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()

    /// Downsampled trace kept for export; the full 100 Hz stream is not retained.
    private(set) var samples: [MotionSample] = []
    private var lastSampleTime: TimeInterval = 0
    private let sampleInterval: TimeInterval = 0.05   // 20 Hz into the log

    init() {
        queue.name = "com.geoscan.motion"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
    }

    func start() {
        guard !isRunning else { return }
        samples.removeAll()
        lastSampleTime = 0

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 100.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                let rate = SIMD3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
                let accel = SIMD3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z)
                let attitude = SIMD3(data.attitude.roll, data.attitude.pitch, data.attitude.yaw)
                let angular = simd_length(rate)
                let linear = simd_length(accel)
                let timestamp = data.timestamp
                Task { @MainActor in
                    self.ingest(timestamp: timestamp, attitude: attitude, rate: rate,
                                accel: accel, angular: angular, linear: linear)
                }
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                let value = data.relativeAltitude.doubleValue
                Task { @MainActor in self.relativeAltitude = value }
            }
        }

        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        isRunning = false
    }

    private func ingest(timestamp: TimeInterval, attitude: SIMD3<Double>, rate: SIMD3<Double>,
                        accel: SIMD3<Double>, angular: Double, linear: Double) {
        angularSpeed = angular
        accelerationMagnitude = linear
        isSteady = angular < blurAngularRateThreshold && linear < blurAccelerationThreshold

        if timestamp - lastSampleTime >= sampleInterval {
            lastSampleTime = timestamp
            samples.append(MotionSample(timestamp: timestamp,
                                        attitude: attitude,
                                        rotationRate: rate,
                                        userAcceleration: accel,
                                        relativeAltitude: relativeAltitude))
        }
    }
}
