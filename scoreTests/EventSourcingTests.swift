//
//  EventSourcingTests.swift
//  scoreTests
//
//  EventStore + StateProjector + UndoService replayed through an in-memory SwiftData container.
//

import Foundation
import SwiftData
import Testing

@testable import score

private final class Harness {
    static let recordingStart = Date(timeIntervalSince1970: 1_700_000_000)

    let container: ModelContainer  // kept alive on purpose: the context does not retain its container
    let store: EventStore
    let projector = StateProjector()
    let undo: UndoService
    let matchId = UUID()

    init() throws {
        container = try ModelContainer(
            for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = EventStore(modelContext: container.mainContext)
        undo = UndoService(eventStore: store, stateProjector: projector)
    }

    /// A harness with its StoredMatch created and MatchStartedEvent (sequence 0) appended.
    static func started(initialServer: Int = 1) throws -> Harness {
        let sut = try Harness()
        try sut.createMatch()
        try sut.store.append(
            event: MatchStartedEvent(
                matchId: sut.matchId, sequenceNumber: try sut.nextSeq(), matchName: "Ann vs Bob",
                playerOneName: "Ann", playerTwoName: "Bob", recordingStartTime: recordingStart,
                initialServer: initialServer))
        return sut
    }

    private func nextSeq() throws -> Int { try store.getNextSequenceNumber(matchId: matchId) }

    @discardableResult
    func createMatch(id: UUID? = nil, start: Date = Harness.recordingStart) throws -> StoredMatch {
        try store.createMatch(
            id: id ?? matchId, matchName: "Ann vs Bob", playerOneName: "Ann", playerTwoName: "Bob",
            startTimestamp: start)
    }

    @discardableResult
    func point(_ player: Int, at videoTime: Double? = nil, game: Int = 0) throws -> PointScoredEvent {
        let event = PointScoredEvent(
            matchId: matchId, sequenceNumber: try nextSeq(), player: player, videoTimestamp: videoTime,
            gameNumber: game)
        try store.append(event: event)
        return event
    }

    func points(_ players: [Int]) throws {
        for player in players { try point(player) }
    }

    @discardableResult
    func markHighlight(at videoTime: Double, player: Int? = nil) throws -> HighlightMarkedEvent {
        let event = HighlightMarkedEvent(
            matchId: matchId, sequenceNumber: try nextSeq(), videoTimestamp: videoTime, player: player, gameNumber: 0)
        try store.append(event: event)
        return event
    }

    func attribute(_ highlight: HighlightMarkedEvent, to player: Int) throws {
        try store.append(
            event: HighlightAttributedEvent(
                matchId: matchId, sequenceNumber: try nextSeq(), highlightEventId: highlight.id, player: player))
    }

    func endGame(p1: Int, p2: Int, duration: TimeInterval = 300) throws {
        try store.append(
            event: GameEndedEvent(
                matchId: matchId, sequenceNumber: try nextSeq(), gameNumber: 0, playerOneScore: p1,
                playerTwoScore: p2, winner: p1 > p2 ? 1 : 2, gameDuration: duration))
    }

    /// Replays the stored events exactly as WatchConnectivityManager.refreshState does.
    func project(includeUndone: Bool = false) throws -> ScoreState {
        let match = try #require(try store.getMatch(id: matchId))
        let events = try store.getEvents(matchId: matchId, includeUndone: includeUndone)
        return try projector.project(events: events, matchMetadata: match)
    }
}

@Suite("EventSourcing")
struct EventSourcingTests {
    @Test("createMatch registers an active match; the newest active match wins")
    func createAndGetActiveMatch() throws {
        let sut = try Harness()
        let older = try sut.createMatch(id: UUID())
        let newer = try sut.createMatch(start: Harness.recordingStart.addingTimeInterval(60))
        #expect(try sut.store.getActiveMatch()?.id == newer.id)
        #expect(try sut.store.getAllMatches().map(\.id) == [newer.id, older.id])
        newer.isActive = false
        try sut.store.updateMatch(newer)
        #expect(try sut.store.getActiveMatch()?.id == older.id)
    }

