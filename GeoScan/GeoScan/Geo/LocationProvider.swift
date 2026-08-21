//
//  LocationProvider.swift
//  Thin CoreLocation wrapper: the freshest fix, the compass heading captured at
//  session start, and enough plumbing to tell the operator why GPS is bad.
//

import Foundation
import Combine
import CoreLocation

@MainActor
final class LocationProvider: NSObject, ObservableObject {

    enum Quality: String {
        case none, poor, fair, good, excellent

        var label: String {
            switch self {
            case .none: return "No fix"
            case .poor: return "Poor"
            case .fair: return "Fair"
            case .good: return "Good"
            case .excellent: return "Excellent"
            }
        }
    }

    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var latestHeading: CLHeading?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdating = false
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .other
        manager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Lifecycle

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard !isUpdating else { return }
        if authorizationStatus == .notDetermined { requestAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 1
            manager.startUpdatingHeading()
        }
        isUpdating = true
    }

    func stop() {
        guard isUpdating else { return }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        isUpdating = false
    }

    // MARK: - Derived values

    /// CoreLocation's `altitude` is orthometric (geoid); the geodesy in this app
    /// is ellipsoidal, so prefer `ellipsoidalAltitude` and only fall back when
    /// the platform cannot supply it.
    var latestGeodetic: Geodetic? {
        guard let l = latestLocation else { return nil }
        return Geodetic(latitude: l.coordinate.latitude,
                        longitude: l.coordinate.longitude,
                        ellipsoidalHeight: l.ellipsoidalAltitude)
    }

    var horizontalAccuracy: Double? {
        guard let a = latestLocation?.horizontalAccuracy, a >= 0 else { return nil }
        return a
    }

    var quality: Quality {
        guard let accuracy = horizontalAccuracy else { return .none }
        // A fix older than a few seconds is stale enough to distrust while walking.
        if let age = latestLocation.map({ -$0.timestamp.timeIntervalSinceNow }), age > 5 { return .poor }
        switch accuracy {
        case ..<3: return .excellent
        case ..<8: return .good
        case ..<20: return .fair
        default: return .poor
        }
    }

    /// Heading in degrees from true north, or nil when the magnetometer has not
    /// produced a calibrated value.
    var trueHeading: Double? {
        guard let h = latestHeading, h.headingAccuracy >= 0, h.trueHeading >= 0 else { return nil }
        return h.trueHeading
    }
}

extension LocationProvider: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let newest = locations.last
        Task { @MainActor in
            guard let newest else { return }
            self.latestLocation = newest
            self.lastError = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.latestHeading = newHeading }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways, self.isUpdating {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = (error as NSError).code == CLError.denied.rawValue
            ? "Location access denied — the scan will not be georeferenced."
            : error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }
}
