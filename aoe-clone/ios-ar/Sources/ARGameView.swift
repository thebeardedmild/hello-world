import SwiftUI
import RealityKit
import ARKit
import CoreLocation

/// Places a colored sphere for every unit/building/resource within 150m,
/// positioned by GPS distance + bearing from the player's current location.
///
/// IMPORTANT — this is GPS + compass placement, not true shared AR: it uses
/// `.gravityAndHeading` world alignment so the AR session's -Z axis points
/// at true north, then converts each entity's real-world bearing/distance
/// into that coordinate space. Consumer GPS/compass error (5-15m, several
/// degrees) means placement will drift and won't line up precisely between
/// two nearby phones. For genuinely shared/persistent AR anchors, look at
/// ARKit's `ARGeoTrackingConfiguration` (works in areas with Apple Maps
/// street-level coverage) or a third-party VPS like Niantic Lightship —
/// swapping the placement math below is the integration point for either.
struct ARGameView: UIViewRepresentable {
    @ObservedObject var client: GameClient
    @ObservedObject var location: LocationManager

    func makeCoordinator() -> ARCoordinator { ARCoordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsWorldTracking {
            config.worldAlignment = .gravityAndHeading
            arView.session.run(config)
        }
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        guard let myLoc = location.coordinate, let state = client.state else { return }
        var liveIds = Set<String>()

        func upsert(id: String, lat: Double, lng: Double, color: UIColor, radius: Float) {
            let target = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            let distance = GeoMath.distanceMeters(myLoc, target)
            guard distance < 150, distance > 0.4 else { return }
            liveIds.insert(id)

            let bearing = GeoMath.bearingRadians(from: myLoc, to: target)
            let x = Float(distance * sin(bearing))
            let z = Float(-distance * cos(bearing)) // -Z is north under .gravityAndHeading
            let y: Float = -1.2 // roughly ground level relative to the camera

            if let anchor = context.coordinator.anchors[id] {
                anchor.transform.translation = SIMD3<Float>(x, y, z)
            } else {
                let mesh = MeshResource.generateSphere(radius: radius)
                let material = SimpleMaterial(color: color, isMetallic: false)
                let model = ModelEntity(mesh: mesh, materials: [material])
                let anchor = AnchorEntity(world: SIMD3<Float>(x, y, z))
                anchor.addChild(model)
                arView.scene.addAnchor(anchor)
                context.coordinator.anchors[id] = anchor
            }
        }

        for unit in state.units {
            upsert(
                id: "u\(unit.id)", lat: unit.lat, lng: unit.lng,
                color: colorFor(ownerId: unit.ownerId, players: state.players),
                radius: unit.type == "villager" ? 0.3 : 0.35,
            )
        }
        for building in state.buildings {
            let sizeM = client.buildingTypes[building.type]?.size ?? 8
            upsert(
                id: "b\(building.id)", lat: building.lat, lng: building.lng,
                color: colorFor(ownerId: building.ownerId, players: state.players),
                radius: Float(min(sizeM / 2, 2)),
            )
        }
        for resource in state.resources {
            let color: UIColor = resource.type == "wood" ? .brown : (resource.type == "food" ? .systemRed : .systemYellow)
            upsert(id: "r\(resource.id)", lat: resource.lat, lng: resource.lng, color: color, radius: 0.2)
        }

        for (id, anchor) in context.coordinator.anchors where !liveIds.contains(id) {
            arView.scene.removeAnchor(anchor)
            context.coordinator.anchors.removeValue(forKey: id)
        }
    }

    private func colorFor(ownerId: Int, players: [PlayerDTO]) -> UIColor {
        guard let hex = players.first(where: { $0.id == ownerId })?.color else { return .gray }
        return UIColor(hex: hex)
    }
}

final class ARCoordinator {
    var anchors: [String: AnchorEntity] = [:]
}

extension UIColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