    @Test("Sequence numbers increase and still count undone events")
    func sequenceNumbersIncludeUndone() throws {
        let sut = try Harness.started()
        #expect(try sut.store.getNextSequenceNumber(matchId: UUID()) == 0)
        #expect(try sut.point(1).sequenceNumber == 1)
        let undoId = try #require(try sut.undo.undoLastPoint(in: sut.matchId))
        #expect(try sut.store.getEvent(id: undoId)?.sequenceNumber == 2)
        #expect(try sut.store.getNextSequenceNumber(matchId: sut.matchId) == 3)
        #expect(try sut.store.getEvents(matchId: sut.matchId).map(\.sequenceNumber) == [0, 2])
        #expect(try sut.store.getEvents(matchId: sut.matchId, includeUndone: true).map(\.sequenceNumber) == [0, 1, 2])
    }

    @Test("matchStarted seeds names, recording state and the initial server")
    func projectMatchStarted() throws {
        let state = try Harness.started(initialServer: 2).project()
        #expect(state.currentMatchName == "Ann vs Bob")
        #expect(state.playerOneName == "Ann" && state.playerTwoName == "Bob")
        #expect(state.isRecording && state.recordingStartTime == Harness.recordingStart)
        #expect(state.servingPlayer == 2 && state.currentGameFirstServer == 2)
        #expect(state.playerOneScore == 0 && state.playerTwoScore == 0)
    }

    @Test(
        "Serving player is replayed from the initial server: every 2 points, every point from 10-10",
        arguments: [
            (1, "", 1), (2, "", 2), (1, "1", 1), (1, "12", 2), (1, "112", 2), (1, "1122", 1), (2, "11", 1),
            (2, "2211", 2), (1, "111111111", 1),
            // 10-9 and 9-10 are still two-point blocks: point 20 belongs to the second server
            (1, "1111111111222222222", 2), (1, "2222222222111111111", 2), (2, "1111111111222222222", 1),
            // from 10-10 the serve alternates every point, starting with the game's first server
            (1, "11111111112222222222", 1), (1, "111111111122222222221", 2), (1, "1111111111222222222212", 1),
            (2, "11111111112222222222", 2), (2, "111111111122222222221", 1), (2, "1111111111222222222212", 2),
        ])
    func servingPlayerAfterPoints(initialServer: Int, points: String, expected: Int) throws {
        let sut = try Harness.started(initialServer: initialServer)
        try sut.points(points.compactMap(\.wholeNumberValue))
        #expect(try sut.project().servingPlayer == expected)
    }

    @Test("Points update the score and record whether the scorer was serving")
    func scoresAndWasServing() throws {
        let sut = try Harness.started()
        for (index, player) in [1, 2, 2, 1, 1].enumerated() { try sut.point(player, at: Double(index + 1) * 10) }
        let state = try sut.project()
        #expect(state.playerOneScore == 3 && state.playerTwoScore == 2)
        #expect(state.currentGamePoints.map(\.player) == [1, 2, 2, 1, 1])
        #expect(state.currentGamePoints.map(\.wasServing) == [true, false, true, false, true])
        #expect(state.currentGamePoints.map(\.videoTimestamp) == [10, 20, 30, 40, 50])
    }

    @Test("gameEnded archives the game, resets the score and alternates the first server")
    func gameEndedProjection() throws {
        let sut = try Harness.started()
        try sut.points([1, 1, 2, 2, 1])  // 3-2: player 1 is serving again, so a missing flip would be visible
        try sut.endGame(p1: 3, p2: 2, duration: 123)
        var state = try sut.project()
        let game = try #require(state.currentMatchGames.first)
        #expect(game.playerOneScore == 3 && game.playerTwoScore == 2 && game.winner == 1)
        #expect(game.points.map(\.player) == [1, 1, 2, 2, 1] && game.duration == 123 && game.firstServer == 1)
        #expect(state.playerOneGames == 1 && state.playerTwoGames == 0)
        #expect(state.playerOneScore == 0 && state.playerTwoScore == 0 && state.currentGamePoints.isEmpty)
        #expect(state.currentGameFirstServer == 2 && state.servingPlayer == 2)
        try sut.point(2)  // 0-1: player 2 still serving, so the second flip is observable too
        try sut.endGame(p1: 0, p2: 1)
        state = try sut.project()
        #expect(state.currentMatchGames.count == 2 && state.currentMatchGames.last?.firstServer == 2)
        #expect(state.playerOneGames == 1 && state.playerTwoGames == 1)
        #expect(state.currentGameFirstServer == 1 && state.servingPlayer == 1)
    }

