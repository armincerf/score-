//
//  ReelExportTests.swift
//  scoreTests
//
//  End-to-end proof that the real highlight reel export carries the broadcast scoreboard: a fabricated match is
//  turned into cues by ReelScoreboardTimeline, rendered by MediaExportService.scoreboardOverlays, burned into a
//  reel cut from a synthetic video by MediaExportService.exportHighlightReel, and frames read back out of the reel
//  are checked pixel by pixel. The frames land next to ReelOverlayTests' (see `ReelFrames.outputDirectory`) as
//  scoreboard-reel-*.png and board-1080p.png / board-2160p.png so a person can look at them.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import score

@Suite("ReelExport", .serialized)
struct ReelExportTests {
    private static let videoSize = CGSize(width: 1280, height: 720)

    // MARK: - The fabricated match

    /// Wall clock = source video time (one segment recorded from 0).
    /// Game 1, player one serves first: ten quick points to 7-3 by 1.0 s, 8-3 at 1.5 s, then 9-3, 10-3, 11-3 at
    /// 4.6-4.8 s. Game 2 (in progress), player two serves first: 0-1 at 5.0 s, 0-2 at 5.5 s, 1-2 at 6.0 s.
    private static let match: ReelScoreboardTimeline = {
        func points(_ scored: [(player: Int, at: Double)]) -> [PointEvent] {
            scored.map { PointEvent(player: $0.player, videoTimestamp: $0.at) }
        }
        let quick = [1, 2, 1, 1, 2, 1, 1, 2, 1, 1].enumerated().map { (player: $1, at: 0.1 * Double($0 + 1)) }
        let gameOne = GameResult(
            playerOneScore: 11, playerTwoScore: 3, winner: 1,
            points: points(quick + [(1, 1.5), (1, 4.6), (1, 4.7), (1, 4.8)]), firstServer: 1)
        return ReelScoreboardTimeline(
            playerOneName: "Alex", playerTwoName: "Lucio", games: [gameOne],
            currentGamePoints: points([(2, 5.0), (2, 5.5), (1, 6.0)]), currentGameFirstServer: 2)
    }()

    /// Clip A: game 1 from 8-3 (1.5 s) for 3 s, player one wins the rally -> reel 0-3 s, row lit from 1.8 s.
    /// Clip B: game 2 from 1-2 (6.0 s) for 4 s, player two wins the rally -> reel 3-7 s, row lit from 5.8 s.
    private static let clips = [
        HighlightClip(startTimestamp: 1.5, endTimestamp: 4.5, player: 1, gameNumber: 0),
        HighlightClip(startTimestamp: 6.0, endTimestamp: 10.0, player: 2, gameNumber: 1),
    ]

    private struct Export {
        let source: URL
        let reel: URL
        let cues: [ReelScoreboardCue]
    }

    /// Exports the reel the way WatchConnectivityManager does: timeline -> rendered overlays -> export.
    private static func exportReel() async throws -> Export {
        let directory = ReelFrames.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("scoreboard-source.mov")
        let reelURL = directory.appendingPathComponent("scoreboard-reel.mov")
        try? FileManager.default.removeItem(at: sourceURL)
        let source = try #require(await MockVideoGenerator.generateMockVideo(duration: 12, to: sourceURL))

        let infos = clips.map { clip in
            MediaExportService.HighlightClipInfo(
                startTimestamp: clip.startTimestamp, endTimestamp: clip.endTimestamp, player: clip.player,
                gameNumber: clip.gameNumber)
        }
        let cues = match.cues(for: zip(clips, infos).map { ReelClip(highlight: $0, reelDuration: $1.duration) })
        let overlays = try await MediaExportService.scoreboardOverlays(cues, forReelFrom: source)
        #expect(overlays.count == cues.count)
        let result = try await MediaExportService.exportHighlightReel(
            from: source, to: reelURL, clips: infos, scoreboard: overlays, quality: .hd720p)
        return Export(source: source, reel: result.outputURL, cues: cues)
    }

    // MARK: - Regions of the board

    private static let layout = ReelScoreboardLayout(videoSize: videoSize)

    /// The empty stretch of a row between the name and the serve marker: only the panel (or the row highlight).
    private static func clearArea(row: Int) -> CGRect {
        let rowRect = layout.rowFrame(row, in: videoSize)
        let left = rowRect.minX + rowRect.width * 0.45
        let right = layout.serveMarkerSlot(row: row, in: videoSize).minX - 6 * layout.unit
        return CGRect(
            x: left, y: rowRect.minY + rowRect.height * 0.2, width: right - left, height: rowRect.height * 0.6)
    }

