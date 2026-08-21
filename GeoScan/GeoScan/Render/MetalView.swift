//
//  MetalView.swift
//  The SwiftUI bridge to the Metal renderer, plus the gesture set the reviewer
//  needs (one finger orbits, two fingers pan, pinch dollies, tap measures).
//

import SwiftUI
import MetalKit
import UIKit
import simd

/// Owns the Metal device, the view and the renderer for one screen.
@MainActor
final class RenderHost: ObservableObject {

    let device: MTLDevice
    let view: MTKView
    let renderer: Renderer

    /// Bumped whenever the renderer's matrices change, so overlays re-project.
    @Published private(set) var frameTick: Int = 0
    @Published private(set) var livePointCount: Int = 0

    init?(capacity: Int, mode: Renderer.Mode) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let view = MTKView(frame: .zero, device: device)
        guard let renderer = Renderer(device: device, view: view, capacity: capacity) else { return nil }
        self.device = device
        self.view = view
        self.renderer = renderer
        renderer.mode = mode
        view.delegate = renderer

        // Overlays only need to re-project a handful of times a second; driving
        // SwiftUI at 60 Hz from the render loop is a good way to lose the frame
        // budget to layout.
        var counter = 0
        renderer.onFrame = { [weak self] count in
            counter += 1
            guard counter % 6 == 0 else { return }
            self?.livePointCount = count
            self?.frameTick &+= 1
        }
    }

    var viewSize: CGSize { view.bounds.size }

    func project(_ world: SIMD3<Float>) -> CGPoint? {
        renderer.project(world, viewSize: view.bounds.size)
    }
}

struct MetalViewRepresentable: UIViewRepresentable {

    let host: RenderHost
    /// Enables the orbit/pan/pinch set. Live AR mode leaves it off.
    var interactive: Bool = false
    var onTap: ((CGPoint, CGSize) -> Void)?

    func makeUIView(context: Context) -> MTKView {
        let view = host.view
        view.isUserInteractionEnabled = true
        context.coordinator.attach(to: view, interactive: interactive)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.host = host
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host, onTap: onTap)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var host: RenderHost
        var onTap: ((CGPoint, CGSize) -> Void)?

        private var lastOrbitTranslation: CGPoint = .zero
        private var lastPanTranslation: CGPoint = .zero

        init(host: RenderHost, onTap: ((CGPoint, CGSize) -> Void)?) {
            self.host = host
            self.onTap = onTap
        }

        func attach(to view: MTKView, interactive: Bool) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            view.addGestureRecognizer(tap)
            guard interactive else { return }

            let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
            orbit.maximumNumberOfTouches = 1
            view.addGestureRecognizer(orbit)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)

            tap.require(toFail: orbit)
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            onTap?(gesture.location(in: view), view.bounds.size)
        }

        @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began { lastOrbitTranslation = .zero }
            let translation = gesture.translation(in: view)
            host.renderer.orbitCamera.orbit(deltaX: Float(translation.x - lastOrbitTranslation.x),
                                            deltaY: Float(translation.y - lastOrbitTranslation.y))
            lastOrbitTranslation = translation
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began { lastPanTranslation = .zero }
            let translation = gesture.translation(in: view)
            host.renderer.orbitCamera.pan(deltaX: Float(translation.x - lastPanTranslation.x),
                                          deltaY: Float(translation.y - lastPanTranslation.y),
                                          viewHeight: Float(view.bounds.height))
            lastPanTranslation = translation
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            host.renderer.orbitCamera.dolly(scale: Float(gesture.scale))
            gesture.scale = 1
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