    @Test("A marked highlight is pending until an attribution event resolves it")
    func highlightMarkedThenAttributed() throws {
        let sut = try Harness.started()
        try sut.point(1, at: 10)
        try sut.point(2, at: 20)
        let highlight = try sut.markHighlight(at: 25)
        var state = try sut.project()
        let pending = try #require(state.pendingHighlight)
        #expect(pending.id == highlight.id && pending.player == nil && pending.gameNumber == 0)
        #expect(pending.startTimestamp == 20 && pending.endTimestamp == 25)
        #expect(state.highlightClips.isEmpty && state.totalHighlightsInMatch == 1)
        try sut.point(2, at: 30)  // the app scores the next point first, then attributes
        try sut.attribute(highlight, to: 2)
        state = try sut.project()
        #expect(state.pendingHighlight == nil && state.totalHighlightsInMatch == 1)
        let clip = try #require(state.highlightClips.first)
        #expect(clip.id == highlight.id && clip.player == 2 && clip.gameNumber == 0)
        #expect(clip.startTimestamp == 20 && clip.endTimestamp == 25)
        try sut.attribute(highlight, to: 1)  // attributing a resolved highlight again is ignored
        state = try sut.project()
        #expect(state.highlightClips.map(\.player) == [2] && state.pendingHighlight == nil)
        let direct = try sut.markHighlight(at: 35, player: 1)  // already attributed: a clip, never pending
        state = try sut.project()
        #expect(state.pendingHighlight == nil && state.highlightClips.map(\.id) == [highlight.id, direct.id])
        #expect(state.highlightClips.last?.startTimestamp == 30 && state.highlightClips.last?.player == 1)
    }

    @Test("matchEnded stops recording and keeps the result")
    func matchEnded() throws {
        let sut = try Harness.started()
        try sut.points([1, 1])
        let ended = MatchEndedEvent(
            matchId: sut.matchId, sequenceNumber: try sut.store.getNextSequenceNumber(matchId: sut.matchId),
            playerOneGames: 1, playerTwoGames: 0, winner: 1, matchDuration: 600, highlightVideoURL: nil)
        try sut.store.append(event: ended)
        let state = try sut.project()
        #expect(!state.isRecording && state.playerOneScore == 2 && state.currentMatchName == "Ann vs Bob")
    }

    @Test("undoLastPoint soft-deletes the point and replay recomputes score and server")
    func undoLastPoint() throws {
        let sut = try Harness.started()
        try sut.points([1, 1])
        #expect(try sut.project().servingPlayer == 2)
        let undoId = try #require(try sut.undo.undoLastPoint(in: sut.matchId))
        let stored = try sut.store.getEvents(matchId: sut.matchId, includeUndone: true)
        let point = try #require(stored.last(where: { $0.eventType == EventType.pointScored.rawValue }))
        let undoStored = try #require(try sut.store.getEvent(id: undoId))
        #expect(point.isUndone && undoStored.eventType == EventType.eventUndone.rawValue && !undoStored.isUndone)
        let undoEvent = try JSONDecoder().decode(EventUndoneEvent.self, from: undoStored.eventData)
        #expect(undoEvent.undoneEventId == point.id && undoEvent.reason == "user_undo")
        for includeUndone in [false, true] {
            let state = try sut.project(includeUndone: includeUndone)
            #expect(state.playerOneScore == 1 && state.currentGamePoints.count == 1 && state.servingPlayer == 1)
        }
    }

    @Test("Undo cannot reach into a finished game")
    func undoStopsAtGameBoundary() throws {
        let sut = try Harness.started()
        try sut.points([1, 1])
        try sut.endGame(p1: 2, p2: 0)
        #expect(try sut.store.getCurrentGameEvents(matchId: sut.matchId).isEmpty)
        #expect(try sut.undo.undoLastPoint(in: sut.matchId) == nil)
        #expect(try !sut.undo.canUndo(in: sut.matchId) && sut.undo.getUndoableActionCount(in: sut.matchId) == 0)
        #expect(try sut.undo.getUndoDescription(in: sut.matchId) == nil)
        try sut.point(2, game: 1)
        #expect(try sut.store.getCurrentGameEvents(matchId: sut.matchId).count == 1)
        #expect(try sut.undo.undoLastPoint(in: sut.matchId) != nil)
        let state = try sut.project()
        #expect(state.currentMatchGames.first?.points.count == 2 && state.playerOneGames == 1)
        #expect(state.playerTwoScore == 0 && state.currentGamePoints.isEmpty)
    }

