//
//  Log.swift
//  scorewatch Watch App
//
//  Central os.Logger instances for the watch app. Use instead of print().
//

import Foundation
import os

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "armincerf.score.watchkitapp"

    /// WatchConnectivity session and commands.
    static let session = Logger(subsystem: subsystem, category: "session")
    /// SwiftUI views.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
