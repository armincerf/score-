//
//  VideoOrientationIntegrationTests.swift
//  scoreTests
//
//  The Vision and AVFoundation ends of the orientation fix, on the simulator:
//  - OrientationConvention pins the EXIF convention with Vision text recognition as the oracle: a picture that
//    needs correction C shows its text upright to Vision (a wide box in the top-left of Vision's normalized,
//    bottom-left-origin coordinates) only when Vision is given C.imageOrientation, and C.transform turns that
//    picture upright. (Recognition itself is no oracle on iOS 27: it reads the text at every rotation.)
//  - VideoOrientationIntegration runs the detector on mock footage (no people: it must keep `.none`), exports mock
//    footage with forced corrections and checks frames read back from the file, and drives
//    WatchConnectivityManager.exportMatchVideos end to end. Frames land in REEL_FRAMES_DIR/orientation as PNGs.
//
//  Vision's human body pose request has no compute device on the iOS simulator ("No available compute device for
//  VNComputeStageMain", with the CPU or the simulator GPU set explicitly too), so here the detector always takes its
//  error path. Its decisions on real photos are checked on the Mac with scripts/detect-orientation.sh --selftest.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import Vision

@testable import score

// MARK: - EXIF convention (Vision text recognition as the oracle)

@Suite("OrientationConvention", .serialized)
struct OrientationConventionTests {
    typealias Correction = VideoRotationCorrection

    /// 640x360, black "SCORE 1234" on white in the upper half.
    private static func textPicture() throws -> CGImage {
        let size = CGSize(width: 640, height: 360)
        let image = OrientationFrames.renderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 76, weight: .heavy), .foregroundColor: UIColor.black,
            ]
            NSAttributedString(string: "SCORE 1234", attributes: attributes).draw(at: CGPoint(x: 40, y: 30))
        }
        return try #require(image.cgImage)
    }

    /// The observation that reads "SCORE 1234" when Vision is told the picture has `orientation`, if any.
    private static func reading(
        _ image: CGImage, orientation: CGImagePropertyOrientation
    ) async throws
        -> RecognizedTextObservation?
    {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: image, orientation: orientation)
        return observations.first { observation in
            let text = (observation.topCandidates(1).first?.string ?? "").uppercased().replacingOccurrences(
                of: " ", with: "")
            return text.contains("SCORE1234")
        }
    }

    /// Whether Vision, told the picture has `orientation`, finds "SCORE 1234" where the upright picture has it: a
    /// wide strip in the top-left (normalized coordinates of the oriented picture, origin bottom-left). Text
    /// recognition alone is no oracle on iOS 27: it reads the text at every rotation. Where it puts the box is.
    private static func textIsUpright(
        in picture: CGImage, orientation candidate: Correction
    ) async throws -> (upright: Bool, box: CGRect?) {
        guard let observation = try await reading(picture, orientation: candidate.imageOrientation) else {
            return (false, nil)
        }
        let box = observation.boundingBox.cgRect
        let view = candidate.rotatedSize(CGSize(width: picture.width, height: picture.height))
        let wide = box.width * view.width > 2 * box.height * view.height
        return (wide && box.midY > 0.55 && box.minX < 0.2, box)
    }

    @Test("The upright picture shows its text upright with .up only (the oracle works on this runtime)")
    func oracleFindsUprightText() async throws {
        let picture = try Self.textPicture()
        try OrientationFrames.save(picture, name: "text-upright")
        for candidate in Correction.allCases {
            let result = try await Self.textIsUpright(in: picture, orientation: candidate)
            #expect(
                result.upright == (candidate == .none),
                "\(candidate.imageOrientation): box \(String(describing: result.box))")
        }
    }

    @Test(
        "A picture that needs correction C is upright to Vision only with C.imageOrientation",
        arguments: Correction.allCases)
    func pictureIsUprightOnlyWithItsCorrection(correction: Correction) async throws {
        // Turned counterclockwise by the correction's angle with Core Graphics alone (not with the code under test)
        let picture = try #require(
            OrientationFrames.turnedCounterclockwise(try Self.textPicture(), degrees: correction.degrees))
        try OrientationFrames.save(picture, name: "text-needs-\(correction.rawValue)")

        for candidate in Correction.allCases {
            let result = try await Self.textIsUpright(in: picture, orientation: candidate)
            #expect(
                result.upright == (candidate == correction),
                "needs \(correction), told \(candidate.imageOrientation): box \(String(describing: result.box))")
        }
    }

    @Test(
        "C.transform (top-left-origin pixels, as AVFoundation uses it) turns that picture upright",
        arguments: Correction.allCases)
    func transformTurnsPictureUpright(correction: Correction) async throws {
        let picture = try #require(
            OrientationFrames.turnedCounterclockwise(try Self.textPicture(), degrees: correction.degrees))
        let size = CGSize(width: picture.width, height: picture.height)
        let corrected = try #require(
            OrientationFrames.renderer(size: correction.rotatedSize(size)).image { context in
                context.cgContext.concatenate(correction.transform(for: size))
                UIImage(cgImage: picture).draw(in: CGRect(origin: .zero, size: size))
            }.cgImage)
        try OrientationFrames.save(corrected, name: "text-corrected-\(correction.rawValue)")
        #expect(corrected.width == 640 && corrected.height == 360)
        let result = try await Self.textIsUpright(in: corrected, orientation: .none)
        #expect(result.upright, "box \(String(describing: result.box))")
    }
}

