//
//  MatchVideoPlaybackTests.swift
//  scoreTests
//
//  The match detail screen's videos: which exist, the default selection, one player per video made on first
//  use, switching pauses the video that was showing, and display sizes are read from the files.
//

import AVFoundation
import Foundation
import Testing

@testable import score

@Suite("Match video playback")
struct MatchVideoPlaybackTests {
    private static let highlights = URL(fileURLWithPath: "/tmp/no-such-highlights.mov")
    private static let fullMatch = URL(fileURLWithPath: "/tmp/no-such-full.mov")

    @Test("Only the videos on disk are offered, highlights first and selected")
    func kindsAndDefaultSelection() {
        let both = MatchVideoPlayback(highlights: Self.highlights, fullMatch: Self.fullMatch)
        #expect(both.kinds == [.highlights, .fullMatch])
        #expect(both.selection == .highlights)

        let fullOnly = MatchVideoPlayback(highlights: nil, fullMatch: Self.fullMatch)
        #expect(fullOnly.kinds == [.fullMatch])
        #expect(fullOnly.selection == .fullMatch)

        let none = MatchVideoPlayback(highlights: nil, fullMatch: nil)
        #expect(none.kinds.isEmpty)
        #expect(none.player(for: .highlights) == nil)
    }

    @Test("Each video gets one player, made on first use and reused")
    func playersAreCreatedOnce() throws {
        let playback = MatchVideoPlayback(highlights: Self.highlights, fullMatch: Self.fullMatch)
        let reel = try #require(playback.player(for: .highlights))
        #expect(playback.player(for: .highlights) === reel)
        let full = try #require(playback.player(for: .fullMatch))
        #expect(full !== reel)
        #expect((reel.currentItem?.asset as? AVURLAsset)?.url == Self.highlights)
    }

    @Test("Switching video pauses the one that was playing and leaves the new one alone")
    func switchingPausesThePrevious() throws {
        let playback = MatchVideoPlayback(highlights: Self.highlights, fullMatch: Self.fullMatch)
        let reel = try #require(playback.player(for: .highlights))
        let full = try #require(playback.player(for: .fullMatch))
        reel.rate = 1
        full.rate = 1
        playback.selection = .fullMatch
        #expect(reel.rate == 0)
        #expect(full.rate == 1)
        full.pause()
    }

    @Test("The display size is loaded from the selected file once")
    func loadsDisplaySize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try #require(
            await MockVideoGenerator.generateMockVideo(duration: 1, to: url, size: CGSize(width: 720, height: 1280)))
        let playback = MatchVideoPlayback(highlights: video, fullMatch: nil)
        #expect(playback.displaySizes[.highlights] == nil)
        await playback.loadDisplaySize(for: .highlights)
        #expect(playback.displaySizes[.highlights] == CGSize(width: 720, height: 1280))
        await playback.loadDisplaySize(for: .fullMatch)
        #expect(playback.displaySizes[.fullMatch] == nil)
    }
}
