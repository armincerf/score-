//
//  ReelManagerExportTests.swift
//  scoreTests
//
//  The scoreboard through the app's own export path: WatchConnectivityManager.exportMatchVideos() builds the
//  timeline from its scoreState, renders the cues and exports the reel. A mock recording stands in for the camera.
//

import AVFoundation
import CoreGraphics
import Foundation
import SwiftData
import Testing

@testable import score

@Suite("ReelManagerExport", .serialized)
struct ReelManagerExportTests {
    private let container: ModelContainer
    private let manager: WatchConnectivityManager

    init() throws {
        container = try ModelContainer(
            for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let eventStore = EventStore(modelContext: context)
        let projector = StateProjector()
        manager = WatchConnectivityManager(
            eventStore: eventStore, stateProjector: projector,
            undoService: UndoService(eventStore: eventStore, stateProjector: projector), modelContext: context)
        manager.scoreAnnouncer.isEnabled = false
        manager.generatesSummaries = false
    }

    /// A match with one 10 s recording from wall clock 0: Ann 2-1 Bob in game 1 (Bob served first), and one
    /// highlight from the third point (3 s) to 7 s won by Ann (her point at 7.2 s makes it 3-1).
    private func recordMatch() async throws -> UUID {
        manager.setMatchName("Ann vs Bob", player1: "Ann", player2: "Bob")
        let matchId = try #require(manager.currentMatchId)
        let segment = VideoStore.fileURL(matchId: matchId, kind: .rawSegment(index: 0))
        _ = try #require(await MockVideoGenerator.generateMockVideo(duration: 10, to: segment))
        var state = manager.scoreState
        state.recordingSegments = [
            RecordingSegment(fileReference: VideoStore.storedReference(for: segment), startOffset: 0)
        ]
        state.currentGamePoints =
            [1, 1, 2].enumerated().map { index, player in
                PointEvent(player: player, videoTimestamp: Double(index + 1))
            } + [PointEvent(player: 1, videoTimestamp: 7.2)]
        state.currentGameFirstServer = 2
        state.highlightClips = [HighlightClip(startTimestamp: 3, endTimestamp: 7, player: 1, gameNumber: 0)]
        manager.scoreState = state
        return matchId
    }

    @Test("Ending a match exports a reel carrying the match's scoreboard", .timeLimit(.minutes(3)))
    func managerReelCarriesTheScoreboard() async throws {
        let matchId = try await recordMatch()
        defer { VideoStore.removeAll(matchId: matchId) }

        let exported = await manager.exportMatchVideos()

        let reel = try #require(exported.highlightReel, "the reel is exported")
        let duration = try await AVURLAsset(url: reel).load(.duration).seconds
        #expect(abs(duration - 4) < 0.1, "one 4 s clip, got \(duration)")
        let start = try await ReelFrames.frame(of: reel, at: 1.0)
        let lit = try await ReelFrames.frame(of: reel, at: 3.5)
        try ReelFrames.savePNG(start, name: "manager-reel-1.0s")
        try ReelFrames.savePNG(lit, name: "manager-reel-3.5s")

        let size = CGSize(width: start.width, height: start.height)
        let layout = ReelScoreboardLayout(videoSize: size)
        let before = ReelPixels(start)
        let after = ReelPixels(lit)
        let box = layout.gamesBox(row: 0, in: size)
        #expect(ReelPixels.isGold(before.rgb(at: CGPoint(x: box.minX + 5, y: box.minY + 5))), "the board is drawn")
        // 2-1 with three points played and Bob first to serve: Ann serves next
        let marker = layout.serveMarkerSlot(row: 0, in: size).insetBy(dx: -3, dy: -3)
        #expect(before.count(in: marker, where: ReelPixels.isGold) > 8, "Ann's serve marker")
        // The last 1.2 s: Ann's points cell turns white (3-1)
        let cell = layout.pointsCell(row: 0, in: size)
        #expect(after.meanBrightness(in: cell) > before.meanBrightness(in: cell) + 80, "Ann's point flashes")
    }

    /// Regression: makeComposition used to add an audio track that stayed empty for a recording without sound,
    /// and the export rejected the empty track (AVError -11838), so exportMatchVideos kept the raw segment as the
    /// full video. The empty track is now dropped before the export.
    @Test("exportFullVideo exports a single recording without sound", .timeLimit(.minutes(2)))
    func fullVideoOfSilentRecording() async throws {
        let directory = ReelFrames.outputDirectory
        let segment = try #require(
            await MockVideoGenerator.generateMockVideo(
                duration: 3, to: directory.appendingPathComponent("silent-segment.mov")))
        let output = directory.appendingPathComponent("silent-full.mov")
        let result = try await MediaExportService.exportFullVideo(segments: [segment], to: output)
        #expect(abs(result.duration - 3) < 0.1)
    }
}
