//
//  ScoreStateTests.swift
//  scoreTests
//
//  ScoreState / WatchSyncState models: statistics, the phone<->watch dictionary contract and JSON persistence.
//

import Foundation
import Testing

@testable import score

@Suite("ScoreState")
struct ScoreStateTests {
    // MARK: - Fixtures

    /// State keys parsed by `MessageData.init(from:)` in `scorewatch Watch App/WatchSessionManager.swift`.
    /// (`highlightConfirmed` is also parsed there, but the phone adds it on top of this payload for one message.)
    private static let watchKeys: Set<String> = [
        "playerOneScore", "playerTwoScore", "playerOneGames", "playerTwoGames", "isRecording",
        "playerOneName", "playerTwoName", "servingPlayer", "currentGameFirstServer", "recordingStartTime",
        "currentMatchGames", "currentGamePoints", "highlightCount", "hasPendingHighlight",
    ]
    private static let startTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// One point: who won it and who was serving. Servers are written out by hand so these fixtures do not depend
    /// on `ServingLogic` (which has its own suite).
    private typealias Point = (scorer: Int, server: Int)

    /// An 11-4 game with P1 serving first. The serve alternates every 2 points, so P1 serves 8 and P2 serves 7;
    /// the scorer was serving on 6 of P1's 11 points and on 2 of P2's 4.
    private static let elevenFour: [Point] = [
        (1, 1), (1, 1), (2, 2), (2, 2), (1, 1), (2, 1), (1, 2), (1, 2), (2, 1), (1, 1), (1, 2), (1, 2), (1, 1), (1, 1),
        (1, 2),
    ]

    private static func makeGame(
        _ sequence: [Point], duration: TimeInterval? = nil, videoTimes: [Double?] = []
    ) -> GameResult {
        var p1 = 0, p2 = 0
        var points: [PointEvent] = []
        for (index, point) in sequence.enumerated() {
            let video = index < videoTimes.count ? videoTimes[index] : nil
            points.append(
                PointEvent(
                    player: point.scorer, timestamp: startTime, videoTimestamp: video,
                    wasServing: point.scorer == point.server))
            if point.scorer == 1 { p1 += 1 } else { p2 += 1 }
        }
        return GameResult(
            playerOneScore: p1, playerTwoScore: p2, winner: p1 > p2 ? 1 : 2, timestamp: startTime, points: points,
            duration: duration, firstServer: sequence.first?.server ?? 1)
    }

    /// A state with every field populated, so round-trips prove each one survives.
    private static func fullState() -> ScoreState {
        let game = makeGame(elevenFour, duration: 120, videoTimes: [1, 5.5, 9])
        let previous = MatchResult(
            name: "Old", playerOneGames: 3, playerTwoGames: 0, winner: 1, games: [game], timestamp: startTime,
            fullVideoURL: "full.mov", highlightVideoURL: "hl.mov", duration: 600)
        let point = PointEvent(player: 1, timestamp: startTime, isHighlight: true, videoTimestamp: 12.5)
        return ScoreState(
            playerOneScore: 7, playerTwoScore: 5, playerOneGames: 1, playerTwoGames: 0,
            currentMatchGames: [game], matchHistory: [previous], currentGamePoints: [point],
            highlightClips: [HighlightClip(startTimestamp: 1, endTimestamp: 5, player: 1, gameNumber: 0)],
            pendingHighlight: HighlightClip(startTimestamp: 20, endTimestamp: 25, gameNumber: 1),
            isRecording: true, recordingStartTime: startTime, currentMatchName: "Ann vs Bob",
            playerOneName: "Ann", playerTwoName: "Bob", servingPlayer: 2, currentGameFirstServer: 2)
    }

    private static let minimalWatchSync = WatchSyncState(
        playerOneScore: 1, playerTwoScore: 2, playerOneGames: 0, playerTwoGames: 0, isRecording: false)

    /// `[p1Score, p2Score, p1Games, p2Games]`, so a whole scoreboard is one expectation.
    private static func scoreboard(_ state: ScoreState) -> [Int] {
        [state.playerOneScore, state.playerTwoScore, state.playerOneGames, state.playerTwoGames]
    }

    /// Deterministic JSON so non-Equatable models can be compared structurally.
    private static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private static func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: - Phone <-> watch dictionary contract

