//
//  ProjectListView.swift
//  The home screen: past scans, and the button that starts a new one.
//

import SwiftUI
import ARKit

struct ProjectListView: View {

    @EnvironmentObject private var store: ProjectStore
    @State private var showsScanner = false
    @State private var pendingDeletion: Project?

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("GeoScan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsScanner = true
                    } label: {
                        Label("New scan", systemImage: "plus.viewfinder")
                    }
                    .disabled(!ScanController.isSupported)
                }
            }
            .fullScreenCover(isPresented: $showsScanner) {
                NavigationStack { ScanView() }
            }
            .refreshable { store.refresh() }
            .confirmationDialog("Delete this scan?",
                                isPresented: Binding(get: { pendingDeletion != nil },
                                                     set: { if !$0 { pendingDeletion = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let pendingDeletion { store.delete(pendingDeletion) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("The point cloud, stills and measurements will be removed from this device.")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(store.projects) { project in
                NavigationLink {
                    ProjectViewer(project: project)
                } label: {
                    ProjectRow(project: project, store: store)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDeletion = project
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 6) {
                Text("No scans yet").font(.title3.weight(.semibold))
                Text(supportMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if ScanController.isSupported {
                Button {
                    showsScanner = true
                } label: {
                    Label("Start a scan", systemImage: "viewfinder")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            tips
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var supportMessage: String {
        ScanController.isSupported
            ? "Walk a site with the camera pointed at what you want to keep. Take stills as you go and tag them — they stay pinned to the model."
            : "This device has no LiDAR sensor. GeoScan needs an iPhone Pro, iPhone Pro Max or an iPad Pro."
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Hold surfaces 0.5–4 m away", systemImage: "ruler")
            Label("Walk 10 m or more for a true-north fit", systemImage: "location.north.line")
            Label("Move slowly — blurred frames are skipped", systemImage: "hand.raised")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }
}

struct ProjectRow: View {
    let project: Project
    let store: ProjectStore

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(DateFormatter.localizedString(from: project.createdAt,
                                                       dateStyle: .medium, timeStyle: .short))
                    if project.geoSolution.isUsable {
                        Label(Format.accuracy(project.geoSolution.estimatedAbsoluteAccuracy),
                              systemImage: "location.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var thumbnail: some View {
        Group {
            if let first = project.photos.first {
                AsyncLocalImage(url: store.photoURL(first, in: project), contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "cube.transparent")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
