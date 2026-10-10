//
//  WatchCommandTests.swift
//  scoreTests
//
//  Phone-side handling of watch commands and the match lifecycle through WatchConnectivityManager,
//  backed by an in-memory SwiftData store and the real EventStore / StateProjector / UndoService.
//  Built for the simulator, so startRecording() only arms the duration timer (no camera is touched).
//

import Foundation
import SwiftData
import Testing

@testable import score

@Suite("WatchCommands")
struct WatchCommandTests {
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
    }

    // MARK: - Helpers

    @discardableResult
    private func startMatch(_ name: String = "Ann vs Bob") throws -> UUID {
        manager.setMatchName(name, player1: "Ann", player2: "Bob")
        return try #require(manager.currentMatchId)
    }

    private func score(_ players: [Int]) {
        for player in players {
            if player == 1 { manager.incrementPlayer1() } else { manager.incrementPlayer2() }
        }
    }

    private func events(_ matchId: UUID) throws -> [StoredMatchEvent] {
        try eventStore.getEvents(matchId: matchId, includeUndone: true)
    }

    private func decode<E: Decodable>(_ type: E.Type, _ event: StoredMatchEvent?) throws -> E {
        try JSONDecoder().decode(type, from: try #require(event).eventData)
    }

    private func send(_ message: [String: Any]) {
        manager.handleMessageData(WatchMessageData(from: message))
    }

    // MARK: - Match start

    @Test("setMatchName creates an active match with a MatchStartedEvent at sequence 0")
    func matchStart() throws {
        let matchId = try startMatch()
        let stored = try #require(try eventStore.getMatch(id: matchId))
        #expect(stored.isActive && stored.matchName == "Ann vs Bob")
        #expect(stored.playerOneName == "Ann" && stored.playerTwoName == "Bob")
        #expect(try eventStore.getActiveMatch()?.id == matchId)

        let all = try events(matchId)
        #expect(all.map(\.eventType) == [EventType.matchStarted.rawValue] && all.first?.sequenceNumber == 0)
        let started = try decode(MatchStartedEvent.self, all.first)
        #expect(started.playerOneName == "Ann" && started.playerTwoName == "Bob")
        #expect([1, 2].contains(started.initialServer))

        let state = manager.scoreState
        #expect(state.currentMatchName == "Ann vs Bob")
        #expect(state.playerOneName == "Ann" && state.playerTwoName == "Bob")
        #expect(state.servingPlayer == started.initialServer && state.currentGameFirstServer == started.initialServer)
        #expect(state.playerOneScore == 0 && state.playerTwoScore == 0 && !state.isRecording)
    }

    @Test("Scoring, ending and highlights are ignored without an active match")
    func noActiveMatch() throws {
        manager.incrementPlayer1()
        send(["command": "incrementP2"])
        manager.markHighlight()
        manager.endGame()
        manager.endMatch(fullVideoURL: nil, highlightVideoURL: nil)
        #expect(manager.scoreState.playerOneScore == 0 && manager.scoreState.playerTwoScore == 0)
        #expect(manager.scoreState.currentMatchGames.isEmpty && manager.scoreState.matchHistory.isEmpty)
        #expect(manager.currentMatchId == nil)
        #expect(try eventStore.getAllMatches().isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredMatchEvent>()) == 0)
    }

    // MARK: - Points and games

    /// Ten alternating points (10-10) followed by `tail`: deuce, where service changes every point.
    nonisolated private static func deuce(_ tail: [Int]) -> [Int] {
        Array(repeating: [1, 2], count: 10).flatMap(\.self) + tail
    }

    // `firstServerServes` is stated from the rules rather than derived from ServingLogic: service changes every
    // two points, and every point once both players reach 10. The two deuce cases distinguish the deuce rule
    // from the two-point rule (which would answer the opposite for 21 and 22 points).
    @Test(
        "Points append sequenced PointScoredEvents and update score and server",
        arguments: [
            (sequence: [1], firstServerServes: true),
            (sequence: [1, 1, 2], firstServerServes: false),
            (sequence: [2, 2, 2, 1, 1], firstServerServes: true),
            (sequence: [1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2], firstServerServes: true),
            (sequence: deuce([1]), firstServerServes: false),  // 11-10
            (sequence: deuce([1, 2]), firstServerServes: true),  // 11-11
        ])
    func scoringPoints(sequence: [Int], firstServerServes: Bool) throws {
        let matchId = try startMatch()
        let firstServer = try #require(manager.scoreState.currentGameFirstServer)
        score(sequence)

        let p1 = sequence.filter { $0 == 1 }.count
        let p2 = sequence.count - p1
        #expect(manager.scoreState.playerOneScore == p1 && manager.scoreState.playerTwoScore == p2)
        #expect(manager.scoreState.servingPlayer == (firstServerServes ? firstServer : 3 - firstServer))

        let points = try events(matchId).filter { $0.eventType == EventType.pointScored.rawValue }
        #expect(points.map(\.sequenceNumber) == Array(1...sequence.count))
        let decoded = try points.map { try decode(PointScoredEvent.self, $0) }
        #expect(decoded.map(\.player) == sequence && decoded.allSatisfy { $0.gameNumber == 0 })
    }

    @Test("A game to 11 then the endGame command records the GameResult and flips the first server")
    func gameToEleven() throws {
        let matchId = try startMatch()
        manager.startRecording()  // points are only tracked into currentGamePoints while recording
        let firstServer = try #require(manager.scoreState.currentGameFirstServer)
        let sequence = [1, 1, 1, 2, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1]  // 11-3
        score(sequence)
        // 11-3 ends the game by itself; a stray End Game from the watch at 0-0 must then be a no-op
        send(["command": "endGame"])

        let all = try events(matchId)
        #expect(all.last?.eventType == EventType.gameEnded.rawValue && all.last?.sequenceNumber == sequence.count + 1)
        let ended = try decode(GameEndedEvent.self, all.last)
        #expect(ended.gameNumber == 0 && ended.playerOneScore == 11 && ended.playerTwoScore == 3 && ended.winner == 1)

        let state = manager.scoreState
        let game = try #require(state.currentMatchGames.first)
        #expect(state.currentMatchGames.count == 1 && state.playerOneGames == 1 && state.playerTwoGames == 0)
        #expect(game.playerOneScore == 11 && game.playerTwoScore == 3 && game.winner == 1)
        #expect(game.firstServer == firstServer && game.points.map(\.player) == sequence)
        // Before deuce the first server serves points 1-2, 5-6, 9-10, ...; a point is "on serve" when its
        // scorer is the player serving at that moment.
        let servedByFirstServer = sequence.indices.map { ($0 / 2).isMultiple(of: 2) }
        let expectedOnServe = zip(sequence, servedByFirstServer).map { scorer, byFirst in
            (scorer == firstServer) == byFirst
        }
        #expect(game.points.map(\.wasServing) == expectedOnServe)
        #expect(game.pointsWonOnServeP1 + game.pointsWonOnServeP2 == expectedOnServe.count(where: { $0 }))
        #expect(state.currentGameFirstServer == 3 - firstServer && state.servingPlayer == 3 - firstServer)
        #expect(state.playerOneScore == 0 && state.playerTwoScore == 0 && state.currentGamePoints.isEmpty)

        manager.incrementPlayer2()
        let next = try decode(PointScoredEvent.self, try events(matchId).last)
        #expect(next.gameNumber == 1)
    }

    // MARK: - Highlights

    @Test("markHighlight while recording creates a pending clip that the next point attributes")
    func highlightAttribution() throws {
        let matchId = try startMatch()
        send(["command": "highlight"])  // not recording yet: ignored
        #expect(manager.scoreState.pendingHighlight == nil)
        #expect(try events(matchId).count == 1)

        manager.startRecording()
        manager.incrementPlayer1()
        manager.markHighlight()
        let pending = try #require(manager.scoreState.pendingHighlight)
        #expect(pending.player == nil && pending.gameNumber == 0 && manager.scoreState.totalHighlightsInMatch == 1)
        #expect(try events(matchId).last?.eventType == EventType.highlightMarked.rawValue)

        send(["command": "incrementP2"])
        #expect(manager.scoreState.pendingHighlight == nil)
        let clip = try #require(manager.scoreState.highlightClips.first)
        #expect(clip.id == pending.id && clip.player == 2 && clip.gameNumber == 0)

        let all = try events(matchId)
        let expectedTypes: [EventType] = [
            .matchStarted, .pointScored, .highlightMarked, .pointScored, .highlightAttributed,
        ]
        #expect(all.map(\.eventType) == expectedTypes.map(\.rawValue))
        let attributed = try decode(HighlightAttributedEvent.self, all.last)
        #expect(attributed.highlightEventId == pending.id && attributed.player == 2)
    }

    // With the camera disabled setMatchName leaves currentVideoURL nil, and startRecording() guards on it before
    // it arms any recording state. So isRecording stays false, recordPoint/markHighlight are skipped (GameResult.points
    // is empty, highlights are dropped) and the watch, which shows scoring only while isRecording, never does.
    @Test("startRecording arms recording state when the camera is disabled")
    func recordingWithoutCamera() throws {
        UserPreferencesService(modelContext: container.mainContext).setCameraEnabled(false)
        try startMatch()
        manager.startRecording()
        #expect(manager.isRecording && manager.scoreState.isRecording)
        manager.incrementPlayer1()
        manager.markHighlight()
        #expect(manager.scoreState.currentGamePoints.count == 1 && manager.scoreState.pendingHighlight != nil)
    }

    // MARK: - Watch messages

    @Test("WatchMessageData separates commands from full state payloads")
    func messageParsing() {
        let command = WatchMessageData(from: ["command": "endGame"])
        #expect(command.command == "endGame" && command.scoreState == nil)
        let state = WatchMessageData(from: ScoreState(playerOneScore: 3, playerTwoScore: 2).toDictionary())
        #expect(state.command == nil && state.scoreState?.playerOneScore == 3)
    }

    @Test(
        "Score commands score a point; requestSync and unknown commands leave state alone",
        arguments: [("incrementP1", 1, 0), ("incrementP2", 0, 1), ("requestSync", 0, 0), ("teleport", 0, 0)])
    func watchCommand(command: String, p1: Int, p2: Int) throws {
        let matchId = try startMatch()
        send(["command": command])
        #expect(manager.isWatchAppInstalled)
        #expect(manager.scoreState.playerOneScore == p1 && manager.scoreState.playerTwoScore == p2)
        #expect(try events(matchId).count == 1 + p1 + p2)
    }

    @Test("endMatch command only raises the signal for GameView; the match stays active")
    func endMatchCommand() throws {
        let matchId = try startMatch()
        send(["command": "endMatch"])
        #expect(manager.endMatchRequestCount > 0 && manager.currentMatchId == matchId)
        #expect(try eventStore.getMatch(id: matchId)?.isActive == true)
        #expect(manager.scoreState.matchHistory.isEmpty)
    }

    @Test("Command-less payloads never append events, and one that is not a ScoreState is dropped")
    func statePayloadAppendsNothing() throws {
        let matchId = try startMatch()
        send(["playerOneScore": 9])  // no playerTwoScore: ScoreState(dictionary:) fails, nothing changes
        #expect(manager.scoreState.playerOneScore == 0)
        send(["playerOneScore": 7, "playerTwoScore": 4])
        #expect(try events(matchId).count == 1)
    }

    // The phone is the source of truth and the watch only sends commands (its sendScore() has no callers), yet
    // handleMessageData still assigns any command-less payload that decodes as a ScoreState straight to
    // scoreState. That drops highlightClips, pendingHighlight and the names, and leaves scoreState out of step
    // with the event store and the manager's private game/highlight bookkeeping. Latent today; live the moment
    // an older watch build (or a reinstated sendScore) pushes its state up.
    @Test("A full score payload from the watch does not overwrite the phone's event-sourced state")
    func statePayloadDoesNotOverwrite() throws {
        try startMatch()
        let before = manager.scoreState
        send([
            "playerOneScore": 7, "playerTwoScore": 4, "playerOneGames": 1, "servingPlayer": 2, "playerOneName": "Zed",
        ])
        let after = manager.scoreState
        #expect(after.playerOneScore == 0 && after.playerTwoScore == 0 && after.playerOneGames == 0)
        #expect(after.servingPlayer == before.servingPlayer)
        #expect(after.playerOneName == "Ann" && after.playerTwoName == "Bob" && after.currentMatchName == "Ann vs Bob")
    }

    // MARK: - Match end

    @Test("cancelMatch deletes the match and its events and resets state")
    func cancelMatch() async throws {
        let matchId = try startMatch()
        manager.startRecording()
        score([1, 2, 1])

        await manager.cancelMatch()

        #expect(try eventStore.getMatch(id: matchId) == nil && eventStore.getActiveMatch() == nil)
        #expect(try events(matchId).isEmpty)
        #expect(manager.currentMatchId == nil && !manager.isRecording && !manager.scoreState.isRecording)
        let state = manager.scoreState
        #expect(state.playerOneScore == 0 && state.playerTwoScore == 0 && state.currentGamePoints.isEmpty)
        #expect(state.playerOneName == nil && state.currentMatchName == nil)
    }

    @Test("endMatch auto-ends the open game, persists the result, appends history and resets")
    func endMatch() throws {
        let matchId = try startMatch()
        manager.startRecording()
        score(Array(repeating: 1, count: 11))
        manager.endGame()
        score(Array(repeating: 1, count: 11))
        manager.endGame()
        score([2, 2, 2])  // open, unfinished game: discarded, never awarded

        manager.endMatch(fullVideoURL: nil, highlightVideoURL: nil)

        let result = try #require(manager.scoreState.matchHistory.first)
        #expect(manager.scoreState.matchHistory.count == 1 && result.name == "Ann vs Bob")
        #expect(result.id == matchId && result.playerOneName == "Ann" && result.playerTwoName == "Bob")
        #expect(result.playerOneGames == 2 && result.playerTwoGames == 0 && result.winner == 1)
        #expect(result.games.count == 2 && result.totalPoints == 22)

        let stored = try #require(try eventStore.getMatch(id: matchId))
        #expect(!stored.isActive && stored.endTimestamp != nil)
        #expect(stored.playerOneGames == 2 && stored.playerTwoGames == 0 && stored.winner == 1)
        #expect(try eventStore.getActiveMatch() == nil)

        let all = try events(matchId)
        #expect(all.map(\.sequenceNumber) == Array(0..<all.count))
        #expect(all.filter { $0.eventType == EventType.gameEnded.rawValue }.count == 2)
        #expect(all.last?.eventType == EventType.matchEnded.rawValue)
        let ended = try decode(MatchEndedEvent.self, all.last)
        #expect(ended.playerOneGames == 2 && ended.playerTwoGames == 0 && ended.winner == 1)

        #expect(manager.currentMatchId == nil && !manager.isRecording && !manager.scoreState.isRecording)
        #expect(manager.scoreState.playerOneGames == 0 && manager.scoreState.currentMatchGames.isEmpty)
        #expect(manager.scoreState.playerOneName == nil && manager.scoreState.currentMatchName == nil)

        try startMatch("Rematch")  // history survives the reset: the loser serves first next time
        #expect(manager.scoreState.matchHistory.count == 1 && manager.scoreState.servingPlayer == 2)
    }

    // endGame() picks `winner = p1 > p2 ? 1 : 2`, so a tied game (including 0-0 from a stray watch endGame)
    // is credited to player 2, and endMatch() auto-ends any open game with points in it. With games 1-0 and the
    // open game tied, player 2 is handed the game and, via the same `>` test at match level, the match.
    @Test("endMatch with a tied open game does not hand the game and the match to player 2")
    func endMatchTiedOpenGame() throws {
        try startMatch()
        score(Array(repeating: 1, count: 11))
        manager.endGame()
        score([1, 2, 1, 2])  // open game tied 2-2

        manager.endMatch(fullVideoURL: nil, highlightVideoURL: nil)

        let result = try #require(manager.scoreState.matchHistory.first)
        #expect(result.winner == 1)
        #expect(result.playerOneGames == 1)
    }

    // MARK: - Delivery (actionId dedupe)

    /// A command as the current watch build sends it (`WatchCommand.payload` in the watch target).
    nonisolated private static func watchCommand(
        _ command: String, actionId: String = UUID().uuidString, sentAt: Date = Date()
    ) -> [String: Any] {
        ["command": command, "actionId": actionId, "sentAt": sentAt.timeIntervalSince1970]
    }

    @discardableResult
    private func deliver(_ message: [String: Any], via delivery: WatchDelivery) -> Bool {
        manager.receiveFromWatch(WatchMessageData(from: message), via: delivery)
    }

    // The watch re-queues a live command with transferUserInfo when sendMessage errors, which includes a reply
    // timeout after the phone already applied it; so one tap can arrive by either path, or both.
    @Test(
        "The same actionId delivered twice scores one point, whichever paths carry it",
        arguments: [
            (WatchDelivery.message, WatchDelivery.message), (.message, .userInfo), (.userInfo, .message),
            (.userInfo, .userInfo),
        ])
    func duplicateActionIdScoresOnce(first: WatchDelivery, second: WatchDelivery) throws {
        let matchId = try startMatch()
        let tap = Self.watchCommand("incrementP1")

        #expect(deliver(tap, via: first))
        #expect(!deliver(tap, via: second))
        #expect(manager.scoreState.playerOneScore == 1 && manager.scoreState.playerTwoScore == 0)
        #expect(try events(matchId).count == 2)

        #expect(deliver(Self.watchCommand("incrementP1"), via: second))  // a new tap has a new id and scores
        #expect(manager.scoreState.playerOneScore == 2)
    }

    @Test("Commands without an actionId (older watch builds) still work, every time they arrive")
    func commandWithoutActionId() throws {
        let matchId = try startMatch()
        let legacy: [String: Any] = ["command": "incrementP2"]
        let parsed = WatchMessageData(from: legacy)
        #expect(parsed.command == "incrementP2" && parsed.actionId == nil && parsed.sentAt == nil)

        #expect(deliver(legacy, via: .message))
        #expect(deliver(legacy, via: .applicationContext))
        #expect(manager.scoreState.playerTwoScore == 2)
        #expect(try events(matchId).count == 3)
    }

    @Test("A command queued with transferUserInfo scores when it arrives, however late")
    func userInfoCommandScores() throws {
        let matchId = try startMatch()
        let sentAt = Date(timeIntervalSinceNow: -90)  // tapped while the phone was out of range
        let actionId = UUID().uuidString
        let userInfo = Self.watchCommand("incrementP2", actionId: actionId, sentAt: sentAt)
        let parsed = WatchMessageData(from: userInfo)
        #expect(parsed.actionId == actionId && parsed.sentAt == sentAt.timeIntervalSince1970)

        #expect(deliver(userInfo, via: .userInfo))
        #expect(manager.isWatchAppInstalled)
        #expect(manager.scoreState.playerOneScore == 0 && manager.scoreState.playerTwoScore == 1)
        let point = try decode(PointScoredEvent.self, try events(matchId).last)
        #expect(point.player == 2)
    }

    // transferUserInfo keeps a tap queued for as long as the watch is out of range, so it can arrive after its
    // match ended and the next one started. Applied then, it would score in (or, for endMatch, end) the new match.
    @Test("A queued command issued before the current match began recording is dropped")
    func commandFromEarlierMatchIsDropped() throws {
        let matchId = try startMatch()
        manager.startRecording()
        let recordingStart = try #require(manager.scoreState.recordingStartTime)
        let lastMatch = recordingStart.addingTimeInterval(-60)

        #expect(!deliver(Self.watchCommand("incrementP1", sentAt: lastMatch), via: .userInfo))
        #expect(!deliver(Self.watchCommand("endMatch", sentAt: lastMatch), via: .userInfo))
        #expect(manager.scoreState.playerOneScore == 0 && manager.endMatchRequestCount == 0)
        #expect(try events(matchId).count == 1)
        #expect(deliver(Self.watchCommand("requestSync", sentAt: lastMatch), via: .message))  // always answered

        // Within the clock-skew allowance of the start, and any time after it, commands apply.
        let skewed = recordingStart.addingTimeInterval(-WatchConnectivityManager.watchClockSkewAllowance / 2)
        #expect(deliver(Self.watchCommand("incrementP1", sentAt: skewed), via: .userInfo))
        #expect(deliver(Self.watchCommand("incrementP2"), via: .message))
        #expect(manager.scoreState.playerOneScore == 1 && manager.scoreState.playerTwoScore == 1)
        #expect(try events(matchId).count == 3)
    }

    @Test("RecentActionIDs remembers the last `capacity` ids and forgets the oldest first")
    func recentActionIdsAreBounded() {
        var recent = RecentActionIDs(capacity: 3)
        let ids = ["a", "b", "c", "a", "d", "a", "c", "d", "b"]
        let isNew = ids.map { recent.insert($0) }
        // "a" is a duplicate while remembered; "d" evicts it, so it is new again (evicting "b"), and so on.
        #expect(isNew == [true, true, true, false, true, true, false, false, true])
    }
}
