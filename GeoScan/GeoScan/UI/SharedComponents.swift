//
//  SharedComponents.swift
//  Small pieces the scan, review and export screens all use.
//

import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.30, green: 0.78, blue: 0.98)
    static let good = Color(red: 0.24, green: 0.82, blue: 0.45)
    static let warn = Color(red: 0.98, green: 0.72, blue: 0.24)
    static let bad = Color(red: 0.94, green: 0.36, blue: 0.34)
    static let panel = Color.black.opacity(0.55)
}

/// The dark rounded panel used for every HUD element.
struct HUDPanel<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

/// Label / value pair used across the statistics panels.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct StatChip: View {
    let symbol: String
    let text: String
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.monospacedDigit().weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.panel, in: Capsule())
    }
}

/// UIActivityViewController, wrapped for the export screen.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Loads a JPEG off the main thread and keeps it around while the view lives.
@MainActor
final class ImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    private var loadedURL: URL?

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        image = nil
        Task.detached(priority: .userInitiated) {
            let loaded = UIImage(contentsOfFile: url.path)
            await MainActor.run { self.image = loaded }
        }
    }
}

struct AsyncLocalImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.18))
                    .overlay(ProgressView())
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { _, newValue in loader.load(newValue) }
    }
}

/// Formatting helpers used in more than one screen.
enum Format {

    static func pointCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fk", Double(count) / 1_000) }
        return "\(count)"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func coordinate(_ g: Geodetic) -> String {
        String(format: "%.6f, %.6f", g.latitude, g.longitude)
    }

    static func accuracy(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        if meters < 10 { return String(format: "±%.1f m", meters) }
        return String(format: "±%.0f m", meters)
    }
}