// MARK: - Detector and export on mock footage

@Suite("VideoOrientationIntegration", .serialized)
struct VideoOrientationIntegrationTests {
    private static func seconds(_ elapsed: Duration) -> Double {
        Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func mockVideo(seconds duration: Double, name: String) async throws -> URL {
        let url = try OrientationFrames.directory().appendingPathComponent(name)
        return try #require(await MockVideoGenerator.generateMockVideo(duration: duration, to: url))
    }

    @Test("Mock footage (no people) keeps the metadata orientation, within 10 s", .timeLimit(.minutes(2)))
    func mockFootageKeepsMetadataOrientation() async throws {
        let source = try await Self.mockVideo(seconds: 3, name: "detector-3s.mov")
        let clock = ContinuousClock()
        let start = clock.now
        let detection = await VideoOrientationDetector.correction(for: source)
        let elapsed = Self.seconds(clock.now - start)

        #expect(detection.correction == .none)
        #expect(elapsed < 10, "detection took \(elapsed) s")
        // Empty scores = Vision could not run (the simulator's body pose request has no compute device);
        // otherwise all four orientations must have been scored, with nobody found
        if !detection.scores.isEmpty {
            #expect(detection.scores.count == 4 && detection.scores.values.allSatisfy { $0 == 0 })
        }
        try OrientationFrames.note(
            "detector 3 s mock: \(detection.correction.rawValue) in \(String(format: "%.3f", elapsed)) s, "
                + "scores \(detection.scores.isEmpty ? "unavailable (Vision error)" : VideoOrientationDetector.describe(detection.scores))",
            file: "detector-3s.txt")
    }

    @Test("Detection time on a 60 s 720p mock video is measured and logged", .timeLimit(.minutes(3)))
    func measureSixtySecondDetection() async throws {
        let source = try await Self.mockVideo(seconds: 60, name: "detector-60s.mov")
        let clock = ContinuousClock()
        let start = clock.now
        let detection = await VideoOrientationDetector.correction(for: source)
        let elapsed = Self.seconds(clock.now - start)
        #expect(detection.correction == .none)
        #expect(elapsed < 10, "detection took \(elapsed) s")
        try OrientationFrames.note(
            "detector 60 s mock: \(detection.correction.rawValue) in \(String(format: "%.3f", elapsed)) s, "
                + "scores \(detection.scores.isEmpty ? "unavailable (Vision error)" : VideoOrientationDetector.describe(detection.scores))",
            file: "detector-60s.txt")
    }

    /// Exports the mock `source` with one forced correction and returns the frame at 1.5 s of source and export.
    private static func export(
        _ source: URL, correction: VideoRotationCorrection
    ) async throws -> (source: CGImage, export: CGImage) {
        let output = try OrientationFrames.directory().appendingPathComponent("export-\(correction.rawValue).mov")
        let result = try await MediaExportService.exportFullVideo(
            segments: [source], corrections: [correction], to: output, quality: .hd720p)
        #expect(abs(result.duration - 4) < 0.1)
        let sourceFrame = try await OrientationFrames.frame(of: source, at: 1.5)
        let exportFrame = try await OrientationFrames.frame(of: output, at: 1.5)
        try OrientationFrames.save(sourceFrame, name: "export-source-1.5s")
        try OrientationFrames.save(exportFrame, name: "export-\(correction.rawValue)-1.5s")
        return (sourceFrame, exportFrame)
    }

    @Test("Exported with .upsideDown180, the frame is the source turned half way round", .timeLimit(.minutes(2)))
    func exportUpsideDown() async throws {
        let source = try await Self.mockVideo(seconds: 4, name: "export-source.mov")
        let frames = try await Self.export(source, correction: .upsideDown180)
        let original = OrientationPixels(frames.source)
        let exported = OrientationPixels(frames.export)
        #expect(exported.width == 1280 && exported.height == 720)

        // The caption band (the generator draws "MOCK MATCH VIDEO" along one long edge) moves to the opposite edge
        let top = CGRect(x: 0, y: 0, width: 1280, height: 100)
        let bottom = CGRect(x: 0, y: 620, width: 1280, height: 100)
        let sourceContrast = original.meanLuma(in: bottom) - original.meanLuma(in: top)
        let exportContrast = exported.meanLuma(in: bottom) - exported.meanLuma(in: top)
        #expect(abs(sourceContrast) > 1.5, "the caption should make one band brighter (contrast \(sourceContrast))")
        #expect(
            exportContrast * sourceContrast < 0, "bands should swap: source \(sourceContrast), export \(exportContrast)"
        )

        // Every bright (text) pixel of the source is bright at its half-turned position, not where it was
        let turned = original.brightRecall(in: exported) { x, y in (1279 - x, 719 - y) }
        let unturned = original.brightRecall(in: exported) { x, y in (x, y) }
        #expect(turned > 0.85, "half-turn recall \(turned)")
        #expect(unturned < 0.5, "unturned recall \(unturned)")
    }

