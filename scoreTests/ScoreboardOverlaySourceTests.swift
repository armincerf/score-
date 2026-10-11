//
//  ScoreboardOverlaySourceTests.swift
//  scoreTests
//
//  The lazy scoreboard source: cue lookup by time, a bounded cache over a full match's worth of states, a miss
//  that renders, a prefetch that saves the next cue's render, and the real (main-actor SwiftUI) renderer.
//

import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Synchronization
import Testing

@testable import score

@Suite("ScoreboardOverlaySource")
struct ScoreboardOverlaySourceTests {
    private static let videoSize = CGSize(width: 1280, height: 720)

    /// `count` distinct states, one second each from 0.
    private static func cues(_ count: Int) -> [ReelScoreboardCue] {
        (0..<count).map { index in
            ReelScoreboardCue(
                timeRange: CMTimeRange(start: time(Double(index)), duration: time(1)),
                state: ReelScoreboardState(
                    playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: index / 100,
                    playerTwoGames: 0, playerOnePoints: index % 100, playerTwoPoints: 0, server: 1, pointWonBy: nil))
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A cheap stand-in for the SwiftUI board: a 4x4 bitmap.
    private static let tinyRenderer: ScoreboardOverlaySource.Renderer = { _, _ in
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }

    @Test("Cues are found by time, including their edges, and gaps have none")
    func lookup() {
        let cues = [
            ReelScoreboardCue(
                timeRange: CMTimeRange(start: Self.time(2), duration: Self.time(1)), state: Self.cues(1)[0].state),
            ReelScoreboardCue(
                timeRange: CMTimeRange(start: Self.time(0), duration: Self.time(1)), state: Self.cues(2)[1].state),
        ]
        let source = ScoreboardOverlaySource(cues: cues, videoSize: Self.videoSize, renderer: Self.tinyRenderer)
        #expect(source.cueIndex(at: Self.time(0)) == 0, "sorted by start")
        #expect(source.cueIndex(at: Self.time(0.999)) == 0)
        #expect(source.cueIndex(at: Self.time(1)) == nil, "a range excludes its end")
        #expect(source.cueIndex(at: Self.time(1.5)) == nil)
        #expect(source.cueIndex(at: Self.time(2)) == 1)
        #expect(source.cueIndex(at: Self.time(3)) == nil)
        #expect(source.cueIndex(at: Self.time(-1)) == nil)
    }

    @Test("Over 400 states the cache never holds more than 16 boards, and each state renders once")
    func cacheStaysBounded() async throws {
        let source = ScoreboardOverlaySource(
            cues: Self.cues(400), videoSize: Self.videoSize, renderer: Self.tinyRenderer)
        var largest = 0
        for second in 0..<400 {
            // Like an export: several frames per cue
            for frame in [0.0, 0.3, 0.6] {
                let board = await source.board(at: Self.time(Double(second) + frame))
                #expect(board != nil)
                largest = max(largest, source.cachedCount)
            }
        }
        await source.waitForRenders()
        #expect(largest <= ScoreboardOverlaySource.cacheCapacity, "largest cache \(largest)")
        #expect(source.cachedCount <= ScoreboardOverlaySource.cacheCapacity)
        #expect(source.renderCount == 400, "every state once: \(source.renderCount) renders")
    }

    @Test("A miss renders; serving a cached board prefetches the next cue's, which then needs no render")
    func missAndPrefetch() async throws {
        let source = ScoreboardOverlaySource(cues: Self.cues(3), videoSize: Self.videoSize, renderer: Self.tinyRenderer)
        guard case .pending = source.boardIfReady(at: Self.time(0.1)) else {
            Issue.record("nothing is rendered before the first request")
            return
        }
        #expect(await source.board(at: Self.time(0.1)) != nil)
        #expect(source.renderCount == 1, "the miss rendered")

        // A second frame of the same cue is a hit, and starts the next cue's render
        guard case .ready(.some) = source.boardIfReady(at: Self.time(0.5)) else {
            Issue.record("the first cue's board should be cached")
            return
        }
        await source.waitForRenders()
        #expect(source.renderCount == 2, "the prefetch rendered cue 1")
        guard case .ready(.some) = source.boardIfReady(at: Self.time(1.2)) else {
            Issue.record("cue 1 should be ready without waiting")
            return
        }
        #expect(source.renderCount == 2, "no render for the prefetched cue")
        #expect(source.boardIfReady(at: Self.time(5)).isEmptyReady, "no cue at 5 s: nothing to draw")
    }

    @Test("Two frames waiting on the same board share one render")
    func concurrentMissesShareARender() async throws {
        let calls = Mutex(0)
        let slowRenderer: ScoreboardOverlaySource.Renderer = { state, layout in
            calls.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return await Self.tinyRenderer(state, layout)
        }
        let source = ScoreboardOverlaySource(cues: Self.cues(1), videoSize: Self.videoSize, renderer: slowRenderer)
        async let first = source.board(at: Self.time(0.1))
        async let second = source.board(at: Self.time(0.2))
        let boards = await [first, second]
        #expect(boards.allSatisfy { $0 != nil })
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("The app's renderer draws the board at the layout's size, placed at the layout's origin")
    func mainActorRenderer() async throws {
        let source = ScoreboardOverlaySource(cues: Self.cues(1), videoSize: Self.videoSize)
        let board = try #require(await source.board(at: Self.time(0.5)))
        let layout = ReelScoreboardLayout(videoSize: Self.videoSize)
        #expect(board.extent.origin == layout.origin)
        #expect(board.extent.size == layout.panelSize)
    }

    @Test("A state that fails to render is not retried, and its frames go without a board")
    func failedRender() async {
        let calls = Mutex(0)
        let failing: ScoreboardOverlaySource.Renderer = { _, _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        let source = ScoreboardOverlaySource(cues: Self.cues(1), videoSize: Self.videoSize, renderer: failing)
        #expect(await source.board(at: Self.time(0.1)) == nil)
        #expect(await source.board(at: Self.time(0.2)) == nil)
        #expect(calls.withLock { $0 } == 1)
    }
}

extension ScoreboardOverlaySource.Lookup {
    fileprivate var isEmptyReady: Bool {
        if case .ready(nil) = self { return true }
        return false
    }
}
