//
//  ReelOverlayTests.swift
//  scoreTests
//
//  End-to-end proof that the reel scoreboard is burned into exported frames: a synthetic video is exported
//  through ReelOverlayComposer and frames are read back out of the exported file and checked pixel by pixel.
//  The frames are also written as PNGs (see `ReelFrames.outputDirectory`) so a person can look at them.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI
import Testing
import UIKit
import os

@testable import score

@Suite("ReelOverlay", .serialized)
struct ReelOverlayTests {
    private static let videoSize = CGSize(width: 1280, height: 720)

    @Test("ImageRenderer produces colour on this runtime (sanity check for the board render)")
    func imageRendererProducesColour() throws {
        let renderer = ImageRenderer(content: Color.red.frame(width: 20, height: 20))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixels = ReelPixels(image)
        let centre = pixels.rgb(at: CGPoint(x: 10, y: 10))
        #expect(
            centre.r > 200 && centre.g < 80 && centre.b < 80,
            "expected red, got \(centre); \(ReelFrames.describe(image))")
        try FileManager.default.createDirectory(at: ReelFrames.outputDirectory, withIntermediateDirectories: true)
        try ReelFrames.savePNG(image, name: "red", in: ReelFrames.outputDirectory)
    }

    private static func state(
        points one: Int, _ two: Int, server: Int, pointWonBy: Int? = nil
    )
        -> ReelScoreboardState
    {
        ReelScoreboardState(
            playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 1, playerTwoGames: 0,
            playerOnePoints: one, playerTwoPoints: two, server: server, pointWonBy: pointWonBy)
    }

    @Test("The scoreboard renders at the layout's pixel size with a transparent background")
    func scoreboardRendersAtLayoutSize() throws {
        let layout = ReelScoreboardLayout(videoSize: Self.videoSize)
        let image = try #require(ReelScoreboardRenderer.render(Self.state(points: 5, 3, server: 1), layout: layout))
        #expect(CGFloat(image.width) == layout.panelSize.width)
        #expect(CGFloat(image.height) == layout.panelSize.height)
        let pixels = ReelPixels(image)
        try FileManager.default.createDirectory(at: ReelFrames.outputDirectory, withIntermediateDirectories: true)
        try ReelFrames.savePNG(image, name: "board", in: ReelFrames.outputDirectory)
        // A corner of the games box (the black digit sits at its centre) is gold; the chip is player one's blue;
        // the name area is the translucent panel
        let gamesCorner = CGPoint(x: layout.panelWidth - layout.pointsWidth - layout.gamesBoxWidth + 5, y: 5)
        let games = pixels.rgb(at: gamesCorner)
        #expect(games.r > 200 && games.g > 150 && games.b < 110, "games box should be gold, got \(games)")
        let chip = pixels.rgb(at: CGPoint(x: 3, y: layout.rowHeight / 2))
        #expect(chip.b > 180 && chip.r < 110, "player one chip should be blue, got \(chip)")
        let panelAlpha = pixels.alpha(at: CGPoint(x: layout.panelWidth / 2, y: 5))
        #expect(panelAlpha > 150 && panelAlpha < 255, "the panel should be translucent, alpha \(panelAlpha)")
    }

    /// Source video and the reel exported with two scoreboard cues (0.5-2 s "before", 2-3.5 s "after").
    private struct SpikeExport {
        let source: URL
        let reel: URL
        let layout: ReelScoreboardLayout
    }

    private static func exportSpikeReel(in directory: URL) async throws -> SpikeExport {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.mov")
        let outputURL = directory.appendingPathComponent("reel.mov")
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: outputURL)  // AVAssetExportSession refuses to overwrite
        let source = try #require(await MockVideoGenerator.generateMockVideo(duration: 4, to: sourceURL))

        let layout = ReelScoreboardLayout(videoSize: videoSize)
        let before = try #require(ReelScoreboardRenderer.render(state(points: 5, 3, server: 1), layout: layout))
        let after = try #require(
            ReelScoreboardRenderer.render(state(points: 6, 3, server: 2, pointWonBy: 1), layout: layout))
        let cues = [
            OverlayCue(
                timeRange: CMTimeRange(start: ReelFrames.seconds(0.5), duration: ReelFrames.seconds(1.5)),
                image: before,
                origin: layout.origin),
            OverlayCue(
                timeRange: CMTimeRange(start: ReelFrames.seconds(2), duration: ReelFrames.seconds(1.5)), image: after,
                origin: layout.origin),
        ]
        let asset = AVURLAsset(url: source)
        let composition = try await ReelOverlayComposer.videoComposition(for: asset, cues: cues)
        let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720))
        session.videoComposition = composition
        try await session.export(to: outputURL, as: .mov)
        return SpikeExport(source: source, reel: outputURL, layout: layout)
    }

    @Test("The scoreboard is burned into the exported frames for its cue's time range only", .timeLimit(.minutes(3)))
    func overlayIsBurnedIntoExportedFrames() async throws {
        let directory = ReelFrames.outputDirectory
        let export = try await Self.exportSpikeReel(in: directory)
        let layout = export.layout
        let size = Self.videoSize

        let frameBefore = try await ReelFrames.frame(of: export.reel, at: 1.0)
        let frameAfter = try await ReelFrames.frame(of: export.reel, at: 3.0)
        let framePlain = try await ReelFrames.frame(of: export.reel, at: 3.9)
        let sourceFrame = try await ReelFrames.frame(of: export.source, at: 1.0)
        let sourceLate = try await ReelFrames.frame(of: export.source, at: 3.9)
        for (name, image) in [
            ("reel-1s", frameBefore), ("reel-3s", frameAfter), ("reel-3.9s", framePlain), ("source-1s", sourceFrame),
        ] {
            try ReelFrames.savePNG(image, name: name, in: directory)
        }

        let exported = ReelPixels(frameBefore)
        let original = ReelPixels(sourceFrame)
        #expect(exported.width == Int(size.width) && exported.height == Int(size.height))

        // Inside the panel: gold games box (sampled off the digit) and the two player chips
        let gold = exported.rgb(at: layout.gamesBox(row: 0, in: size).insetCorner(5))
        #expect(gold.r > 190 && gold.g > 140 && gold.b < 120, "games box should be gold, got \(gold)")
        let chipOne = exported.rgb(at: layout.chip(row: 0, in: size).center())
        #expect(chipOne.b > 170 && chipOne.r < 120, "player one chip should be blue, got \(chipOne)")
        let chipTwo = exported.rgb(at: layout.chip(row: 1, in: size).center())
        #expect(chipTwo.r > 170 && chipTwo.b < 120, "player two chip should be red, got \(chipTwo)")

        // Outside the panel the frame is the source frame (allowing for re-encoding)
        let outside = CGPoint(x: size.width - 40, y: 40)
        #expect(exported.distance(to: original, at: outside) < 40, "frame outside the panel should match the source")
        let abovePanel = CGPoint(x: layout.panelFrame(in: size).midX, y: layout.panelFrame(in: size).minY - 20)
        #expect(exported.distance(to: original, at: abovePanel) < 40, "just above the panel should match the source")

        // Between the cues the second board shows a different points cell and the same chip
        let later = ReelPixels(frameAfter)
        #expect(
            exported.meanDifference(to: later, in: layout.pointsCell(row: 0, in: size)) > 4,
            "player one's points cell should change from 5 to 6")
        #expect(
            exported.meanDifference(to: later, in: layout.chip(row: 0, in: size)) < 10,
            "the chip should not change between cues")

        // After the last cue the panel is gone: that region matches the plain source
        #expect(
            ReelPixels(framePlain).meanDifference(to: ReelPixels(sourceLate), in: layout.panelFrame(in: size)) < 12,
            "no overlay should be drawn after the last cue")
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