    private static func goldMarkerPixels(_ frame: ReelPixels, row: Int) -> Int {
        frame.count(
            in: layout.serveMarkerSlot(row: row, in: videoSize).insetBy(dx: -3, dy: -3), where: ReelPixels.isGold)
    }

    // MARK: - Tests

    @Test(
        "The exported reel shows each clip's score, server and celebration from the timeline", .timeLimit(.minutes(3)))
    func scoreboardIsBurnedIntoTheReel() async throws {
        let export = try await Self.exportReel()
        #expect(export.cues.count == 4, "two clips, both long enough for a celebration")
        let reelDuration = try await AVURLAsset(url: export.reel).load(.duration).seconds
        #expect(abs(reelDuration - 7) < 0.1, "3 s + 4 s of clips, got \(reelDuration)")

        var frames: [Double: ReelPixels] = [:]
        for time in [1.0, 2.5, 4.0, 6.5] {
            let image = try await ReelFrames.frame(of: export.reel, at: time)
            try ReelFrames.savePNG(image, name: "scoreboard-reel-\(time)s")
            frames[time] = ReelPixels(image)
        }
        let clipAStart = try #require(frames[1.0])
        let clipALit = try #require(frames[2.5])
        let clipBStart = try #require(frames[4.0])
        let clipBLit = try #require(frames[6.5])
        let size = Self.videoSize
        let layout = Self.layout
        #expect(clipAStart.width == Int(size.width) && clipAStart.height == Int(size.height))

        // Clip A at 8-3, Lucio to serve: gold games boxes, both chips, the serve marker on row 2 only
        for row in 0...1 {
            #expect(ReelPixels.isGold(clipAStart.rgb(at: layout.gamesBox(row: row, in: size).insetCorner(5))))
        }
        let chipOne = clipAStart.rgb(at: layout.chip(row: 0, in: size).center())
        #expect(chipOne.b > 170 && chipOne.r < 120, "player one chip should be blue, got \(chipOne)")
        let chipTwo = clipAStart.rgb(at: layout.chip(row: 1, in: size).center())
        #expect(chipTwo.r > 170 && chipTwo.b < 120, "player two chip should be red, got \(chipTwo)")
        #expect(Self.goldMarkerPixels(clipAStart, row: 1) > 8 && Self.goldMarkerPixels(clipAStart, row: 0) == 0)

        // Clip A's last 1.2 s: Alex's row lit (9-3), Alex to serve
        Self.expectLit(row: 0, in: clipALit, comparedWith: clipAStart)
        #expect(Self.goldMarkerPixels(clipALit, row: 0) > 8 && Self.goldMarkerPixels(clipALit, row: 1) == 0)

        // Clip B at 1-0 in games and 1-2: games digit and both points cells change, nothing lit, Alex to serve
        #expect(clipBStart.meanDifference(to: clipAStart, in: layout.gamesBox(row: 0, in: size)) > 4, "games 0 -> 1")
        #expect(clipBStart.meanDifference(to: clipAStart, in: layout.gamesBox(row: 1, in: size)) < 3, "games 0 -> 0")
        #expect(clipBStart.meanDifference(to: clipAStart, in: layout.pointsCell(row: 0, in: size)) > 4, "8 -> 1")
        #expect(clipBStart.meanDifference(to: clipAStart, in: layout.pointsCell(row: 1, in: size)) > 4, "3 -> 2")
        for row in 0...1 {
            let change =
                clipBStart.meanBrightness(in: Self.clearArea(row: row))
                - clipAStart.meanBrightness(in: Self.clearArea(row: row))
            #expect(abs(change) < 6, "row \(row) should not be lit at clip B's start (change \(change))")
        }
        #expect(Self.goldMarkerPixels(clipBStart, row: 0) > 8 && Self.goldMarkerPixels(clipBStart, row: 1) == 0)

        // Clip B's last 1.2 s: Lucio's row lit (1-3), Lucio to serve
        Self.expectLit(row: 1, in: clipBLit, comparedWith: clipBStart)
        #expect(Self.goldMarkerPixels(clipBLit, row: 1) > 8 && Self.goldMarkerPixels(clipBLit, row: 0) == 0)

        try await Self.expectCutFromSource(clipBStart, source: export.source)
    }

