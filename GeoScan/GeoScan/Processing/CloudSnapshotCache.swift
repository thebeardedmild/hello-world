//
//  CloudSnapshotCache.swift
//
//  Picking needs a spatial index, and building one over a few million points
//  costs a noticeable fraction of a second — far too long to do on every tap, and
//  pointless to redo when nothing has changed.
//
//  So the snapshot is cached and only rebuilt when the cloud has actually grown
//  meaningfully or the cache has gone stale. During a live scan that means one
//  rebuild every few seconds at most; in the reviewer, exactly one.
//

import Foundation

@MainActor
final class CloudSnapshotCache {

    /// Rebuild if the cloud grew by more than this fraction.
    var growthThreshold: Double = 0.08
    /// Rebuild if the snapshot is older than this, even if the cloud is quiet.
    var maximumAge: TimeInterval = 4.0
    /// Upper bound on points fed to the picker; beyond this the index costs more
    /// than the extra precision is worth.
    var maximumPoints: Int = 3_000_000

    private var cached: PointCloud?
    private var cachedCount: Int = 0
    private var cachedAt: Date = .distantPast
    private var isBuilding = false

    /// Returns the current snapshot, rebuilding first if it has gone stale.
    func cloud(liveCount: Int, snapshot: () -> [GSPoint]) -> PointCloud? {
        if let cached, !isStale(liveCount: liveCount) { return cached }
        guard !isBuilding else { return cached }

        isBuilding = true
        defer { isBuilding = false }

        let points = snapshot()
        guard !points.isEmpty else { return cached }
        let cloud = PointCloud(points: points)
        // Build the index eagerly: doing it here costs the same, but it happens
        // before the tap rather than during it.
        _ = cloud.spatialIndex()
        cached = cloud
        cachedCount = liveCount
        cachedAt = Date()
        return cloud
    }

    func set(_ cloud: PointCloud) {
        cached = cloud
        cachedCount = cloud.count
        cachedAt = Date()
        _ = cloud.spatialIndex()
    }

    func invalidate() {
        cached = nil
        cachedCount = 0
        cachedAt = .distantPast
    }

    var current: PointCloud? { cached }

    private func isStale(liveCount: Int) -> Bool {
        if Date().timeIntervalSince(cachedAt) > maximumAge { return true }
        guard cachedCount > 0 else { return true }
        let growth = Double(liveCount - cachedCount) / Double(cachedCount)
        return growth > growthThreshold
    }
}
