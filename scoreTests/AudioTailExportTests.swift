//
//  AudioTailExportTests.swift
//  scoreTests
//
//  A camera segment whose sound runs past its last video frame (AVCaptureMovieFileOutput writes audio and video in
//  independent chunks, so the file is often tens of ms longer than its picture). The exports insert each segment for
//  the file's whole duration, so the composition asks the compositor for frames the video track does not have: they
//  must come out black (as the default compositor drew them), never fail the export. Frames land in REEL_FRAMES_DIR
//  as tail-*.png.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing

@testable import score

@Suite("AudioTailExport", .serialized)
struct AudioTailExportTests {
    private static let directory = ReelFrames.outputDirectory
    private static let videoSeconds = 4.0
    private static let toneSeconds = 4.3

    /// A 4 s mock picture with a 4.3 s tone (LPCM, muxed by passthrough): the asset runs 0.3 s past its video track.
    private static func segment(_ index: Int) async throws -> URL {
        let picture = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: videoSeconds, to: directory.appendingPathComponent("tail-picture-\(index).mov")))
        let output = directory.appendingPathComponent("tail-segment-\(index).mov")
        let toneAsset = AVURLAsset(url: directory.appendingPathComponent("tail-tone-\(index).caf"))
        try makeTone(seconds: toneSeconds, at: toneAsset.url)
        let pictureAsset = AVURLAsset(url: picture)
        let composition = AVMutableComposition()
        let video = try #require(try await pictureAsset.loadTracks(withMediaType: .video).first)
        let videoTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(try await video.load(.timeRange), of: video, at: .zero)
        let tone = try #require(try await toneAsset.loadTracks(withMediaType: .audio).first)
        let audioTrack = try #require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try audioTrack.insertTimeRange(try await tone.load(.timeRange), of: tone, at: .zero)
        try? FileManager.default.removeItem(at: output)
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: output, as: .mov)
        extendLifetime(toneAsset)
        extendLifetime(pictureAsset)

        // The fixture must have the shape under test: the file outlasts its picture
        let asset = AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let videoEnd = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let pictureEnd = try await videoEnd.load(.timeRange).end.seconds
        try #require(duration - pictureEnd > 0.2, "asset \(duration) s, video ends at \(pictureEnd) s")
        return output
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
        file.close()
    }

    private static func frame(_ url: URL, at seconds: Double, name: String) async throws -> ReelPixels {
        let image = try await ReelFrames.frame(of: url, at: seconds)
        try ReelFrames.savePNG(image, name: name)
        return ReelPixels(image)
    }

    @Test(
        "Segments whose sound outlasts their picture export whole, the tail black under the board",
        .timeLimit(.minutes(3)))
    func fullVideoWithAudioTails() async throws {
        let segments = [try await Self.segment(0), try await Self.segment(1)]
        let timeline = RecordingTimeline(
            segments: (0..<2).map {
                RecordingSegment(
                    fileReference: "tail-\($0).mov", startOffset: Double($0) * Self.toneSeconds,
                    duration: Self.toneSeconds)
            })
        let match = ReelScoreboardTimeline(
            playerOneName: "Alex", playerTwoName: "Lucio", games: [],
            currentGamePoints: [PointEvent(player: 1, videoTimestamp: 1), PointEvent(player: 2, videoTimestamp: 6)],
            currentGameFirstServer: 1)
        let duration = 2 * Self.toneSeconds
        let cues = MatchScoreboardTimeline.cues(match: match, recording: timeline, videoDuration: duration)
        let output = Self.directory.appendingPathComponent("tail-full.mov")
        let result = try await MediaExportService.exportFullVideo(
            segments: segments, scoreboard: cues, to: output, quality: .hd720p)
        #expect(abs(result.duration - duration) < 0.05, "the time base stays the files' durations: \(result.duration)")

        let size = CGSize(width: 1280, height: 720)
        let layout = ReelScoreboardLayout(videoSize: size)
        let away = CGRect(x: 700, y: 300, width: 400, height: 300)  // the picture's middle, clear of the board
        let picture = try await Self.frame(output, at: 2, name: "tail-full-2.0s")
        let tail = try await Self.frame(output, at: 4.15, name: "tail-full-4.15s")
        let second = try await Self.frame(output, at: 6.5, name: "tail-full-6.5s")
        #expect(picture.meanBrightness(in: away) > 20, "the first segment's picture")
        #expect(second.meanBrightness(in: away) > 20, "the second segment's picture, after the first one's tail")
        #expect(tail.meanBrightness(in: away) < 5, "the tail has no picture: black, \(tail.meanBrightness(in: away))")
        let box = layout.gamesBox(row: 0, in: size)
        for (name, frame) in [("2.0", picture), ("4.15", tail), ("6.5", second)] {
            #expect(frame.count(in: box, where: ReelPixels.isGold) > 200, "the board is drawn at \(name) s")
        }
    }

    @Test("A reel piece ending on a segment's end, past its picture, exports", .timeLimit(.minutes(3)))
    func reelPieceThroughTheTail() async throws {
        let segment = try await Self.segment(2)
        let piece = MediaExportService.SourcePiece(
            url: segment,
            timeRange: CMTimeRange(
                start: CMTime(seconds: 3, preferredTimescale: 600),
                end: CMTime(seconds: Self.toneSeconds, preferredTimescale: 600)))
        let output = Self.directory.appendingPathComponent("tail-reel.mov")
        let result = try await MediaExportService.exportHighlightReel(
            pieces: [piece], to: output, quality: .hd720p)
        #expect(abs(result.duration - (Self.toneSeconds - 3)) < 0.05)
        let away = CGRect(x: 700, y: 300, width: 400, height: 300)
        let picture = try await Self.frame(output, at: 0.5, name: "tail-reel-0.5s")
        #expect(picture.meanBrightness(in: away) > 20, "the clip's picture")
    }
}