    @Test("The board scales with the video height at 1080p and 4K", arguments: [1080, 2160])
    func boardScalesWithHeight(height: Int) throws {
        let videoSize = CGSize(width: height * 16 / 9, height: height)
        let layout = ReelScoreboardLayout(videoSize: videoSize)
        let reference = ReelScoreboardLayout(videoSize: Self.videoSize)
        let scale = CGFloat(height) / 720
        #expect(layout.panelSize.width == reference.panelSize.width * scale)
        #expect(abs(layout.panelSize.height - reference.panelSize.height * scale) <= 1, "separator rounds to a pixel")
        #expect(layout.origin == CGPoint(x: reference.margin * scale, y: reference.margin * scale))

        let state = ReelScoreboardState(
            playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 2, playerTwoGames: 1, playerOnePoints: 10,
            playerTwoPoints: 9, server: 2, pointWonBy: nil)
        let range = CMTimeRange(start: .zero, duration: ReelFrames.seconds(1))
        let overlays = MediaExportService.scoreboardOverlays(
            [ReelScoreboardCue(timeRange: range, state: state), ReelScoreboardCue(timeRange: range, state: state)],
            videoSize: videoSize)
        try #require(overlays.count == 2)
        #expect(overlays[0].image === overlays[1].image, "identical states share one bitmap")
        #expect(overlays[0].origin == layout.origin)

        let image = overlays[0].image
        #expect(CGFloat(image.width) == layout.panelSize.width && CGFloat(image.height) == layout.panelSize.height)
        try ReelFrames.savePNG(image, name: "board-\(height)p")
        let pixels = ReelPixels(image)
        let gamesCorner = CGPoint(
            x: layout.panelWidth - layout.pointsWidth - layout.gamesBoxWidth + 5 * layout.unit, y: 5 * layout.unit)
        #expect(ReelPixels.isGold(pixels.rgb(at: gamesCorner)), "games box should be gold at \(height)p")
    }

    @Test("In portrait footage the board scales with the width, so it fits across the frame")
    func boardFitsPortrait() {
        let portrait = CGSize(width: 1080, height: 1920)
        let layout = ReelScoreboardLayout(videoSize: portrait)
        #expect(layout == ReelScoreboardLayout(videoSize: CGSize(width: 1920, height: 1080)))
        #expect(layout.panelFrame(in: portrait).maxX + layout.margin <= portrait.width)
    }

    // MARK: - Checks

    /// The row's clear area is clearly brighter (the white highlight) and the other row's is not.
    private static func expectLit(
        row: Int, in lit: ReelPixels, comparedWith before: ReelPixels,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let rise = lit.meanBrightness(in: clearArea(row: row)) - before.meanBrightness(in: clearArea(row: row))
        #expect(rise > 15, "row \(row) should light up (brightness +\(rise))", sourceLocation: sourceLocation)
        let other = 1 - row
        let otherChange =
            lit.meanBrightness(in: clearArea(row: other)) - before.meanBrightness(in: clearArea(row: other))
        #expect(abs(otherChange) < 6, "row \(other) should stay dark (\(otherChange))", sourceLocation: sourceLocation)
    }

    /// Reel 4.0 s is 1 s into clip B, which starts at 6.0 s of the source: the frame outside the board is the
    /// source's frame at 7.0 s (its clock reads 0:07), not the one at 4.0 s.
    private static func expectCutFromSource(_ reelFrame: ReelPixels, source: URL) async throws {
        let matching = ReelPixels(try await ReelFrames.frame(of: source, at: 7.0))
        let other = ReelPixels(try await ReelFrames.frame(of: source, at: 4.0))
        let clock = CGRect(x: 440, y: 300, width: 400, height: 120)
        let toMatching = reelFrame.meanDifference(to: matching, in: clock)
        let toOther = reelFrame.meanDifference(to: other, in: clock)
        #expect(toMatching < 6 && toOther > toMatching + 5, "clock region: \(toMatching) vs 7 s, \(toOther) vs 4 s")
        #expect(reelFrame.distance(to: matching, at: CGPoint(x: videoSize.width - 40, y: 40)) < 40)
    }
}

/// The reel export from other sources: without cues (today's plain reel), a recording with sound (as every camera
/// recording has) and a source whose frames are stored rotated.
@Suite("ReelExportSources", .serialized)
struct ReelExportSourceTests {
    private static let directory = ReelFrames.outputDirectory