    @Test("Exported with .clockwise90, the frame is 720x1280 and the source turned clockwise", .timeLimit(.minutes(2)))
    func exportClockwise() async throws {
        let source = try await Self.mockVideo(seconds: 4, name: "export-source.mov")
        let frames = try await Self.export(source, correction: .clockwise90)
        let original = OrientationPixels(frames.source)
        let exported = OrientationPixels(frames.export)
        #expect(exported.width == 720 && exported.height == 1280)

        // Clockwise, the source's bottom edge becomes the left edge and its top edge the right edge
        let sourceContrast =
            original.meanLuma(in: CGRect(x: 0, y: 620, width: 1280, height: 100))
            - original.meanLuma(in: CGRect(x: 0, y: 0, width: 1280, height: 100))
        let exportContrast =
            exported.meanLuma(in: CGRect(x: 0, y: 0, width: 100, height: 1280))
            - exported.meanLuma(in: CGRect(x: 620, y: 0, width: 100, height: 1280))
        #expect(abs(sourceContrast) > 1.5)
        #expect(
            exportContrast * sourceContrast > 0,
            "source bottom-top \(sourceContrast), export left-right \(exportContrast)")

        // Source pixel (x, y) lands at (719 - y, x) when turned clockwise, at (y, 1279 - x) when turned the other way
        let clockwise = original.brightRecall(in: exported) { x, y in (719 - y, x) }
        let anticlockwise = original.brightRecall(in: exported) { x, y in (y, 1279 - x) }
        #expect(clockwise > 0.85, "clockwise recall \(clockwise)")
        #expect(anticlockwise < 0.5, "anticlockwise recall \(anticlockwise)")
    }

    @Test("Silent footage (no audio track) exports to a full video and a reel", .timeLimit(.minutes(2)))
    func silentFootageExports() async throws {
        // Regression: the composition's empty audio track made both exports fail with AVFoundation -11838
        let source = try await Self.mockVideo(seconds: 4, name: "silent-source.mov")
        let directory = try OrientationFrames.directory()
        let full = try await MediaExportService.exportFullVideo(
            segments: [source], to: directory.appendingPathComponent("silent-full.mov"))
        #expect(abs(full.duration - 4) < 0.1)
        let clip = MediaExportService.HighlightClipInfo(
            startTimestamp: 0.5, endTimestamp: 2.5, player: 1, gameNumber: 0)
        let reel = try await MediaExportService.exportHighlightReel(
            from: full.outputURL, to: directory.appendingPathComponent("silent-reel.mov"), clips: [clip])
        #expect(abs(reel.duration - 2) < 0.1)
    }

    @Test("exportMatchVideos detects every segment and exports mock footage upright", .timeLimit(.minutes(2)))
    func exportMatchVideosEndToEnd() async throws {
        let container = try ModelContainer(
            for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let eventStore = EventStore(modelContext: container.mainContext)
        let projector = StateProjector()
        let manager = WatchConnectivityManager(
            eventStore: eventStore, stateProjector: projector,
            undoService: UndoService(eventStore: eventStore, stateProjector: projector),
            modelContext: container.mainContext)
        manager.scoreAnnouncer.isEnabled = false
        manager.generatesSummaries = false
        manager.setMatchName("Ann vs Bob", player1: "Ann", player2: "Bob")
        let matchId = try #require(manager.currentMatchId)
        defer { VideoStore.removeAll(matchId: matchId) }

        let segment = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 3, to: VideoStore.fileURL(matchId: matchId, kind: .mock)))
        manager.scoreState.recordingSegments = [
            RecordingSegment(fileReference: VideoStore.storedReference(for: segment), startOffset: 0)
        ]

        let clock = ContinuousClock()
        let start = clock.now
        let (fullVideo, highlightReel) = await manager.exportMatchVideos()
        let elapsed = Self.seconds(clock.now - start)

        let full = try #require(fullVideo)
        #expect(full == VideoStore.fileURL(matchId: matchId, kind: .full))
        #expect(highlightReel == nil)  // no highlights marked
        let frame = try await OrientationFrames.frame(of: full, at: 1.5)
        #expect(frame.width == 1280 && frame.height == 720, "mock footage must not be turned")
        #expect(!FileManager.default.fileExists(atPath: segment.path), "the raw segment is removed after export")
        #expect(elapsed < 30, "detect + export took \(elapsed) s")
        try OrientationFrames.save(frame, name: "match-full-1.5s")
        try OrientationFrames.note(
            "exportMatchVideos 3 s mock: \(String(format: "%.3f", elapsed)) s", file: "match-export.txt")
    }
}

