//
//  Log.swift
//  score
//
//  Central os.Logger instances. Filter in Console.app / Xcode by subsystem "armincerf.score".
//  Use these instead of print(): levels are filterable, debug logs are stripped from release
//  builds' persisted logs, and interpolated values are private by default.
//

import Foundation
import os

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "armincerf.score"

    /// App lifecycle, container setup.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Match flow: scoring, games, watch commands (WatchConnectivityManager).
    static let match = Logger(subsystem: subsystem, category: "match")
    /// Camera capture, recording, export, mock video.
    static let video = Logger(subsystem: subsystem, category: "video")
    /// Speech announcements and audio session.
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// SwiftData event store, undo, preferences.
    static let store = Logger(subsystem: subsystem, category: "store")
    /// SwiftUI views.
    static let ui = Logger(subsystem: subsystem, category: "ui")
    /// FoundationModels match summaries.
    static let ai = Logger(subsystem: subsystem, category: "ai")
}