    /// One 4 s clip from 1 s, player one wins the rally: two cues (score, then the lit row).
    private static func cues(
        for source: URL
    ) async throws -> (clip: MediaExportService.HighlightClipInfo, overlays: [OverlayCue]) {
        let highlight = HighlightClip(startTimestamp: 1, endTimestamp: 5, player: 1, gameNumber: 0)
        let timeline = ReelScoreboardTimeline(
            playerOneName: "Alex", playerTwoName: "Lucio", games: [],
            currentGamePoints: [PointEvent(player: 2, videoTimestamp: 0.5)], currentGameFirstServer: 1)
        let cues = timeline.cues(for: [ReelClip(highlight: highlight, reelDuration: 4)])
        let overlays = try await MediaExportService.scoreboardOverlays(cues, forReelFrom: source)
        let clip = MediaExportService.HighlightClipInfo(startTimestamp: 1, endTimestamp: 5, player: 1, gameNumber: 0)
        return (clip, overlays)
    }

    @Test("Without cues a silent source exports the plain reel, as before the scoreboard", .timeLimit(.minutes(3)))
    func plainReelWithoutCues() async throws {
        let source = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 6, to: Self.directory.appendingPathComponent("scoreboard-plain-source.mov")))
        let plan = try await Self.cues(for: source)
        let reel = try await MediaExportService.exportHighlightReel(
            from: source, to: Self.directory.appendingPathComponent("scoreboard-plain-reel.mov"), clips: [plan.clip],
            scoreboard: [], quality: .hd720p)

        #expect(abs(reel.duration - 4) < 0.05)
        let frame = try await ReelFrames.frame(of: reel.outputURL, at: 1)
        let size = CGSize(width: frame.width, height: frame.height)
        let box = ReelScoreboardLayout(videoSize: size).gamesBox(row: 0, in: size)
        #expect(ReelPixels(frame).count(in: box, where: ReelPixels.isGold) == 0, "no board without cues")
    }

    @Test("A source with sound keeps its sound under the scoreboard", .timeLimit(.minutes(3)))
    func soundIsKept() async throws {
        let silent = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 6, to: Self.directory.appendingPathComponent("scoreboard-silent.mov")))
        let source = try await Self.combine(
            video: silent, withTone: true, transform: .identity,
            to: Self.directory.appendingPathComponent("scoreboard-sound-source.mov"))
        let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        try #require(!sourceAudio.isEmpty, "the fixture needs an audio track")

        let plan = try await Self.cues(for: source)
        let reelURL = Self.directory.appendingPathComponent("scoreboard-sound-reel.mov")
        let reel = try await MediaExportService.exportHighlightReel(
            from: source, to: reelURL, clips: [plan.clip], scoreboard: plan.overlays, quality: .hd720p)

        let reelAsset = AVURLAsset(url: reel.outputURL)
        #expect(try await !reelAsset.loadTracks(withMediaType: .audio).isEmpty, "the reel keeps the sound")
        let frame = try await ReelFrames.frame(of: reel.outputURL, at: 1)
        try ReelFrames.savePNG(frame, name: "scoreboard-sound-reel-1.0s")
        let layout = ReelScoreboardLayout(videoSize: CGSize(width: frame.width, height: frame.height))
        let size = CGSize(width: frame.width, height: frame.height)
        let corner = layout.gamesBox(row: 0, in: size).insetCorner(5)
        #expect(ReelPixels.isGold(ReelPixels(frame).rgb(at: corner)), "the board is drawn")
    }

    @Test("A source stored rotated keeps the plain reel, upright, instead of a sideways one", .timeLimit(.minutes(3)))
    func rotatedSourceSkipsTheBoard() async throws {
        let landscape = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 6, to: Self.directory.appendingPathComponent("scoreboard-unrotated.mov")))
        // Stored 1280x720, displayed rotated 90 degrees clockwise (720x1280), like a portrait camera file
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)
        let source = try await Self.combine(
            video: landscape, withTone: false, transform: rotation,
            to: Self.directory.appendingPathComponent("scoreboard-rotated-source.mov"))
        let sourceAsset = AVURLAsset(url: source)
        let stored = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        try #require(!(try await stored.load(.preferredTransform)).isIdentity, "the fixture must be stored rotated")

        let plan = try await Self.cues(for: source)
        #expect(plan.overlays.count == 2, "the board is rendered for the upright 720x1280 frame")
        let reelURL = Self.directory.appendingPathComponent("scoreboard-rotated-reel.mov")
        let reel = try await MediaExportService.exportHighlightReel(
            from: source, to: reelURL, clips: [plan.clip], scoreboard: plan.overlays, quality: .hd720p)

        let frame = try await ReelFrames.frame(of: reel.outputURL, at: 1)
        try ReelFrames.savePNG(frame, name: "scoreboard-rotated-reel-1.0s")
        #expect(frame.width < frame.height, "upright portrait, got \(frame.width)x\(frame.height)")
        let size = CGSize(width: frame.width, height: frame.height)
        let layout = ReelScoreboardLayout(videoSize: size)
        let pixels = ReelPixels(frame)
        let goldInBox = pixels.count(in: layout.gamesBox(row: 0, in: size), where: ReelPixels.isGold)
        #expect(goldInBox == 0, "no board over a source that is not stored upright")
    }

    // MARK: - Fixtures

    /// `video` re-exported with `transform` as its stored orientation and, optionally, a 440 Hz tone as sound
    /// (encoded by the 1280x720 preset, AAC like a camera file; passthrough keeps the stored rotation).
    private static func combine(
        video: URL, withTone: Bool, transform: CGAffineTransform, to outputURL: URL
    ) async throws -> URL {
        let videoAsset = AVURLAsset(url: video)
        let duration = try await videoAsset.load(.duration)
        let composition = AVMutableComposition()
        let sourceVideo = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let videoTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = transform
        // Held for the whole export: a track whose asset has been released cannot be inserted (AVError -11800 / -12780)
        let toneAsset = AVURLAsset(url: outputURL.deletingPathExtension().appendingPathExtension("caf"))
        if withTone {
            try makeTone(seconds: duration.seconds + 1, at: toneAsset.url)  // longer than the video: the range fits
            let tone = try #require(try await toneAsset.loadTracks(withMediaType: .audio).first)
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try audioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: tone, at: .zero)
        }
        try? FileManager.default.removeItem(at: outputURL)
        let preset = withTone ? AVAssetExportPreset1280x720 : AVAssetExportPresetPassthrough
        let session = try #require(AVAssetExportSession(asset: composition, presetName: preset))
        try await session.export(to: outputURL, as: .mov)
        extendLifetime(toneAsset)
        return outputURL
    }

    private static func makeTone(seconds: Double, at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = 0.2 * sin(2 * .pi * 440 * Float(index) / 44_100)
        }
        try file.write(from: buffer)
        file.close()  // writes the header now; until then a reader may see an incomplete file
    }
}

