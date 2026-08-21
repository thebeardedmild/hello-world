//
//  PhotoViews.swift
//  Taking a note on a still, and getting from a still back into the model.
//

import SwiftUI
import simd

/// The sheet that appears right after the shutter, and again when a pin is tapped.
struct PhotoNoteEditorView: View {

    @State var photo: PhotoNote
    let imageURL: URL
    var onSave: (PhotoNote) -> Void
    var onDelete: ((PhotoNote) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var tagText: String = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AsyncLocalImage(url: imageURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .listRowInsets(EdgeInsets())
                }

                Section("Note") {
                    TextEditor(text: $photo.note)
                        .frame(minHeight: 96)
                        .focused($noteFocused)
                }

                Section("Tags") {
                    HStack {
                        TextField("Add a tag", text: $tagText)
                            .textInputAutocapitalization(.never)
                            .onSubmit(addTag)
                        Button("Add", action: addTag)
                            .disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !photo.tags.isEmpty {
                        TagCloud(tags: photo.tags) { tag in
                            photo.tags.removeAll { $0 == tag }
                        }
                    }
                }

                Section("Captured") {
                    StatRow(label: "Time", value: PhotoNote.timeFormatter.string(from: photo.capturedAt))
                    if let distance = photo.aimDistance {
                        StatRow(label: "Subject distance", value: String(format: "%.2f m", distance))
                    }
                    if let location = photo.location {
                        StatRow(label: "Position", value: Format.coordinate(location))
                    }
                    if let accuracy = photo.locationHorizontalAccuracy {
                        StatRow(label: "GPS accuracy", value: Format.accuracy(accuracy))
                    }
                }

                if let onDelete {
                    Section {
                        Button("Delete this still", role: .destructive) {
                            onDelete(photo)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Still")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(photo)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { noteFocused = photo.note.isEmpty }
        }
    }

    private func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tag.isEmpty, !photo.tags.contains(tag) else { return }
        photo.tags.append(tag)
        tagText = ""
    }
}

struct TagCloud: View {
    let tags: [String]
    var onRemove: ((String) -> Void)?

    var body: some View {
        // A scrolling row rather than a flow layout: a still rarely carries more
        // than a handful of tags, and this never reflows the form around it.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { chips }
                .padding(.vertical, 2)
        }
    }

    private var chips: some View {
        ForEach(tags, id: \.self) { tag in
            HStack(spacing: 4) {
                Text(tag).font(.caption)
                if onRemove != nil {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .onTapGesture { onRemove?(tag) }
        }
    }
}

/// Full-screen still with the correlation tools: tap the image to drop a 3-D
/// marker, jump the 3-D view to the camera's viewpoint, see what else saw this.
struct PhotoDetailView: View {

    let imageURL: URL
    let cloud: PointCloud?
    /// Called whenever a marker is added, so the project can be written back.
    var onUpdate: ((PhotoNote) -> Void)?
    var onLocate: ((SIMD3<Float>) -> Void)?
    var onMatchViewpoint: (() -> Void)?

    @State private var photo: PhotoNote
    @State private var annotationMode = false

    init(photo: PhotoNote,
         imageURL: URL,
         cloud: PointCloud?,
         onUpdate: ((PhotoNote) -> Void)? = nil,
         onLocate: ((SIMD3<Float>) -> Void)? = nil,
         onMatchViewpoint: (() -> Void)? = nil) {
        _photo = State(initialValue: photo)
        self.imageURL = imageURL
        self.cloud = cloud
        self.onUpdate = onUpdate
        self.onLocate = onLocate
        self.onMatchViewpoint = onMatchViewpoint
    }

    @State private var pendingAnnotation: PhotoAnnotation?
    @State private var annotationText = ""
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    imageWithAnnotations

                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    controls

                    if !photo.note.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Note").font(.caption).foregroundStyle(.secondary)
                            Text(photo.note).font(.body)
                        }
                        .padding(.horizontal)
                    }

                    if !photo.tags.isEmpty {
                        TagCloud(tags: photo.tags).padding(.horizontal)
                    }

                    if !photo.annotations.isEmpty {
                        annotationList
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(photo.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Marker note", isPresented: Binding(get: { pendingAnnotation != nil },
                                                       set: { if !$0 { pendingAnnotation = nil } })) {
                TextField("What is this?", text: $annotationText)
                Button("Add") { commitAnnotation() }
                Button("Cancel", role: .cancel) { pendingAnnotation = nil }
            } message: {
                Text(pendingAnnotationSummary)
            }
        }
    }

    // MARK: - Image

    private var imageWithAnnotations: some View {
        GeometryReader { geometry in
            let displaySize = geometry.size
            ZStack(alignment: .topLeading) {
                AsyncLocalImage(url: imageURL)
                    .frame(width: displaySize.width, height: displaySize.height)

                ForEach(photo.annotations) { annotation in
                    if let point = displayPoint(for: annotation.pixel, in: displaySize) {
                        AnnotationMarker(annotation: annotation)
                            .position(point)
                            .onTapGesture {
                                if let world = annotation.world { onLocate?(world) }
                            }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard annotationMode else { return }
                addAnnotation(atDisplayPoint: location, in: displaySize)
            }
        }
        .aspectRatio(displayAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if annotationMode {
                Text("Tap the photo to drop a marker")
                    .font(.caption2)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                annotationMode.toggle()
                message = annotationMode
                    ? "Markers are matched to the point cloud along the camera ray, so they land on the surface you tapped."
                    : nil
            } label: {
                Label(annotationMode ? "Done marking" : "Add marker",
                      systemImage: annotationMode ? "checkmark" : "mappin.and.ellipse")
            }
            .buttonStyle(.bordered)

            Button {
                onMatchViewpoint?()
                dismiss()
            } label: {
                Label("Show in 3D", systemImage: "cube.transparent")
            }
            .buttonStyle(.bordered)
            .disabled(onMatchViewpoint == nil)
        }
        .padding(.horizontal)
    }

    private var annotationList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Markers").font(.headline).padding(.horizontal)
            ForEach(photo.annotations) { annotation in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: annotation.world == nil ? "mappin.slash" : "mappin.circle.fill")
                        .foregroundStyle(annotation.world == nil ? Color.secondary : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(annotation.text.isEmpty ? "Marker" : annotation.text)
                        if annotation.world != nil, annotation.sigma.isFinite {
                            Text(String(format: "located in the cloud, ±%.0f mm", annotation.sigma * 1000))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("not matched to the cloud — nothing was scanned along that ray")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let world = annotation.world {
                        Button("Locate") { onLocate?(world) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Geometry

    /// The stored image is in sensor orientation; the EXIF tag decides how it is
    /// displayed, so the aspect ratio has to follow the same rule.
    private var isRotated: Bool {
        photo.exifOrientation == 6 || photo.exifOrientation == 8
    }

    private var displayAspect: CGFloat {
        let w = CGFloat(photo.imageWidth), h = CGFloat(photo.imageHeight)
        guard w > 0, h > 0 else { return 4.0 / 3.0 }
        return isRotated ? h / w : w / h
    }

    /// Display point -> pixel in the stored (unrotated) image.
    private func pixel(fromDisplayPoint point: CGPoint, in size: CGSize) -> SIMD2<Float>? {
        guard size.width > 0, size.height > 0 else { return nil }
        let u = Float(point.x / size.width)
        let v = Float(point.y / size.height)
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }

        let width = Float(photo.imageWidth), height = Float(photo.imageHeight)
        switch photo.exifOrientation {
        case 6:   // displayed rotated 90° clockwise
            return SIMD2(v * width, (1 - u) * height)
        case 8:   // rotated 90° counter-clockwise
            return SIMD2((1 - v) * width, u * height)
        case 3:   // 180°
            return SIMD2((1 - u) * width, (1 - v) * height)
        default:  // 1, upright
            return SIMD2(u * width, v * height)
        }
    }

    /// The inverse, for drawing existing markers.
    private func displayPoint(for pixel: SIMD2<Float>, in size: CGSize) -> CGPoint? {
        let width = Float(photo.imageWidth), height = Float(photo.imageHeight)
        guard width > 0, height > 0 else { return nil }
        let px = pixel.x / width, py = pixel.y / height

        let u: Float, v: Float
        switch photo.exifOrientation {
        case 6: u = 1 - py; v = px
        case 8: u = py;     v = 1 - px
        case 3: u = 1 - px; v = 1 - py
        default: u = px;    v = py
        }
        return CGPoint(x: CGFloat(u) * size.width, y: CGFloat(v) * size.height)
    }

    // MARK: - Annotations

    private func addAnnotation(atDisplayPoint point: CGPoint, in size: CGSize) {
        guard let pixel = pixel(fromDisplayPoint: point, in: size) else { return }
        var annotation = PhotoAnnotation(pixel: pixel)
        if let cloud, let pick = PhotoCorrelator.resolve(pixel: pixel, in: photo, cloud: cloud) {
            annotation.world = pick.world
            annotation.sigma = pick.sigma
        }
        annotationText = ""
        pendingAnnotation = annotation
    }

    private var pendingAnnotationSummary: String {
        guard let pending = pendingAnnotation else { return "" }
        guard pending.world != nil else {
            return "Nothing was scanned along that ray, so this marker will stay on the photo only."
        }
        return String(format: "Matched to the cloud, ±%.0f mm.", pending.sigma * 1000)
    }

    private func commitAnnotation() {
        guard var annotation = pendingAnnotation else { return }
        annotation.text = annotationText
        photo.annotations.append(annotation)
        pendingAnnotation = nil
        annotationText = ""
        onUpdate?(photo)
    }
}

private struct AnnotationMarker: View {
    let annotation: PhotoAnnotation

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(annotation.world == nil ? Color.secondary : Theme.accent, lineWidth: 2)
                .background(Circle().fill(Color.black.opacity(0.25)))
                .frame(width: 22, height: 22)
            Circle()
                .fill(annotation.world == nil ? Color.secondary : Theme.accent)
                .frame(width: 5, height: 5)
        }
        .shadow(radius: 2)
    }
}
