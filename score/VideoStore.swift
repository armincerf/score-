//
//  VideoStore.swift
//  score
//
//  Where match videos live and how the database refers to them.
//
//  Videos are written to Application Support/Videos (never tmp/, which iOS purges). A stored
//  reference (StoredMatch.fullVideoURL / highlightVideoURL, MatchResult.*VideoURL) is the bare
//  file name inside that directory, so the reference survives app updates that move the
//  container. Legacy rows hold absolute file URLs; `resolve` still understands those.
//

import Foundation

nonisolated enum VideoStore {
    enum Kind {
        /// A recording segment; a match has several when recording was interrupted and resumed.
        case rawSegment(index: Int)
        case full
        case highlights
        case mock
    }

    /// Application Support/Videos, created on first use.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "Videos", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileName(matchId: UUID, kind: Kind) -> String {
        let suffix: String
        switch kind {
        case .rawSegment(let index): suffix = "seg\(index)"
        case .full: suffix = "full"
        case .highlights: suffix = "highlights"
        case .mock: suffix = "mock"
        }
        return "\(matchId.uuidString)_\(suffix).mov"
    }

    static func fileURL(matchId: UUID, kind: Kind) -> URL {
        directory.appending(path: fileName(matchId: matchId, kind: kind))
    }

    /// The string to persist for a video file: its name when it lives in the store, else its absolute URL.
    static func storedReference(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return parent == directory.standardizedFileURL.path ? url.lastPathComponent : url.absoluteString
    }

    /// Turns a stored reference back into a file URL (nil for nil/empty). Does not check existence.
    static func resolve(_ reference: String?) -> URL? {
        guard let reference, !reference.isEmpty else { return nil }
        if reference.contains("://") { return URL(string: reference) }  // legacy absolute file URL
        if reference.hasPrefix("/") { return URL(fileURLWithPath: reference) }  // legacy absolute path
        return directory.appending(path: reference)
    }

    static func exists(_ reference: String?) -> Bool {
        guard let url = resolve(reference) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func remove(_ reference: String?) {
        guard let url = resolve(reference) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every file in the store that belongs to `matchId` (segments, exports, mock video).
    static func removeAll(matchId: UUID) {
        let prefix = matchId.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
