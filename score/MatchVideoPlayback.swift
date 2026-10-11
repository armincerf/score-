//
//  MatchVideoPlayback.swift
//  score
//
//  The finished match's videos on the detail screen: which one is selected, one AVPlayer per video (made on
//  first use), and each video's upright display size for the inline player's shape.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import os

/// One of a finished match's videos.
nonisolated enum MatchVideoKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case highlights
    case fullMatch

    var id: Self { self }

    /// Title of the video in the section header and the share sheet.
    var title: String {
        switch self {
        case .highlights: return "Highlight Reel"
        case .fullMatch: return "Full Match"
        }
    }

    /// Segment title in the video picker.
    var pickerTitle: String {
        switch self {
        case .highlights: return "Highlights"
        case .fullMatch: return "Full match"
        }
    }

    var systemImage: String {
        switch self {
        case .highlights: return "star.fill"
        case .fullMatch: return "video.fill"
        }
    }
}

@Observable
final class MatchVideoPlayback {
    /// The videos on disk, highlights first.
    let kinds: [MatchVideoKind]

    /// The video in the inline player; switching pauses the one that was showing.
    var selection: MatchVideoKind {
        didSet {
            guard oldValue != selection else { return }
            players[oldValue]?.pause()
        }
    }

    /// Upright display size per video once `loadDisplaySize(for:)` has read it.
    private(set) var displaySizes: [MatchVideoKind: CGSize] = [:]

    @ObservationIgnored private let urls: [MatchVideoKind: URL]
    /// Made on first use and kept for the screen's lifetime, so a video keeps its position across switches.
    @ObservationIgnored private var players: [MatchVideoKind: AVPlayer] = [:]

    init(highlights: URL?, fullMatch: URL?) {
        var urls: [MatchVideoKind: URL] = [:]
        urls[.highlights] = highlights
        urls[.fullMatch] = fullMatch
        self.urls = urls
        kinds = MatchVideoKind.allCases.filter { urls[$0] != nil }
        selection = kinds.first ?? .highlights
    }

    func url(for kind: MatchVideoKind) -> URL? { urls[kind] }

    /// The video's player, created the first time it is asked for; nil when the video is not on disk.
    func player(for kind: MatchVideoKind) -> AVPlayer? {
        if let player = players[kind] { return player }
        guard let url = urls[kind] else { return nil }
        let player = AVPlayer(url: url)
        players[kind] = player
        return player
    }

    /// Reads the video's upright display size once; until then (or if it cannot be read) the player is 16:9.
    func loadDisplaySize(for kind: MatchVideoKind) async {
        guard displaySizes[kind] == nil, let url = urls[kind] else { return }
        guard let size = await InlinePlayerLayout.loadDisplaySize(of: url) else {
            Log.ui.warning("No display size for \(kind.rawValue) video \(url.lastPathComponent)")
            return
        }
        Log.ui.debug("\(kind.rawValue) video displays at \(Int(size.width))x\(Int(size.height))")
        displaySizes[kind] = size
    }
}
