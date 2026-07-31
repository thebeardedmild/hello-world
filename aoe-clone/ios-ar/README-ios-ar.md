# Empires Clone — iOS AR companion (scaffold)

This connects to the exact same Node server in `aoe-clone/server/` — it's a
native AR/camera view onto the same live match the web client shows on a
map. **This code was written without a Mac/Xcode available to compile or run
it.** It's structurally sound Swift following current SwiftUI/RealityKit/
ARKit patterns, but treat it as a first draft to build and debug in Xcode,
not a tested app. Syntax check it with `swift build`/Xcode's error list
before assuming any given line is correct.

## What "AR" means here (read this first)

There is no shared/persistent AR world — each phone places 3D markers in its
own camera view using **GPS distance + compass bearing** from the player's
current location, not a synced 3D coordinate space. Two nearby phones will
each show units *roughly* where they belong, but not in exactly the same
spot (consumer GPS is accurate to ~5-15m, compass to a few degrees). That's
inherent to what ARKit's stock APIs give you for free — Pokémon GO-style
precise shared placement uses Niantic's own Lightship VPS, which is a
separate integration (see "Next steps" below).

For anything where precision matters (or if the AR drift is annoying), the
same app has a **Map View** toggle that shows the exact server-authoritative
positions on a normal 2D map — genuinely accurate, just not "AR."

## Requirements

- A Mac with Xcode 15+ (ARKit/RealityKit require a real iOS device — the
  Simulator has no camera or motion sensors, so AR mode won't run there;
  Map View will).
- A physical iPhone (iOS 16+) to test on, and an Apple ID for on-device
  signing (a free account works for local testing; TestFlight distribution
  to friends needs a paid Apple Developer account).
- The Node server from `aoe-clone/` running and reachable from your phone
  (same LAN, or a tunnel — see the main README's "Playing on iOS / over
  cellular data" section).

## Setup

1. In Xcode: **File → New → Project → iOS → App**. Name it (e.g.
   `EmpiresCloneAR`), Interface: **SwiftUI**, Language: **Swift**.
2. Delete the template's `ContentView.swift` and `*App.swift`.
3. Drag every file in `ios-ar/Sources/` into the project navigator (check
   "Copy items if needed" and make sure they're added to your app target).
4. Open your target's **Info** tab and add the two required privacy keys
   (`NSLocationWhenInUseUsageDescription`, `NSCameraUsageDescription`) —
   values are in `InfoPlist-additions.xml` in this folder. If your server is
   plain `ws://` on your LAN (the default), also add the
   `NSAppTransportSecurity` / `NSAllowsLocalNetworking` exception from that
   same file, or point `host` at a `wss://` tunnel instead (preferred if
   you're not on the same network).
5. In `ContentView.swift`, the `host` field defaults to
   `192.168.1.100:3000` — change it (or just type the real address into the
   text field at runtime) to your server's actual LAN IP/port or tunnel
   host.
6. Build to your iPhone (not the Simulator), trust the developer profile if
   prompted (Settings → General → VPN & Device Management), and grant
   location + camera permissions.

## Known limitations

- Approximate AR placement only (see above) — no persistent or
  cross-device-synced anchors.
- No occlusion: units render "through" real walls/objects since the app has
  no model of real-world geometry (LiDAR-equipped devices could add this —
  see below).
- No pathfinding around real obstacles, same as the web client — this is a
  simulation limitation shared by both clients, not AR-specific.
- The join flow's location wait (`ContentView.swift`) uses a simple
  `onChange` on the first location fix rather than proper loading-state
  handling — fine for a scaffold, worth hardening.

## Next steps if you want to go further

- **`ARGeoTrackingConfiguration`** — Apple's geo-anchored AR API, more
  accurate than the compass-based placement here, but only available where
  Apple Maps has street-level coverage (major US/UK/etc. cities). Swap-in
  point is `ARGameView.swift`'s `makeUIView`/placement math.
- **Niantic Lightship ARDK** — third-party SDK built specifically for this
  genre (VPS-backed shared AR anchors); a bigger integration than a stock
  ARKit swap.
- **LiDAR occlusion** (`ARWorldTrackingConfiguration.sceneReconstruction`)
  on Pro/Pro Max devices — lets real furniture/walls occlude AR units for a
  much more convincing effect, at the cost of only working on newer
  hardware.
