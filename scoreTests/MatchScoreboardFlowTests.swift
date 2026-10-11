//
//  MatchScoreboardFlowTests.swift
//  scoreTests
//
//  The full video's board over a ScoreState the app really produces: points scored through WatchConnectivityManager
//  (games ending themselves at 11), read the way exportMatchVideos reads it, before endMatch.
//

import CoreMedia
import Foundation
import SwiftData
import Testing

@testable import score

@Suite("MatchScoreboardFlow")
struct MatchScoreboardFlowTests {
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
        manager.scoreAnnouncer.isEnabled = false  // no TTS in tests
        manager.generatesSummaries = false
    }

    @Test("After a 3-0 win scored through the manager, the board ends with nobody to serve")
    func decidedMatchFromTheApp() throws {
        manager.setMatchName("Ann vs Bob", player1: "Ann", player2: "Bob")
        manager.startRecording()  // points carry video times only while recording
        // 33 points, one a second (no suspension point, so the duration timer cannot overwrite the clock)
        for second in 1...33 {
            manager.recordingDuration = Double(second)
            manager.handleMessageData(WatchMessageData(from: ["command": "incrementP1"]))
        }
        let state = manager.scoreState
        try #require(state.currentMatchGames.count == 3 && manager.matchWonBy == 1, "Ann won 3-0")
        #expect(state.currentGameFirstServer != nil, "the app names a server for a game that will not be played")

        let recording = RecordingTimeline(segments: [
            RecordingSegment(fileReference: "a.mov", startOffset: 0, duration: 60)
        ])
        let cues = MatchScoreboardTimeline.cues(
            match: ReelScoreboardTimeline(scoreState: state), recording: recording, videoDuration: 60)
        let last = try #require(cues.last)
        #expect(last.state.playerOneGames == 3 && last.state.playerTwoGames == 0)
        #expect(last.state.playerOnePoints == 0 && last.state.playerTwoPoints == 0)
        #expect(last.state.server == nil, "no serve marker after the deciding game")
        #expect(abs(last.timeRange.start.seconds - (33 + ReelScoreboardTimeline.celebrationDuration)) < 0.01)
    }
}
