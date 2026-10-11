//
//  MatchOverlayExportTests.swift
//  scoreTests
//
//  The match scoreboard on the full video, and the reel cut from the raw segments, proven on exported frames.
//  Three 4 s mock segments recorded back to back (wall clock = video time), the middle one with a forced quarter
//  turn (so it letterboxes into the first one's 1280x720 frame), and five scripted points:
//    1.0 s Alex (1-0)   2.5 s Lucio (1-1)   5.0 s Alex (2-1, in the turned segment)   9.0 s Alex (3-1)   10.5 s Lucio
//  Frames land in REEL_FRAMES_DIR as match-full-*.png and match-reel-*.png.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import score

@Suite("MatchOverlayExport", .serialized)
struct MatchOverlayExportTests {
    private static let landscape = CGSize(width: 1280, height: 720)
    private static let corrections: [VideoRotationCorrection] = [.none, .clockwise90, .none]

    private static let match = ReelScoreboardTimeline(
        playerOneName: "Alex", playerTwoName: "Lucio", games: [],
        currentGamePoints: [(1, 1.0), (2, 2.5), (1, 5.0), (1, 9.0), (2, 10.5)].map {
            PointEvent(player: $0.0, videoTimestamp: $0.1)
        },
        currentGameFirstServer: 1)

    private static let timeline = RecordingTimeline(
        segments: (0..<3).map {
            RecordingSegment(fileReference: "segment-\($0).mov", startOffset: Double($0) * 4, duration: 4)
        })

    /// Three distinct 4 s mock files (each one's clock starts at 0:00).
    private static func segments() async throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<3 {
            let url = ReelFrames.outputDirectory.appendingPathComponent("match-segment-\(index).mov")
            urls.append(try #require(await MockVideoGenerator.generateMockVideo(duration: 4, to: url)))
        }
        return urls
    }

    private static func frame(_ url: URL, at seconds: Double, name: String) async throws -> ReelPixels {
        let image = try await ReelFrames.frame(of: url, at: seconds)
        try ReelFrames.savePNG(image, name: name)
        return ReelPixels(image)
    }

    // MARK: - Full video

