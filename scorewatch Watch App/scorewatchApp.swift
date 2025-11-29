//
//  scorewatchApp.swift
//  scorewatch Watch App
//
//  Created by Alex Davis on 29/11/2025.
//

import SwiftUI

@main
struct scorewatch_Watch_AppApp: App {
    @StateObject private var session = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
    }
}
