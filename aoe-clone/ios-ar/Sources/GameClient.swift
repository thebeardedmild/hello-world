import Foundation
import CoreLocation

/// WebSocket client for the same protocol the browser client speaks
/// (see aoe-clone/public/client.js). Connects to the Node server over
/// plain ws:// — see README-ios-ar.md for the App Transport Security
/// exception that requires during local development.
@MainActor
final class GameClient: ObservableObject {
    @Published var connected = false
    @Published var myPlayerId: Int?
    @Published var origin: CLLocationCoordinate2D?
    @Published var unitTypes: [String: UnitTypeInfo] = [:]
    @Published var buildingTypes: [String: BuildingTypeInfo] = [:]
    @Published var playRadiusM: Double = 0
    @Published var state: StateMessage?
    @Published var errorMessage: String?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    func connect(host: String, name: String, lat: Double, lng: Double) {
        guard let url = URL(string: "ws://\(host)") else {
            errorMessage = "Invalid server address: \(host)"
            return
        }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        listen()
        send(["type": "join", "name": name, "lat": lat, "lng": lng])
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    func sendCommand(_ cmd: [String: Any]) {
        send(["type": "command", "cmd": cmd])
    }

    // Convenience wrappers matching the actions in server/game.js's handleCommand().
    func move(unitIds: [Int], to coord: CLLocationCoordinate2D) {
        sendCommand(["action": "move", "unitIds": unitIds, "lat": coord.latitude, "lng": coord.longitude])
    }

    func gather(unitIds: [Int], resourceId: Int) {
        sendCommand(["action": "gather", "unitIds": unitIds, "resourceId": resourceId])
    }

    func attack(unitIds: [Int], targetId: Int) {
        sendCommand(["action": "attack", "unitIds": unitIds, "targetId": targetId])
    }

    func build(unitIds: [Int], buildingType: String, at coord: CLLocationCoordinate2D) {
        sendCommand(["action": "build", "unitIds": unitIds, "buildingType": buildingType, "lat": coord.latitude, "lng": coord.longitude])
    }

    func train(buildingId: Int, unitType: String) {
        sendCommand(["action": "train", "buildingId": buildingId, "unitType": unitType])
    }

    func stop(unitIds: [Int]) {
        sendCommand(["action": "stop", "unitIds": unitIds])
    }

    private func send(_ dict: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in self.connected = false }
            case .success(let message):
                if case .string(let text) = message, let data = text.data(using: .utf8) {
                    Task { @MainActor in self.handle(data: data) }
                }
                self.listen()
            }
        }
    }

    private func handle(data: Data) {
        struct TypeProbe: Codable { let type: String }
        guard let probe = try? JSONDecoder().decode(TypeProbe.self, from: data) else { return }
        let decoder = JSONDecoder()
        switch probe.type {
        case "welcome":
            guard let msg = try? decoder.decode(WelcomeMessage.self, from: data) else { return }
            myPlayerId = msg.playerId
            origin = CLLocationCoordinate2D(latitude: msg.originLat, longitude: msg.originLng)
            unitTypes = msg.unitTypes
            buildingTypes = msg.buildingTypes
            playRadiusM = msg.playRadiusM
            connected = true
        case "state":
            guard let msg = try? decoder.decode(StateMessage.self, from: data) else { return }
            state = msg
        case "error":
            guard let msg = try? decoder.decode(ErrorMessage.self, from: data) else { return }
            errorMessage = msg.message
        default:
            break
        }
    }
}
