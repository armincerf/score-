//
//  HeadToHeadTests.swift
//  scoreTests
//
//  HeadToHead.from(history:): the record of the most recent match's players across the whole history.
//

import Foundation
import Testing

@testable import score

@Suite("HeadToHead")
struct HeadToHeadTests {
    /// A finished match; `winner` defaults to whoever won more games (or no winner on a tie).
    private static func match(
        _ playerOne: String?, _ playerTwo: String?, _ gamesOne: Int, _ gamesTwo: Int, winner: Int? = nil,
        name: String? = nil
    ) -> MatchResult {
        let decided = gamesOne == gamesTwo ? MatchResult.noWinner : (gamesOne > gamesTwo ? 1 : 2)
        return MatchResult(
            name: name, playerOneName: playerOne, playerTwoName: playerTwo, playerOneGames: gamesOne,
            playerTwoGames: gamesTwo, winner: winner ?? decided, games: [])
    }

    @Test func emptyHistoryHasNoRecord() {
        #expect(HeadToHead.from(history: []) == nil)
    }

    @Test func countsWinsAndDraws() throws {
        let history = [
            Self.match("Alex", "Lucio", 3, 1),
            Self.match("Alex", "Lucio", 1, 3),
            Self.match("Alex", "Lucio", 1, 1),
            Self.match("Alex", "Lucio", 3, 2),
        ]
        let record = try #require(HeadToHead.from(history: history))
        #expect(record.playerOneName == "Alex")
        #expect(record.playerTwoName == "Lucio")
        #expect(record.playerOneWins == 2)
        #expect(record.playerTwoWins == 1)
        #expect(record.draws == 1)
        #expect(record.matchesPlayed == 4)
    }

    @Test func playerOrderDoesNotMatter() throws {
        // The latest match has Lucio as player one: earlier wins by Alex as player one count for Alex.
        let history = [
            Self.match("Alex", "Lucio", 3, 0),
            Self.match("alex ", " LUCIO", 3, 2),
            Self.match("Lucio", "Alex", 3, 1),
        ]
        let record = try #require(HeadToHead.from(history: history))
        #expect(record.playerOneName == "Lucio")
        #expect(record.playerTwoName == "Alex")
        #expect(record.playerOneWins == 1)
        #expect(record.playerTwoWins == 2)
        #expect(record.draws == 0)
        #expect(record.matchesPlayed == 3)
    }

    @Test func excludesMatchesAgainstOtherOpponents() throws {
        let history = [
            Self.match("Alex", "Sam", 3, 0),
            Self.match("Sam", "Lucio", 0, 3),
            Self.match("Alex", "Lucio", 2, 3),
            Self.match("Lucio", "Sam", 1, 1),
            Self.match("Alex", "Lucio", 3, 1),
        ]
        let record = try #require(HeadToHead.from(history: history))
        #expect(record.playerOneWins == 1)
        #expect(record.playerTwoWins == 1)
        #expect(record.draws == 0)
        #expect(record.matchesPlayed == 2)
    }

    @Test(
        "A latest match without usable names has no record",
        arguments: [
            (nil, nil), ("  ", "Lucio"), ("Alex", nil),
        ] as [(String?, String?)])
    func latestMatchWithoutNames(playerOne: String?, playerTwo: String?) {
        let history = [Self.match("Alex", "Lucio", 3, 0), Self.match(playerOne, playerTwo, 3, 1)]
        #expect(HeadToHead.from(history: history) == nil)
    }

    @Test func earlierMatchesWithoutNamesAreSkipped() throws {
        let history = [
            Self.match(nil, nil, 3, 0),
            Self.match(" ", "Lucio", 3, 0),
            Self.match("Alex", nil, 0, 3, name: "Solo practice"),
            Self.match("Alex", "Lucio", 1, 3),
        ]
        let record = try #require(HeadToHead.from(history: history))
        #expect(record.playerOneWins == 0)
        #expect(record.playerTwoWins == 1)
        #expect(record.matchesPlayed == 1)
    }

    @Test func legacyMatchNamesAreParsedAndTrimmed() throws {
        // Matches stored before player names existed carry them only in "A vs B - <date>".
        let history = [
            Self.match(nil, nil, 3, 0, name: "Lucio vs Alex - 1 Oct 2026 at 10:00"),  // Lucio won
            Self.match(nil, nil, 3, 1, name: " Alex  vs Lucio - 2 Oct 2026 at 10:00"),  // Alex won
        ]
        let record = try #require(HeadToHead.from(history: history))
        #expect(record.playerOneName == "Alex")
        #expect(record.playerTwoName == "Lucio")
        #expect(record.playerOneWins == 1)
        #expect(record.playerTwoWins == 1)
        #expect(record.matchesPlayed == 2)
    }

    @Test func noWinnerIsADrawEvenWithUnevenGames() throws {
        // An abandoned match can record games but no winner.
        let history = [Self.match("Alex", "Lucio", 2, 1, winner: MatchResult.noWinner)]
        let record = try #require(HeadToHead.from(history: history))
        #expect(record.playerOneWins == 0)
        #expect(record.playerTwoWins == 0)
        #expect(record.draws == 1)
        #expect(record.matchesPlayed == 1)
    }
}