// MARK: - Helpers

/// Output directory, frame extraction, PNG writing and Core Graphics rotation for the orientation tests.
enum OrientationFrames {
    /// REEL_FRAMES_DIR/orientation (make test sets REEL_FRAMES_DIR to .build/shots/reel on the Mac), or the repo's
    /// .build/shots/reel/orientation.
    static func directory() throws -> URL {
        let base: URL
        if let path = ProcessInfo.processInfo.environment["REEL_FRAMES_DIR"], !path.isEmpty {
            base = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            base = repo.appendingPathComponent(".build/shots/reel", isDirectory: true)
        }
        let directory = base.appendingPathComponent("orientation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func renderer(size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    static func save(_ image: CGImage, name: String) throws {
        let data = try #require(UIImage(cgImage: image).pngData())
        try data.write(to: try directory().appendingPathComponent("\(name).png"))
    }

    static func note(_ text: String, file: String) throws {
        try (text + "\n").write(to: try directory().appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// `image` turned counterclockwise by `degrees` with Core Graphics alone, so it needs a `degrees` clockwise turn
    /// to look upright. Core Graphics contexts are y-up: a positive angle turns the picture counterclockwise on
    /// screen.
    static func turnedCounterclockwise(_ image: CGImage, degrees: Int) -> CGImage? {
        let quarter = !degrees.isMultiple(of: 180)
        let width = quarter ? image.height : image.width
        let height = quarter ? image.width : image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(degrees) * .pi / 180)
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: CGPoint(x: -size.width / 2, y: -size.height / 2), size: size))
        return context.makeImage()
    }
}

/// RGBA bytes of a CGImage in top-left coordinates, with the luma queries the orientation checks need.
struct OrientationPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        let imageWidth = image.width
        let imageHeight = image.height
        width = imageWidth
        height = imageHeight
        var buffer = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: imageWidth, height: imageHeight, bitsPerComponent: 8,
                    bytesPerRow: imageWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        }
        bytes = buffer
    }

    /// Rec. 601 luma at a pixel, 0-255 (coordinates clamp to the image).
    func luma(_ x: Int, _ y: Int) -> Double {
        let index = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return 0.299 * Double(bytes[index]) + 0.587 * Double(bytes[index + 1]) + 0.114 * Double(bytes[index + 2])
    }

    /// Mean luma over a rectangle, sampled every 2 px.
    func meanLuma(in rect: CGRect) -> Double {
        var total = 0.0
        var count = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                total += luma(x, y)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// Fraction of this image's bright pixels (luma > 150, sampled every 2 px) whose position under `mapping` is
    /// bright in `other` too (luma > 110 anywhere in the 3x3 neighbourhood, allowing for re-encoding).
    func brightRecall(in other: OrientationPixels, mapping: (Int, Int) -> (Int, Int)) -> Double {
        var bright = 0
        var found = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) where luma(x, y) > 150 {
                bright += 1
                let (mappedX, mappedY) = mapping(x, y)
                let neighbourhood = (-1...1).flatMap { dy in
                    (-1...1).map { dx in other.luma(mappedX + dx, mappedY + dy) }
                }
                if neighbourhood.contains(where: { $0 > 110 }) { found += 1 }
            }
        }
        return bright == 0 ? 0 : Double(found) / Double(bright)
    }
}