    @Test("Dictionary payload round-trips every synced field; highlight clips are only synced as counts")
    func dictionaryRoundTrip() throws {
        let original = Self.fullState()
        let dict = original.toDictionary()
        let restored = try #require(ScoreState(dictionary: dict))
        #expect(Self.scoreboard(restored) == [7, 5, 1, 0])
        #expect(restored.isRecording && restored.recordingStartTime == Self.startTime)
        #expect(restored.playerOneName == "Ann" && restored.playerTwoName == "Bob" && restored.servingPlayer == 2)
        #expect(restored.currentMatchName == "Ann vs Bob" && restored.currentGameFirstServer == 2)
        #expect(try Self.json(restored.currentMatchGames) == Self.json(original.currentMatchGames))
        #expect(restored.matchHistory.isEmpty)  // match history is phone-only (unbounded, never sent)
        #expect(try Self.json(restored.currentGamePoints) == Self.json(original.currentGamePoints))
        // Clips are phone-only state: the watch receives a count and a pending flag instead
        #expect(dict["highlightCount"] as? Int == 2 && dict["hasPendingHighlight"] as? Bool == true)
        #expect(restored.highlightClips.isEmpty && restored.pendingHighlight == nil && !restored.hasPendingHighlight)
    }

    @Test("Dictionary has exactly the keys the watch parses (plus currentMatchName), as property-list values")
    func dictionaryContract() {
        let dict = Self.fullState().toDictionary()
        // currentMatchName is sent but the watch ignores it
        #expect(Set(dict.keys) == Self.watchKeys.union(["currentMatchName"]))
        // nil optionals are omitted rather than sent as NSNull
        let nilOmitted: Set<String> = [
            "playerOneName", "playerTwoName", "currentGameFirstServer", "recordingStartTime",
        ]
        #expect(Set(ScoreState().toDictionary().keys) == Self.watchKeys.subtracting(nilOmitted))
        #expect(PropertyListSerialization.propertyList(dict, isValidFor: .binary))
        for (key, value) in dict {
            #expect(value is NSNumber || value is String || value is Data, "\(key) is \(type(of: value))")
        }
        #expect(dict["recordingStartTime"] as? TimeInterval == Self.startTime.timeIntervalSince1970)
        #expect(dict["currentMatchGames"] is Data && dict["currentGamePoints"] is Data && dict["matchHistory"] == nil)
    }

    @Test(
        "Parsing requires both scores",
        arguments: [[:], ["playerOneScore": 3], ["playerTwoScore": 3], ["playerOneScore": "3", "playerTwoScore": 3]]
            as [[String: any Sendable]])
    func parsingRequiresBothScores(input: [String: any Sendable]) {
        #expect(ScoreState(dictionary: input) == nil)
    }

