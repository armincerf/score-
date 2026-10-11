//
//  ExportTimingTests.swift
//  scoreTests
//
//  How long the full-video export of a 60 s 720p mock recording takes on this runtime, written to
//  REEL_FRAMES_DIR/export-timing.txt: through AVFoundation's default compositor (a layer instruction, as the
//  export did before FrameCompositor), through FrameCompositor without a board and with a match's board. The three
//  run in turn, three times, so a busy machine slows them alike. A measurement, not a gate: the limit only catches a hang.
//  Opt-in (nine minute-long exports would slow every other suite's time limits):
//    TEST_RUNNER_EXPORT_TIMING=1 make test T=scoreTests/ExportTimingTests
//

import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing

@testable import score

@Suite(
    "ExportTiming", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["EXPORT_TIMING"] != nil, "set TEST_RUNNER_EXPORT_TIMING=1"))
struct ExportTimingTests {
    @Test("Full export of a 60 s 720p mock is timed on both compositors", .timeLimit(.minutes(5)))
    func timeSixtySecondFullExport() async throws {
        let directory = ReelFrames.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 60, to: directory.appendingPathComponent("timing-source-60s.mov")))
        let output = directory.appendingPathComponent("timing-full-60s.mov")
        // A point every 4 s: 30 points, 60 board states
        let points = (0..<15).map {
            PointEvent(player: $0.isMultiple(of: 3) ? 2 : 1, videoTimestamp: Double($0) * 4 + 2)
        }
        let match = ReelScoreboardTimeline(
            playerOneName: "Alex", playerTwoName: "Lucio", games: [], currentGamePoints: points,
            currentGameFirstServer: 1)
        let recording = RecordingTimeline(segments: [
            RecordingSegment(fileReference: "timing", startOffset: 0, duration: 60)
        ])
        let cues = MatchScoreboardTimeline.cues(match: match, recording: recording, videoDuration: 60)

        var lines: [String] = []
        let report = directory.appendingPathComponent("export-timing.txt")
        func note(_ line: String) throws {
            lines.append(line)
            try (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        for round in 1...3 {
            let reference = try await Self.timed { try await Self.exportWithDefaultCompositor(source, to: output) }
            try note("round \(round): default compositor \(reference) s")
            let plain = try await Self.timed {
                _ = try await MediaExportService.exportFullVideo(segments: [source], to: output, quality: .hd720p)
            }
            try note("round \(round): FrameCompositor \(plain) s")
            let board = try await Self.timed {
                _ = try await MediaExportService.exportFullVideo(
                    segments: [source], scoreboard: cues, to: output, quality: .hd720p)
            }
            try note(
                String(
                    format:
                        "round %d: default compositor %.2f s, FrameCompositor %.2f s (%.2fx), with board %.2f s (%.2fx)",
                    round, reference, plain, plain / reference, board, board / reference))
        }
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 60) < 0.1)
    }

    private static func timed(_ work: () async throws -> Void) async throws -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// The export as it was before FrameCompositor: one layer instruction (identity: the mock is stored upright)
    /// rendered by AVFoundation's default compositor at 30 fps.
    private static func exportWithDefaultCompositor(_ source: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(.identity, at: .zero)
        let instruction = AVVideoCompositionInstruction(
            configuration: AVVideoCompositionInstruction.Configuration(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: .zero, duration: duration)))
        let videoComposition = AVVideoComposition(
            configuration: AVVideoComposition.Configuration(
                frameDuration: CMTime(value: 1, timescale: 30), instructions: [instruction],
                renderSize: CGSize(width: 1280, height: 720)))
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720))
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: output, as: .mov)
    }
}