    @Test("canUndo, undoable count and description follow the last live action")
    func undoAvailability() throws {
        let sut = try Harness.started()
        let id = sut.matchId
        #expect(try !sut.undo.canUndo(in: id) && sut.undo.getUndoableActionCount(in: id) == 0)
        #expect(try sut.undo.getUndoDescription(in: id) == nil)
        try sut.points([1, 2])
        #expect(try sut.undo.canUndo(in: id) && sut.undo.getUndoableActionCount(in: id) == 2)
        #expect(try sut.undo.getUndoDescription(in: id) == "Point for Player 2")
        try sut.markHighlight(at: 30)
        #expect(
            try sut.undo.getUndoableActionCount(in: id) == 3 && sut.undo.getUndoDescription(in: id) == "Highlight Mark")
        #expect(try sut.undo.undoLastHighlight(in: id) != nil)
        #expect(try sut.project().pendingHighlight == nil)
        #expect(try sut.undo.getUndoDescription(in: id) == "Point for Player 2")
        #expect(try sut.undo.undoLastPoint(in: id) != nil)
        #expect(try sut.undo.getUndoDescription(in: id) == "Point for Player 1")
        #expect(try sut.undo.undoLastPoint(in: id) != nil)
        #expect(try !sut.undo.canUndo(in: id) && sut.undo.getUndoableActionCount(in: id) == 0)
    }

    @Test("deleteMatch removes the match and every event, undone ones included")
    func deleteMatch() throws {
        let sut = try Harness.started()
        try sut.points([1, 2])
        _ = try sut.undo.undoLastPoint(in: sut.matchId)
        let other = try sut.createMatch(id: UUID())
        try sut.store.deleteMatch(id: sut.matchId)
        #expect(try sut.store.getMatch(id: sut.matchId) == nil)
        #expect(try sut.store.getEvents(matchId: sut.matchId, includeUndone: true).isEmpty)
        #expect(try sut.store.getAllMatches().map(\.id) == [other.id])
        #expect(throws: EventStoreError.self) { try sut.store.deleteMatch(id: sut.matchId) }
    }

    // GameView.undoLastAction -> undoLastPoint -> refreshState(): only the PointScoredEvent is soft-deleted, the
    // HighlightAttributedEvent that point produced stays live, so the clip keeps the undone point's player and the
    // next point cannot re-attribute it.
    @Test(
        "Undoing the point that attributed a highlight makes the highlight pending again",
        .disabled("BUG: undoLastPoint leaves the HighlightAttributedEvent live, so the clip keeps the wrong player"))
    func undoRestoresPendingHighlight() throws {
        let sut = try Harness.started()
        try sut.point(1, at: 10)
        let highlight = try sut.markHighlight(at: 15)
        try sut.point(2, at: 20)
        try sut.attribute(highlight, to: 2)
        _ = try sut.undo.undoLastPoint(in: sut.matchId)
        let state = try sut.project()
        #expect(state.highlightClips.isEmpty && state.pendingHighlight?.id == highlight.id)
    }

    // UndoService.maxUndoDepth (10) is documented in AGENTS.md, but its guard looks up the index of the last live
    // point in the list of live points (always count - 1) and compares it with count - 10, which is never smaller,
    // so UndoError.exceedsMaxDepth is unreachable and a game can be undone all the way back to 0-0.
    @Test(
        "Undo is limited to maxUndoDepth points per game",
        .disabled("BUG: UndoService's depth guard can never fire, so the 11th undo succeeds instead of throwing"))
    func undoDepthLimit() throws {
        let sut = try Harness.started()
        try sut.points(Array(repeating: 1, count: 11))
        for _ in 0..<10 { #expect(try sut.undo.undoLastPoint(in: sut.matchId) != nil) }
        #expect(throws: UndoError.exceedsMaxDepth) { try sut.undo.undoLastPoint(in: sut.matchId) }
        #expect(try sut.project().playerOneScore == 1)
    }

    // Latent: nothing reads StoredMatch.events yet and deleteMatch deletes events by hand, but the declared cascade
    // delete never fires and any future @Query/relationship traversal silently sees an empty list.
    @Test(
        "Appended events are linked to their StoredMatch",
        .disabled("BUG: EventStore.append never sets StoredMatchEvent.match, so StoredMatch.events is always empty"))
    func eventsLinkToMatch() throws {
        let sut = try Harness.started()
        try sut.points([1])
        let match = try #require(try sut.store.getMatch(id: sut.matchId))
        #expect(match.events.count == 2)
        #expect(try sut.store.getEvents(matchId: sut.matchId).allSatisfy { $0.match?.id == sut.matchId })
    }
}