    @Test(
        "The full video carries the match board point by point, over turned and letterboxed footage",
        .timeLimit(.minutes(3)))
    func fullVideoCarriesTheMatchBoard() async throws {
        let segments = try await Self.segments()
        let cues = MatchScoreboardTimeline.cues(match: Self.match, recording: Self.timeline, videoDuration: 12)
        let output = ReelFrames.outputDirectory.appendingPathComponent("match-full.mov")
        let result = try await MediaExportService.exportFullVideo(
            segments: segments, corrections: Self.corrections, scoreboard: cues, to: output, quality: .hd720p)
        #expect(abs(result.duration - 12) < 0.1)

        var frames: [Double: ReelPixels] = [:]
        for time in [0.5, 1.5, 2.4, 3.0, 5.5, 6.5, 9.5] {
            frames[time] = try await Self.frame(output, at: time, name: "match-full-\(time)s")
        }
        let size = Self.landscape
        let layout = ReelScoreboardLayout(videoSize: size)
        for (time, frame) in frames {
            #expect(frame.width == 1280 && frame.height == 720)
            let corner = layout.gamesBox(row: 0, in: size).insetCorner(5)
            #expect(ReelPixels.isGold(frame.rgb(at: corner)), "the board is drawn at \(time) s")
        }
        let start = try #require(frames[0.5])
        let lit = try #require(frames[1.5])
        let settled = try #require(frames[2.4])
        let litTwo = try #require(frames[3.0])
        // 0-0, Alex to serve; at 1.5 s Alex's point (1-0) is lit: his cell white, its digit changed
        Self.expectCell(row: 0, in: lit, white: true)
        Self.expectCell(row: 1, in: lit, white: false)
        #expect(start.inkChanges(to: lit, in: layout.pointsCell(row: 0, in: size)) > 20, "0 -> 1")
        // Between points (2.4 s) the board settles: no white cell, still 1-0
        Self.expectCell(row: 0, in: settled, white: false)
        Self.expectCell(row: 1, in: settled, white: false)
        // 2.5 s: Lucio's point lit (1-1), and the serve passes to him after two points
        Self.expectCell(row: 1, in: litTwo, white: true)
        #expect(Self.markerPixels(litTwo, row: 1) > 8 && Self.markerPixels(litTwo, row: 0) == 0)

        // 5.5 s, in the turned segment: letterboxed between black bands, the board in place, Alex's point lit (2-1)
        let turned = try #require(frames[5.5])
        Self.expectCell(row: 0, in: turned, white: true)
        Self.expectCell(row: 0, in: try #require(frames[6.5]), white: false)
        try await Self.expectTurnedAndLetterboxed(turned, source: segments[1])
        // 9.5 s, third segment: the frame is the segment's own (untouched), Alex's point lit (3-1)
        Self.expectCell(row: 0, in: try #require(frames[9.5]), white: true)
        let third = OrientationPixels(try await ReelFrames.frame(of: segments[2], at: 1.5))
        let recall = third.brightRecall(in: OrientationPixels(try await ReelFrames.frame(of: output, at: 9.5))) {
            ($0, $1)
        }
        #expect(recall > 0.85, "third segment untouched, recall \(recall)")
    }

    // MARK: - Reel

    @Test(
        "The reel is cut from the segments: one board, its own, over turned and letterboxed pieces",
        .timeLimit(.minutes(3)))
    func reelHasExactlyOneBoard() async throws {
        let segments = try await Self.segments()
        // A: wall 4.5-7.5 in the turned segment (Alex wins its rally at 5.0); B: wall 7.0-10.0, across the boundary
        // into the third segment (Alex wins its rally at 9.0). The reel takes A's portrait 720x1280 frame, so B's
        // landscape part letterboxes into it, and a board burned into the landscape footage would show inside it
        let highlights = [
            HighlightClip(startTimestamp: 4.5, endTimestamp: 7.5, player: 1, gameNumber: 0),
            HighlightClip(startTimestamp: 7.0, endTimestamp: 10.0, player: 1, gameNumber: 0),
        ]
        let plan = MediaExportService.reelPlan(
            for: highlights, timeline: Self.timeline, segments: segments, corrections: Self.corrections)
        #expect(plan.pieces.count == 3, "A, then B as two pieces")
        let cues = Self.match.cues(for: plan.clips)
        let output = ReelFrames.outputDirectory.appendingPathComponent("match-reel.mov")
        let reel = try await MediaExportService.exportHighlightReel(
            pieces: plan.pieces, to: output, scoreboard: cues, quality: .hd720p)
        #expect(abs(reel.duration - 6) < 0.1)

        let portrait = CGSize(width: 720, height: 1280)
        let layout = ReelScoreboardLayout(videoSize: portrait)
        let panel = layout.panelFrame(in: portrait).insetBy(dx: -2, dy: -2)
        for time in [1.0, 2.5, 3.5, 4.5, 5.5] {
            let frame = try await Self.frame(output, at: time, name: "match-reel-\(time)s")
            #expect(frame.width == 720 && frame.height == 1280, "portrait, from the first piece")
            let ownBoard = frame.count(in: layout.gamesBox(row: 0, in: portrait), where: ReelPixels.isGold)
            #expect(ownBoard > 200, "the reel's own board at \(time) s (\(ownBoard) gold pixels)")
            // Nothing gold anywhere else: a second board (the full video's) would bring its own games boxes
            let whole = frame.count(in: CGRect(origin: .zero, size: portrait), where: ReelPixels.isGold)
            let inPanel = frame.count(in: panel, where: ReelPixels.isGold)
            #expect(whole == inPanel, "\(whole - inPanel) gold pixels outside the reel's panel at \(time) s")
        }
        // B's landscape part (reel 4.5 s) sits in a 720x405 band: black above and below
        let letterboxed = try await Self.frame(output, at: 4.5, name: "match-reel-4.5s")
        let above = letterboxed.meanBrightness(in: CGRect(x: 0, y: 0, width: 720, height: 400))
        let picture = letterboxed.meanBrightness(in: CGRect(x: 0, y: 460, width: 720, height: 360))
        #expect(above < 4 && picture > 20, "band \(above), picture \(picture)")
        // A at reel 1.0 s is the turned segment at 1.5 s, turned clockwise to fill the portrait frame
        let source = OrientationPixels(try await ReelFrames.frame(of: segments[1], at: 1.5))
        let first = OrientationPixels(try await ReelFrames.frame(of: output, at: 1.0))
        let clockwise = source.brightRecall(in: first) { x, y in (719 - y, x) }
        let anticlockwise = source.brightRecall(in: first) { x, y in (y, 1279 - x) }
        #expect(clockwise > 0.85 && anticlockwise < 0.5, "clockwise \(clockwise), anticlockwise \(anticlockwise)")
    }

    @Test("A highlight across a segment boundary becomes two pieces, in order, each with its segment's correction")
    func reelPlanAcrossSegments() throws {
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/segment-\($0).mov") }
        let highlights = [
            HighlightClip(startTimestamp: 7.0, endTimestamp: 10.0, player: 1, gameNumber: 0),
            HighlightClip(startTimestamp: 1.0, endTimestamp: 2.0, player: 2, gameNumber: 0),
            HighlightClip(startTimestamp: 20.0, endTimestamp: 25.0, player: 2, gameNumber: 0),
        ]
        let plan = MediaExportService.reelPlan(
            for: highlights, timeline: Self.timeline, segments: urls, corrections: Self.corrections)
        try #require(plan.pieces.count == 3)
        #expect(plan.pieces.map(\.url) == [urls[1], urls[2], urls[0]])
        #expect(plan.pieces.map(\.correction) == [.clockwise90, .none, .none])
        let ranges = plan.pieces.compactMap(\.timeRange).map { ($0.start.seconds, $0.end.seconds) }
        #expect(ranges.map(\.0) == [3, 0, 1] && ranges.map(\.1) == [4, 2, 2])
        #expect(plan.clips.map(\.reelDuration) == [3, 1], "reel order = marked order")
        #expect(plan.withoutFootage.map(\.startTimestamp) == [20], "after the footage: no piece")
    }

    @Test("The compositor's Core Image transform is the layer transform between bottom-left-origin frames")
    func coreImageTransform() {
        // A quarter turn clockwise of a 1280x720 frame: its top-left corner goes to the top-right of 720x1280
        let geometry = MediaExportService.uprightGeometry(
            naturalSize: Self.landscape, preferredTransform: .identity, correction: .clockwise90)
        let transform = FrameInstruction.coreImageTransform(
            geometry.transform, sourceHeight: 720, renderHeight: geometry.size.height)
        // Core Image's top-left corner is (0, height); top-right of the 720x1280 frame is (720, 1280)
        #expect(CGPoint(x: 0, y: 720).applying(transform) == CGPoint(x: 720, y: 1280))
        // The source's bottom-left corner turns to the frame's top-left, (0, 1280) in Core Image
        #expect(CGPoint.zero.applying(transform) == CGPoint(x: 0, y: 1280))
        // Without a turn the transform is the identity
        let plain = FrameInstruction.coreImageTransform(.identity, sourceHeight: 720, renderHeight: 720)
        #expect(plain == .identity)
    }

    // MARK: - Checks

    /// The points cell of `row` is the white celebration cell, or the dark panel.
    private static func expectCell(
        row: Int, in frame: ReelPixels, white: Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let cell = ReelScoreboardLayout(videoSize: landscape).pointsCell(row: row, in: landscape)
        let median = frame.medianBrightness(in: cell)
        if white {
            #expect(median > 200, "row \(row) lit (median \(median))", sourceLocation: sourceLocation)
        } else {
            #expect(median < 60, "row \(row) not lit (median \(median))", sourceLocation: sourceLocation)
        }
    }

    private static func markerPixels(_ frame: ReelPixels, row: Int) -> Int {
        let layout = ReelScoreboardLayout(videoSize: landscape)
        return frame.count(
            in: layout.serveMarkerSlot(row: row, in: landscape).insetBy(dx: -3, dy: -3), where: ReelPixels.isGold)
    }

    /// The turned segment, 720x1280 upright, scaled by 720/1280 into a 405x720 column at x 437-842: black bands
    /// either side (left of the board's panel), the source turned clockwise inside.
    private static func expectTurnedAndLetterboxed(_ frame: ReelPixels, source: URL) async throws {
        let left = frame.meanBrightness(in: CGRect(x: 0, y: 0, width: 200, height: 500))
        let right = frame.meanBrightness(in: CGRect(x: 1080, y: 0, width: 200, height: 720))
        let column = frame.meanBrightness(in: CGRect(x: 457, y: 20, width: 365, height: 500))
        #expect(left < 4 && right < 4, "bands should be black: left \(left), right \(right)")
        #expect(column > 20, "the column carries the picture (\(column))")
        let original = OrientationPixels(try await ReelFrames.frame(of: source, at: 1.5))
        let exported = OrientationPixels(
            try await ReelFrames.frame(
                of: ReelFrames.outputDirectory
                    .appendingPathComponent("match-full.mov"), at: 5.5))
        let scale = 720.0 / 1280.0
        func placed(_ point: (x: Double, y: Double)) -> (Int, Int) {
            (437 + Int((point.x * scale).rounded(.down)), Int((point.y * scale).rounded(.down)))
        }
        let clockwise = original.brightRecall(in: exported) { x, y in placed((719.5 - Double(y), Double(x) + 0.5)) }
        let anticlockwise = original.brightRecall(in: exported) { x, y in
            placed((Double(y) + 0.5, 1279.5 - Double(x)))
        }
        #expect(clockwise > 0.85, "clockwise recall \(clockwise)")
        #expect(anticlockwise < 0.5, "anticlockwise recall \(anticlockwise)")
    }
}

extension CGRect {
    /// A point just inside the top-left corner.
    fileprivate func insetCorner(_ inset: CGFloat) -> CGPoint {
        CGPoint(x: minX + inset, y: minY + inset)
    }
}
