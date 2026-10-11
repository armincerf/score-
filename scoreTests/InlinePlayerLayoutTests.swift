//
//  InlinePlayerLayoutTests.swift
//  scoreTests
//
//  The inline match video player is shaped like its video: landscape fills the width, portrait is capped in
//  height, unknown sizes get 16:9; display sizes come from the track's natural size and preferred transform.
//

import CoreGraphics
import Foundation
import Testing

@testable import score

@Suite("Inline player layout")
struct InlinePlayerLayoutTests {
    private static func isClose(_ size: CGSize, _ width: CGFloat, _ height: CGFloat) -> Bool {
        abs(size.width - width) < 0.01 && abs(size.height - height) < 0.01
    }

    @Test("A 16:9 video fills the width at its own ratio")
    func landscapeFillsWidth() {
        let size = InlinePlayerLayout.playerSize(for: CGSize(width: 1280, height: 720), availableWidth: 370)
        #expect(Self.isClose(size, 370, 208.125))
    }

    @Test("A 9:16 video is capped at the maximum height and keeps its ratio")
    func portraitIsCappedInHeight() {
        let size = InlinePlayerLayout.playerSize(for: CGSize(width: 720, height: 1280), availableWidth: 370)
        #expect(Self.isClose(size, 236.25, 420))
        #expect(InlinePlayerLayout.maxHeight == 420)
    }

    @Test("A square video is a square at the width")
    func squareFillsWidth() {
        let size = InlinePlayerLayout.playerSize(for: CGSize(width: 1080, height: 1080), availableWidth: 370)
        #expect(Self.isClose(size, 370, 370))
    }

    @Test("A square video wider than the maximum height is capped too")
    func wideSquareIsCapped() {
        let size = InlinePlayerLayout.playerSize(for: CGSize(width: 1080, height: 1080), availableWidth: 600)
        #expect(Self.isClose(size, 420, 420))
    }

    @Test(
        "Unknown or empty video sizes fall back to 16:9 at the width",
        arguments: [
            nil, CGSize.zero, CGSize(width: 1280, height: 0), CGSize(width: 0, height: 720),
        ] as [CGSize?])
    func unknownSizeIsSixteenByNine(videoSize: CGSize?) {
        let size = InlinePlayerLayout.playerSize(for: videoSize, availableWidth: 370)
        #expect(Self.isClose(size, 370, 208.125))
    }

    @Test("No width (before the first layout pass) gives no frame")
    func zeroWidth() {
        #expect(InlinePlayerLayout.playerSize(for: CGSize(width: 1280, height: 720), availableWidth: 0) == .zero)
        #expect(InlinePlayerLayout.playerSize(for: nil, availableWidth: -10) == .zero)
        #expect(
            InlinePlayerLayout.playerSize(for: CGSize(width: 720, height: 1280), availableWidth: 370, maxHeight: 0)
                == .zero)
    }

    @Test("A short screen caps the height: a 16:9 video in landscape fits on screen, narrower than the card")
    func landscapeViewportCapsHeight() {
        // iPhone 17 Pro in landscape: 304 pt of scroll view, a card 686 pt wide
        let cap = InlinePlayerLayout.maxHeight(forViewportHeight: 304)
        #expect(abs(cap - 243.2) < 0.01)
        let size = InlinePlayerLayout.playerSize(
            for: CGSize(width: 1280, height: 720), availableWidth: 686, maxHeight: cap)
        #expect(Self.isClose(size, 432.355_555, 243.2))
        #expect(size.height < 304)
    }

    @Test(
        "A tall screen, or one not measured yet, keeps the 420 pt cap",
        arguments: [724, 1000, 0, -1] as [CGFloat])
    func tallOrUnmeasuredViewportKeepsCap(viewportHeight: CGFloat) {
        #expect(InlinePlayerLayout.maxHeight(forViewportHeight: viewportHeight) == InlinePlayerLayout.maxHeight)
    }

    @Test("A track stored landscape with a quarter-turn transform is shown portrait")
    func rotatedTrackIsPortrait() throws {
        let natural = CGSize(width: 1920, height: 1080)
        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let display = try #require(
            InlinePlayerLayout.displaySize(naturalSize: natural, preferredTransform: quarterTurn))
        #expect(Self.isClose(display, 1080, 1920))
        let size = InlinePlayerLayout.playerSize(for: display, availableWidth: 370)
        #expect(Self.isClose(size, 236.25, 420))
    }

    @Test("A track stored upright keeps its natural size; an empty track has no display size")
    func uprightAndEmptyTracks() {
        let natural = CGSize(width: 1280, height: 720)
        #expect(InlinePlayerLayout.displaySize(naturalSize: natural, preferredTransform: .identity) == natural)
        #expect(InlinePlayerLayout.displaySize(naturalSize: .zero, preferredTransform: .identity) == nil)
    }

    @Test("The display size is read from the file: a portrait mock recording loads as 720x1280")
    func loadsPortraitMockVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inline-layout-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try #require(
            await MockVideoGenerator.generateMockVideo(duration: 1, to: url, size: CGSize(width: 720, height: 1280)))
        let display = try #require(await InlinePlayerLayout.loadDisplaySize(of: video))
        #expect(display == CGSize(width: 720, height: 1280))
    }

    @Test("A file without a video track has no display size")
    func missingFileHasNoSize() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID()).mov")
        #expect(await InlinePlayerLayout.loadDisplaySize(of: url) == nil)
    }
}
