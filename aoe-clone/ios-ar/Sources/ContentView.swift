import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject private var client = GameClient()
    @StateObject private var location = LocationManager()
    @State private var name = ""
    @State private var host = "192.168.1.100:3000" // your server's LAN IP:port, or a tunnel host
    @State private var joined = false
    @State private var showAR = true
    @State private var waitingForFix = false

    var body: some View {
        if !joined {
            joinForm
        } else if !client.connected {
            connectingView
        } else {
            ZStack(alignment: .top) {
                if showAR {
                    ARGameView(client: client, location: location).ignoresSafeArea()
                } else {
                    MapFallbackView(client: client, location: location).ignoresSafeArea()
                }
                hud
            }
        }
    }

    private var joinForm: some View {
        VStack(spacing: 16) {
            Text("Empires Clone — AR").font(.title).bold()
            Text("Run the Node server from aoe-clone/ and enter its address below.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Server address (host:port)", text: $host)
                .textFieldStyle(.roundedBorder).autocapitalization(.none).disableAutocorrection(true)
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let err = client.errorMessage {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            Button(waitingForFix ? "Getting location…" : "Join") {
                location.requestPermission()
                location.start()
                waitingForFix = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(waitingForFix)
        }
        .padding()
        // TODO: this polls with a fixed delay for simplicity; a production
        // version should use Combine (location.$coordinate.sink) instead.
        .onChange(of: location.coordinate) { _, newValue in
            guard waitingForFix, let coord = newValue else { return }
            joined = true
            client.connect(host: host, name: name.isEmpty ? "Player" : name, lat: coord.latitude, lng: coord.longitude)
        }
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting to \(host)…")
            if let err = client.errorMessage {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private var hud: some View {
        HStack {
            if let me = client.state?.players.first(where: { $0.id == client.myPlayerId }) {
                Text("🌲\(Int(me.resources["wood"] ?? 0)) 🍎\(Int(me.resources["food"] ?? 0)) 🪙\(Int(me.resources["gold"] ?? 0)) 👥\(me.population)/\(me.popCap)")
                    .padding(8).background(.black.opacity(0.6)).foregroundColor(.white).cornerRadius(8)
            }
            Spacer()
            Button(showAR ? "Map View" : "AR View") { showAR.toggle() }
                .padding(8).background(.black.opacity(0.6)).foregroundColor(.white).cornerRadius(8)
        }
        .padding()
    }
}