    @Test("Missing optional keys and undecodable payloads fall back to defaults")
    func parsingDefaults() throws {
        let state = try #require(
            ScoreState(dictionary: ["playerOneScore": 4, "playerTwoScore": 2, "matchHistory": Data("nope".utf8)]))
        #expect(Self.scoreboard(state) == [4, 2, 0, 0])
        #expect(!state.isRecording && state.recordingStartTime == nil)
        #expect(state.servingPlayer == 1 && state.currentGameFirstServer == nil)
        #expect(state.playerOneName == nil && state.playerTwoName == nil && state.currentMatchName == nil)
        #expect(state.currentMatchGames.isEmpty && state.matchHistory.isEmpty && state.currentGamePoints.isEmpty)
    }

    @Test("forNewMatch keeps only match history and resets all match-scoped state")
    func forNewMatch() throws {
        let previous = Self.fullState()
        let fresh = ScoreState.forNewMatch(
            preservingHistoryFrom: previous, matchName: "Cat vs Dog", playerOneName: "Cat", playerTwoName: "Dog",
            initialServer: 2, recordingStartTime: Self.startTime)
        #expect(try Self.json(fresh.matchHistory) == Self.json(previous.matchHistory))
        #expect(Self.scoreboard(fresh) == [0, 0, 0, 0])
        #expect(fresh.currentMatchGames.isEmpty && fresh.currentGamePoints.isEmpty && fresh.highlightClips.isEmpty)
        #expect(fresh.currentMatchName == "Cat vs Dog" && fresh.playerOneName == "Cat" && fresh.playerTwoName == "Dog")
        #expect(fresh.servingPlayer == 2 && fresh.currentGameFirstServer == 2 && fresh.pendingHighlight == nil)
        #expect(!fresh.isRecording && fresh.recordingStartTime == Self.startTime)  // startRecording() marks it live

        let idle = ScoreState.forNewMatch(
            preservingHistoryFrom: previous, matchName: "", playerOneName: "", playerTwoName: "", initialServer: 1)
        #expect(!idle.isRecording && idle.recordingStartTime == nil)
    }

    @Test("Highlight counters: current game filters by game number, match total includes the pending clip")
    func highlightCounters() {
        let clips = [0, 1, 1].map { HighlightClip(startTimestamp: 0, endTimestamp: 1, player: 1, gameNumber: $0) }
        // One finished game, so the game in progress is index 1 (WatchConnectivityManager stamps clips with
        // currentMatchGames.count)
        var state = ScoreState(currentMatchGames: [Self.makeGame([(1, 1), (1, 1), (1, 2)])], highlightClips: clips)
        #expect(state.totalHighlightsInCurrentGame == 2 && state.totalHighlightsInMatch == 3)
        state.pendingHighlight = HighlightClip(startTimestamp: 6, endTimestamp: 7, gameNumber: 1)
        #expect(state.totalHighlightsInCurrentGame == 2 && state.totalHighlightsInMatch == 4)
        #expect(state.hasPendingHighlight && !ScoreState().hasPendingHighlight)
        #expect(ScoreState().totalHighlightsInMatch == 0 && ScoreState().totalHighlightsInCurrentGame == 0)
    }

    // MARK: - GameResult / MatchResult statistics

    @Test(
        "Average point time averages gaps between consecutive points that both have video timestamps",
        arguments: [
            ([], nil), ([10], nil), ([10, 14, 20], 5), ([10, nil, 20], nil), ([10, 14, nil, 30], 4),
        ] as [([Double?], Double?)])
    func averagePointTime(videoTimes: [Double?], expected: Double?) {
        let game = Self.makeGame(
            Array(repeating: (scorer: 1, server: 1), count: videoTimes.count), videoTimes: videoTimes)
        #expect(game.averagePointTime == expected)
    }

    @Test("Match statistics aggregate per-game serve stats and skip missing values")
    func matchStatistics() {
        let games = [
            Self.makeGame(Self.elevenFour, duration: 120, videoTimes: [0, 4, 8]),
            Self.makeGame([(2, 2), (2, 2), (2, 1)]),  // 0-3, P2 serves first: wins 2 on serve, 1 on P1's serve
            Self.makeGame([(1, 1), (1, 1)], duration: 60, videoTimes: [0, 2]),  // 2-0, both on serve
        ]
        // Fixture sanity: the hand-written 11-4 sequence really is 11-4 with 6 and 2 points won on serve
        #expect(games[0].playerOneScore == 11 && games[0].playerTwoScore == 4 && games[0].winner == 1)
        #expect(games[0].pointsWonOnServeP1 == 6 && games[0].pointsWonOnServeP2 == 2)
        #expect(games[1].pointsWonOnServeP1 == 0 && games[1].pointsWonOnServeP2 == 2)

        let match = MatchResult(playerOneGames: 2, playerTwoGames: 1, winner: 1, games: games)
        #expect(match.totalPoints == 20)
        #expect(match.averageGameTime == 90 && match.averagePointTime == 3)
        #expect(match.totalPointsWonOnServeP1 == 8 && match.totalPointsWonOnServeP2 == 4)

        let empty = MatchResult(playerOneGames: 0, playerTwoGames: 0, winner: 1, games: [])
        #expect(empty.totalPoints == 0 && empty.averageGameTime == nil && empty.averagePointTime == nil)
        #expect(empty.totalPointsWonOnServeP1 == 0 && empty.totalPointsWonOnServeP2 == 0)
    }

    @Test("Serve win percentage is points won on serve over serves taken; nil without games")
    func serveWinPercentage() throws {
        // 0-3 with P2 serving first (P2 serves points 1-2, P1 point 3) and 2-0 with P1 serving first.
        // P1: 2 won of 3 serves; P2: 2 won of 2. Shut-outs are the one shape for which today's
        // ServingLogic.calculateTotalServes matches the real rotation (see serveWinPercentageUsesActualServes),
        // so this holds before and after that fix.
        let games = [Self.makeGame([(2, 2), (2, 2), (2, 1)]), Self.makeGame([(1, 1), (1, 1)])]
        let match = MatchResult(playerOneGames: 1, playerTwoGames: 1, winner: 1, games: games)
        #expect(abs(try #require(match.serveWinPercentageP1) - 200.0 / 3.0) < 1e-9)
        #expect(match.serveWinPercentageP2 == 100)

        let empty = MatchResult(playerOneGames: 0, playerTwoGames: 0, winner: 1, games: [])
        #expect(empty.serveWinPercentageP1 == nil && empty.serveWinPercentageP2 == nil)
    }

    @Test("Serve win percentage divides by the serves each player actually took")
    func serveWinPercentageUsesActualServes() throws {
        let game = Self.makeGame(Self.elevenFour)
        let match = MatchResult(playerOneGames: 1, playerTwoGames: 0, winner: 1, games: [game])
        #expect(match.serveWinPercentageP1 == 75)
        #expect(abs(try #require(match.serveWinPercentageP2) - 200.0 / 7.0) < 1e-9)
    }

    // MARK: - WatchSyncState (not used by the live protocol yet; see AGENTS.md)

    @Test("WatchSyncState dictionary round-trips, optionals omitted when nil")
    func watchSyncStateRoundTrip() throws {
        let original = WatchSyncState(
            playerOneScore: 9, playerTwoScore: 11, playerOneGames: 1, playerTwoGames: 2, isRecording: true,
            playerOneName: "Ann", playerTwoName: "Bob", highlightCountInCurrentGame: 1, highlightCountInMatch: 4,
            confirmedActionId: "abc")
        let dict = original.toDictionary()
        #expect(PropertyListSerialization.propertyList(dict, isValidFor: .binary))
        let parsed = try #require(WatchSyncState(dictionary: dict))
        #expect(parsed.playerOneScore == 9 && parsed.playerTwoScore == 11 && parsed.isRecording)
        #expect(parsed.playerOneGames == 1 && parsed.playerTwoGames == 2)
        #expect(parsed.playerOneName == "Ann" && parsed.playerTwoName == "Bob" && parsed.confirmedActionId == "abc")
        #expect(parsed.highlightCountInCurrentGame == 1 && parsed.highlightCountInMatch == 4)

        let minimalDict = Self.minimalWatchSync.toDictionary()
        #expect(Set(minimalDict.keys).isDisjoint(with: ["playerOneName", "playerTwoName", "confirmedActionId"]))
        let minimal = try #require(WatchSyncState(dictionary: minimalDict))
        #expect(minimal.playerOneName == nil && minimal.playerTwoName == nil && minimal.confirmedActionId == nil)
        #expect(minimal.highlightCountInCurrentGame == 0 && minimal.highlightCountInMatch == 0)
    }

    @Test(
        "WatchSyncState parsing fails when a required key is missing",
        arguments: ["playerOneScore", "playerTwoScore", "playerOneGames", "playerTwoGames", "isRecording"])
    func watchSyncStateMissingKey(key: String) {
        var dict = Self.minimalWatchSync.toDictionary()
        dict.removeValue(forKey: key)
        #expect(WatchSyncState(dictionary: dict) == nil)
    }

    // MARK: - JSON persistence

    @Test("ScoreState, PointEvent, HighlightClip, GameResult and MatchResult round-trip through JSON")
    func jsonRoundTrips() throws {
        let state = Self.fullState()
        let restoredState = try Self.roundTrip(state)
        #expect(try Self.json(restoredState) == Self.json(state))
        #expect(restoredState.highlightClips.count == 1 && restoredState.totalHighlightsInMatch == 2)

        let point = try Self.roundTrip(
            PointEvent(player: 2, timestamp: Self.startTime, isHighlight: true, videoTimestamp: 3.25, wasServing: true))
        #expect(point.player == 2 && point.isHighlight && point.wasServing)
        #expect(point.videoTimestamp == 3.25 && point.timestamp == Self.startTime)

        let clip = HighlightClip(startTimestamp: 1.5, endTimestamp: 4, player: nil, gameNumber: 2)
        let restoredClip = try Self.roundTrip(clip)
        #expect(restoredClip.id == clip.id && restoredClip.player == nil && restoredClip.gameNumber == 2)
        #expect(restoredClip.startTimestamp == 1.5 && restoredClip.endTimestamp == 4)

        let match = try Self.roundTrip(try #require(state.matchHistory.first))
        #expect(match.name == "Old" && match.fullVideoURL == "full.mov" && match.highlightVideoURL == "hl.mov")
        #expect(match.duration == 600 && match.winner == 1 && match.timestamp == Self.startTime)
        let game = try #require(match.games.first)
        #expect(game.playerOneScore == 11 && game.playerTwoScore == 4 && game.winner == 1)
        #expect(game.firstServer == 1 && game.duration == 120 && game.points.count == 15)
        #expect(game.points[1].videoTimestamp == 5.5 && game.points[3].videoTimestamp == nil)
    }

    @Test("Phone models decode the watch's JSON, which has no duration/name/fullVideoURL fields")
    func decodesWatchShapedJSON() throws {
        // Shapes copied from `scorewatch Watch App/ScoreState.swift`, whose GameResult/MatchResult lack these fields
        let watchGame =
            #"{"playerOneScore":11,"playerTwoScore":7,"winner":1,"timestamp":0,"points":[],"firstServer":2}"#
        let game = try JSONDecoder().decode(GameResult.self, from: Data(watchGame.utf8))
        #expect(game.duration == nil && game.firstServer == 2 && game.points.isEmpty)

        let watchMatch = #"{"playerOneGames":3,"playerTwoGames":1,"winner":1,"games":[],"timestamp":0}"#
        let match = try JSONDecoder().decode(MatchResult.self, from: Data(watchMatch.utf8))
        #expect(match.name == nil && match.fullVideoURL == nil && match.highlightVideoURL == nil)
        #expect(match.duration == nil && match.playerOneGames == 3)
    }
}
