//
//  WatchCommandTimingTests.swift
//  scoreTests
//
//  When a watch command happened: a tap the watch queued with transferUserInfo (phone out of reach) arrives later,
//  often in a burst, and is placed on the match clock at its `sentAt`, not on arrival, so the full video's board
//  follows the rallies instead of freezing and then jumping.
//

import Foundation
import SwiftData
import Testing

@testable import score

@Suite("WatchCommandTiming")
struct WatchCommandTimingTests {
    private let container: ModelContainer
    private let eventStore: EventStore
    private let manager: WatchConnectivityManager

    init() throws {
        container = try ModelContainer(
            for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        eventStore = EventStore(modelContext: context)
        let projector = StateProjector()
        manager = WatchConnectivityManager(
            eventStore: eventStore, stateProjector: projector,
            undoService: UndoService(eventStore: eventStore, stateProjector: projector), modelContext: context)
        manager.scoreAnnouncer.isEnabled = false  // no TTS in tests
        manager.generatesSummaries = false
    }

    /// A recording match whose clock reads `now` seconds; returns the match id and the clock's origin.
    private func recordingMatch(now: TimeInterval) throws -> (id: UUID, start: Date) {
        manager.setMatchName("Ann vs Bob", player1: "Ann", player2: "Bob")
        manager.startRecording()
        manager.recordingDuration = now
        return (try #require(manager.currentMatchId), try #require(manager.scoreState.recordingStartTime))
    }

    private func deliver(_ command: String, sentAt: Date?) {
        var message: [String: Any] = ["command": command, "actionId": UUID().uuidString]
        message["sentAt"] = sentAt?.timeIntervalSince1970
        manager.receiveFromWatch(WatchMessageData(from: message), via: .userInfo)
    }

    @Test("The tap time on the match clock, kept between the previous point and now")
    func commandOffsetClamps() {
        let start = Date(timeIntervalSince1970: 1_000)
        func offset(_ sentAt: TimeInterval) -> TimeInterval {
            WatchConnectivityManager.commandOffset(
                sentAt: 1_000 + sentAt, recordingStart: start, now: 60, notBefore: 20)
        }
        #expect(offset(42) == 42, "a tap queued 18 s ago")
        #expect(offset(15) == 20, "never before the previous point")
        #expect(offset(61.5) == 60, "never after now (the watch's clock running ahead)")
    }

    @Test("Points and a highlight queued on the watch are timed at their taps, in the store and the state")
    func queuedCommandsKeepTheirTapTimes() throws {
        let match = try recordingMatch(now: 90)
        // The watch was out of reach from 10 s; its queue drains at 90 s
        deliver("incrementP1", sentAt: match.start.addingTimeInterval(12))
        deliver("incrementP2", sentAt: match.start.addingTimeInterval(31))
        deliver("highlight", sentAt: match.start.addingTimeInterval(45))
        deliver("incrementP2", sentAt: match.start.addingTimeInterval(47))

        let points = manager.scoreState.currentGamePoints.map(\.videoTimestamp)
        #expect(points == [12, 31, 47])
        let stored = try eventStore.getEvents(matchId: match.id, includeUndone: true)
            .filter { $0.eventType == EventType.pointScored.rawValue }
            .map { try JSONDecoder().decode(PointScoredEvent.self, from: $0.eventData).videoTimestamp }
        #expect(stored == [12, 31, 47], "a relaunch replays the same times")
        let highlight = try #require(manager.scoreState.highlightClips.first)
        #expect(highlight.startTimestamp == 31 && highlight.endTimestamp == 45, "from the last point to the tap")
        #expect(highlight.player == 2)
    }

    @Test("A command without sentAt (older watch builds) is timed on arrival")
    func commandWithoutSentAt() throws {
        _ = try recordingMatch(now: 75)
        deliver("incrementP1", sentAt: nil)
        #expect(manager.scoreState.currentGamePoints.map(\.videoTimestamp) == [75])
    }
}
