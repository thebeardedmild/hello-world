//
//  GeoScanApp.swift
//

import SwiftUI

@main
struct GeoScanApp: App {

    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
