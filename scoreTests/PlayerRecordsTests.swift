//
//  PlayerRecordsTests.swift
//  scoreTests
//
//  PlayerRecords (leaderboard, per-player and per-opponent records, matches) and HeadToHead.between: the rules
//  behind the Stats pages.
//

import Foundation
import Testing

@testable import score

@Suite("PlayerRecords")
struct PlayerRecordsTests {
    /// A finished match a day after the previous one; `winner` defaults to whoever won more games (none on a tie).
    /// `points` are the games' scores (player one first); without them the match records no games.
    private static func match(
        _ playerOne: String?, _ playerTwo: String?, _ gamesOne: Int, _ gamesTwo: Int, winner: Int? = nil,
        points: [(Int, Int)] = [], day: Int = 0, name: String? = nil
    ) -> MatchResult {
        let decided = gamesOne == gamesTwo ? MatchResult.noWinner : (gamesOne > gamesTwo ? 1 : 2)
        let games = points.map { GameResult(playerOneScore: $0.0, playerTwoScore: $0.1, winner: $0.0 > $0.1 ? 1 : 2) }
        return MatchResult(
            name: name, playerOneName: playerOne, playerTwoName: playerTwo, playerOneGames: gamesOne,
            playerTwoGames: gamesTwo, winner: winner ?? decided, games: games,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
    }

    // MARK: - Leaderboard

    @Test func emptyHistoryHasNoPlayers() {
        let records = PlayerRecords(history: [])
        #expect(records.leaderboard.isEmpty)
        #expect(records.latestPair == nil)
        #expect(records.matches(of: "alex").isEmpty)
        #expect(records.opponents(of: "alex").isEmpty)
    }

    @Test func leaderboardRanksByWinRate() {
        let history = [
            Self.match("Alex", "Lucio", 3, 1),  // Alex 1-0
            Self.match("Mia", "Sam", 3, 0),  // Mia 1-0
            Self.match("Alex", "Mia", 1, 3),  // Alex 1-1, Mia 2-0
            Self.match("Sam", "Lucio", 3, 2),  // Sam 1-1, Lucio 0-2
        ]
        let board = PlayerRecords(history: history).leaderboard
        #expect(board.map(\.name) == ["Mia", "Alex", "Sam", "Lucio"])
        #expect(board.map(\.winRate) == [1, 0.5, 0.5, 0])
    }

    @Test func tiesOnWinRateGoToMoreWinsThenFewerLossesThenName() {
        let history = [
            // Bea 2-0 and Cal 1-0 are both at 100 %: Bea has more wins
            Self.match("Bea", "Dan", 3, 0), Self.match("Bea", "Eve", 3, 0), Self.match("Cal", "Dan", 3, 0),
            // Dan 0-2 + 0-1 draw, Eve 0-1 and Fay 0-1: all at 0 %, Eve and Fay have fewer losses than Dan
            Self.match("Dan", "Fay", 1, 1),
            Self.match("Fay", "Gus", 0, 3),
        ]
        let board = PlayerRecords(history: history).leaderboard
        #expect(board.map(\.name) == ["Bea", "Cal", "Gus", "Eve", "Fay", "Dan"])
    }

    @Test func drawsCountAsPlayedNotWon() throws {
        let history = [
            Self.match("Alex", "Lucio", 3, 1),
            Self.match("Alex", "Lucio", 2, 1, winner: MatchResult.noWinner),  // abandoned
            Self.match("Alex", "Lucio", 0, 3),
            Self.match("Alex", "Lucio", 3, 2),
        ]
        let alex = try #require(PlayerRecords(history: history).player("alex"))
        #expect((alex.wins, alex.losses, alex.draws, alex.matchesPlayed) == (2, 1, 1, 4))
        #expect(alex.winRate == 0.5)
    }

    @Test func gamesAndPointsAreSummedFromEachSide() throws {
        let history = [
            Self.match("Alex", "Lucio", 2, 1, points: [(11, 7), (9, 11), (11, 9)]),
            Self.match("Lucio", "Alex", 1, 0, points: [(11, 5)]),
        ]
        let records = PlayerRecords(history: history)
        let alex = try #require(records.player("alex"))
        #expect((alex.gamesWon, alex.gamesLost) == (2, 2))
        #expect((alex.pointsWon, alex.pointsLost) == (36, 38))
        let lucio = try #require(records.player("lucio"))
        #expect((lucio.gamesWon, lucio.gamesLost, lucio.pointsWon, lucio.pointsLost) == (2, 2, 38, 36))
    }

    // MARK: - Identity

    @Test func identityIgnoresCaseWhitespaceAndOrderAndKeepsTheLatestSpelling() throws {
        let history = [
            Self.match("alex", "Lucio", 3, 0),
            Self.match(" LUCIO ", "Alex  ", 3, 1),
            Self.match("Lucio", "Alex", 0, 3),
        ]
        let records = PlayerRecords(history: history)
        #expect(records.leaderboard.count == 2)
        let alex = try #require(records.player("alex"))
        #expect(alex.name == "Alex")
        #expect((alex.wins, alex.losses) == (2, 1))
        #expect(records.player("lucio")?.name == "Lucio")
    }

    @Test func matchesWithoutTwoPlayersCountForNobody() {
        let history = [
            Self.match(nil, nil, 3, 0),
            Self.match(" ", "Lucio", 3, 0),
            Self.match("Alex", nil, 0, 3, name: "Solo practice"),
            Self.match("Alex", "alex ", 3, 1),  // the same person on both sides
            Self.match(nil, nil, 3, 1, name: "Mia vs Sam - 2 Oct 2026 at 10:00"),  // legacy: names in the match name
        ]
        let records = PlayerRecords(history: history)
        #expect(records.leaderboard.map(\.name) == ["Mia", "Sam"])
        #expect(records.played.map(\.historyIndex) == [4])
        #expect(records.latestPair.map { [$0.playerOne, $0.playerTwo] } == ["mia", "sam"])
    }

    // MARK: - Streak and form

    @Test func streakIsTheRunOfIdenticalResultsAtTheEnd() throws {
        let history = [
            Self.match("Alex", "Lucio", 0, 3),
            Self.match("Alex", "Lucio", 3, 0),
            Self.match("Lucio", "Alex", 0, 3),
            Self.match("Alex", "Mia", 3, 2),
        ]
        let records = PlayerRecords(history: history)
        #expect(records.player("alex")?.streak == PlayerStreak(outcome: .win, count: 3))
        #expect(records.player("lucio")?.streak == PlayerStreak(outcome: .loss, count: 2))
        #expect(records.player("mia")?.streak == PlayerStreak(outcome: .loss, count: 1))
        let drawn = PlayerRecords(history: history + [Self.match("Alex", "Lucio", 1, 1)])
        #expect(drawn.player("alex")?.streak == PlayerStreak(outcome: .draw, count: 1))
    }

    @Test func formIsTheLastFiveResultsOldestFirst() throws {
        let results: [(Int, Int)] = [(3, 0), (3, 0), (0, 3), (3, 1), (1, 1), (0, 3), (3, 2)]
        let history = results.map { Self.match("Alex", "Lucio", $0.0, $0.1) }
        let alex = try #require(PlayerRecords(history: history).player("alex"))
        #expect(alex.form == [.loss, .win, .draw, .loss, .win])
        let short = try #require(PlayerRecords(history: Array(history.prefix(2))).player("lucio"))
        #expect(short.form == [.loss, .loss])
    }

    // MARK: - A player's matches and opponents

    @Test func playerMatchesAreNewestFirstFromTheirSide() {
        let history = [
            Self.match("Alex", "Lucio", 3, 1, day: 1),
            Self.match("Mia", "Sam", 3, 0, day: 2),
            Self.match("lucio", "ALEX", 3, 2, day: 3),
        ]
        let matches = PlayerRecords(history: history).matches(of: "alex")
        #expect(matches.map(\.historyIndex) == [2, 0])
        #expect(matches.map(\.opponentName) == ["lucio", "lucio"])  // the latest spelling, in every row
        #expect(matches.map(\.outcome) == [.loss, .win])
        #expect(matches.map { [$0.gamesWon, $0.gamesLost] } == [[2, 3], [3, 1]])
    }

    @Test func opponentRecordsAreMostPlayedFirst() {
        let history = [
            Self.match("Alex", "Mia", 3, 0),
            Self.match("Lucio", "Alex", 3, 0),
            Self.match("Alex", "Lucio", 3, 2),
            Self.match("Alex", "Lucio", 1, 1),
            Self.match("Sam", "Alex", 3, 1),
        ]
        let opponents = PlayerRecords(history: history).opponents(of: "alex")
        #expect(opponents.map(\.name) == ["Lucio", "Mia", "Sam"])
        let lucio = opponents[0]
        #expect((lucio.wins, lucio.losses, lucio.draws, lucio.matchesPlayed) == (1, 1, 1, 3))
        #expect(abs(lucio.winRate - 1.0 / 3) < 1e-9)
        #expect((opponents[1].wins, opponents[1].losses) == (1, 0))
        #expect((opponents[2].wins, opponents[2].losses) == (0, 1))
    }

    // MARK: - Head to head

    @Test func headToHeadCountsBothNameOrders() throws {
        let history = [
            Self.match("Alex", "Lucio", 3, 1, points: [(11, 5), (11, 9), (8, 11), (11, 2)], day: 1),
            Self.match("Mia", "Lucio", 3, 0, day: 2),
            Self.match("lucio", "alex", 3, 2, day: 3),
            Self.match("Lucio", "Alex", 2, 2, winner: MatchResult.noWinner, day: 4),
        ]
        let record = try #require(HeadToHead.between("Lucio", " ALEX", in: history))
        #expect(record.playerOneName == "Lucio")
        #expect(record.playerTwoName == "Alex")
        #expect((record.playerOneWins, record.playerTwoWins, record.draws, record.matchesPlayed) == (1, 1, 1, 3))
        #expect((record.playerOneGames, record.playerTwoGames) == (6, 7))
        #expect((record.playerOnePoints, record.playerTwoPoints) == (27, 41))
        #expect(record.meetings.map(\.historyIndex) == [3, 2, 0])
        #expect(record.meetings.map(\.winner) == [MatchResult.noWinner, 1, 2])
        #expect(record.meetings.map { [$0.playerOneGames, $0.playerTwoGames] } == [[2, 2], [3, 2], [1, 3]])
        // The same pair from the other side mirrors it
        let mirrored = try #require(PlayerRecords(history: history).headToHead("alex", "lucio"))
        #expect((mirrored.playerOneWins, mirrored.playerTwoWins, mirrored.draws) == (1, 1, 1))
        #expect((mirrored.playerOnePoints, mirrored.playerTwoPoints) == (41, 27))
    }

    @Test func winnerFilterKeepsTheMatchesOnePlayerWon() throws {
        let history = [
            Self.match("Alex", "Lucio", 3, 1, day: 1),
            Self.match("Alex", "Lucio", 0, 3, day: 2),
            Self.match("Lucio", "Alex", 3, 2, day: 3),
            Self.match("Lucio", "Alex", 1, 1, day: 4),
        ]
        let record = try #require(HeadToHead.between("Alex", "Lucio", in: history))
        #expect(record.meetings(.all).map(\.historyIndex) == [3, 2, 1, 0])
        #expect(record.meetings(.playerOneWon).map(\.historyIndex) == [0])
        #expect(record.meetings(.playerTwoWon).map(\.historyIndex) == [2, 1])
    }

    @Test(
        "No head to head for a blank or identical pair",
        arguments: [("Alex", "alex "), ("", "Lucio"), ("Alex", "  ")])
    func noHeadToHeadForBlankOrIdenticalPair(playerOne: String, playerTwo: String) {
        #expect(HeadToHead.between(playerOne, playerTwo, in: [Self.match("Alex", "Lucio", 3, 0)]) == nil)
    }

    @Test func playersWhoNeverMetHaveAnEmptyRecord() throws {
        let history = [Self.match("Alex", "Lucio", 3, 0), Self.match("Mia", "Sam", 3, 0)]
        let record = try #require(PlayerRecords(history: history).headToHead("alex", "sam"))
        #expect(record.matchesPlayed == 0)
        #expect(record.meetings.isEmpty)
        #expect((record.playerOneName, record.playerTwoName) == ("Alex", "Sam"))
    }

    @Test func homeRecordMatchesBetweenForTheLatestPair() throws {
        let history = [
            Self.match("Alex", "Lucio", 3, 1), Self.match("Mia", "Alex", 3, 0), Self.match("Lucio", "Alex", 3, 2),
        ]
        let home = try #require(HeadToHead.from(history: history))
        #expect(home == HeadToHead.between("Lucio", "Alex", in: history))
        #expect((home.playerOneWins, home.playerTwoWins, home.matchesPlayed) == (1, 1, 2))
    }
}
