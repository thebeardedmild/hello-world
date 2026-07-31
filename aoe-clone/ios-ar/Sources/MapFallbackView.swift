import SwiftUI
import MapKit

/// Plain 2D map view of the live game state — useful because AR placement
/// (see ARGameView) is only approximate; the map is exact (it's the same
/// lat/lng the server sends) and easier to read at a glance while walking.
struct MapFallbackView: UIViewRepresentable {
    @ObservedObject var client: GameClient
    @ObservedObject var location: LocationManager

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        if let origin = client.origin {
            let region = MKCoordinateRegion(
                center: origin,
                latitudinalMeters: max(client.playRadiusM * 2.5, 200),
                longitudinalMeters: max(client.playRadiusM * 2.5, 200),
            )
            map.setRegion(region, animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let state = client.state else { return }
        map.removeAnnotations(map.annotations)

        for unit in state.units {
            let a = MKPointAnnotation()
            a.coordinate = CLLocationCoordinate2D(latitude: unit.lat, longitude: unit.lng)
            a.title = client.unitTypes[unit.type]?.name ?? unit.type
            map.addAnnotation(a)
        }
        for building in state.buildings {
            let a = MKPointAnnotation()
            a.coordinate = CLLocationCoordinate2D(latitude: building.lat, longitude: building.lng)
            a.title = client.buildingTypes[building.type]?.name ?? building.type
            map.addAnnotation(a)
        }
        for resource in state.resources {
            let a = MKPointAnnotation()
            a.coordinate = CLLocationCoordinate2D(latitude: resource.lat, longitude: resource.lng)
            a.title = resource.type
            map.addAnnotation(a)
        }
    }
}