extension CGRect {
    fileprivate func center() -> CGPoint {
        CGPoint(x: midX, y: midY)
    }

    /// A point just inside the top-left corner.
    fileprivate func insetCorner(_ inset: CGFloat) -> CGPoint {
        CGPoint(x: minX + inset, y: minY + inset)
    }
}

// MARK: - A source that still needs a correction

extension ReelExportSourceTests {
    /// The raw camera segment kept as the full video when the full export fails carries the detector's correction:
    /// the reel must turn it (and leave the board out, which the Core Image composition cannot turn).
    @Test(
        "A reel cut with a correction comes out turned, without the board", .timeLimit(.minutes(3)),
        arguments: [false, true])
    func correctedSourceIsTurned(withCues: Bool) async throws {
        let source = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 6, to: Self.directory.appendingPathComponent("scoreboard-corrected-source.mov")))
        let plan = try await Self.cues(for: source)
        let name = withCues ? "scoreboard-corrected-cues-reel" : "scoreboard-corrected-reel"
        let reel = try await MediaExportService.exportHighlightReel(
            from: source, to: Self.directory.appendingPathComponent("\(name).mov"), clips: [plan.clip],
            scoreboard: withCues ? plan.overlays : [], correction: .upsideDown180, quality: .hd720p)
        #expect(abs(reel.duration - 4) < 0.05)

        // Reel 1 s is 1 s into the clip, which starts at 1 s of the source
        let image = try await ReelFrames.frame(of: reel.outputURL, at: 1)
        try ReelFrames.savePNG(image, name: "\(name)-1.0s")
        #expect(image.width == 1280 && image.height == 720)
        let original = OrientationPixels(try await ReelFrames.frame(of: source, at: 2))
        let exported = OrientationPixels(image)
        let turned = original.brightRecall(in: exported) { x, y in (1279 - x, 719 - y) }
        let unturned = original.brightRecall(in: exported) { x, y in (x, y) }
        #expect(turned > 0.85, "half-turn recall \(turned)")
        #expect(unturned < 0.5, "unturned recall \(unturned)")

        let size = CGSize(width: image.width, height: image.height)
        let box = ReelScoreboardLayout(videoSize: size).gamesBox(row: 0, in: size)
        let gold = ReelPixels(image).count(in: box, where: ReelPixels.isGold)
        #expect(gold == 0, "no board over a turned reel")
        try OrientationFrames.note(
            "\(name): \(image.width)x\(image.height), half-turn recall \(turned), unturned \(unturned), gold \(gold)",
            file: "\(name).txt")
    }
}
