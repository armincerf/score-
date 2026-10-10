//
//  ScoreWatchApp.swift
//  scorewatch Watch App
//
//  Watch app entry point.
//

import SwiftUI

@main
struct ScoreWatchApp: App {
    @State private var session = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
        }
    }
}
