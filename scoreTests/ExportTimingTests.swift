//
//  ExportTimingTests.swift
//  scoreTests
//
//  How long the full-video export of a 60 s 720p mock recording takes on this runtime, written to
//  REEL_FRAMES_DIR/export-timing.txt. A measurement, not a gate: the limit only catches a hang.
//

import AVFoundation
import Foundation
import Testing

@testable import score

@Suite("ExportTiming", .serialized)
struct ExportTimingTests {
    @Test("Full export of a 60 s 720p mock is timed", .timeLimit(.minutes(5)))
    func timeSixtySecondFullExport() async throws {
        let directory = ReelFrames.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 60, to: directory.appendingPathComponent("timing-source-60s.mov")))
        let output = directory.appendingPathComponent("timing-full-60s.mov")
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await MediaExportService.exportFullVideo(segments: [source], to: output, quality: .hd720p)
        let elapsed = start.duration(to: clock.now)
        #expect(abs(result.duration - 60) < 0.1)
        let line = "plain full export, 60 s 720p mock: \(elapsed)"
        try (line + "\n").write(
            to: directory.appendingPathComponent("export-timing.txt"), atomically: true, encoding: .utf8)
    }
}
