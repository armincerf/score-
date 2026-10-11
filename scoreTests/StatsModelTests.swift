//
//  StatsModelTests.swift
//  scoreTests
//
//  The Stats page's pair choice: the most recent match's players by default, choosing the other player swaps
//  them, and a reload keeps the choice while both players still have matches.
//

import Foundation
import Testing

@testable import score

@Suite("StatsModel")
struct StatsModelTests {
    private static func match(_ playerOne: String, _ playerTwo: String) -> MatchResult {
        MatchResult(
            playerOneName: playerOne, playerTwoName: playerTwo, playerOneGames: 3, playerTwoGames: 1, winner: 1,
            games: [])
    }

    @Test func choosingTheOtherPlayerSwapsThePair() {
        let pair = PlayerPair(playerOne: "alex", playerTwo: "lucio")
        #expect(pair.choosing(playerOne: "lucio") == PlayerPair(playerOne: "lucio", playerTwo: "alex"))
        #expect(pair.choosing(playerTwo: "alex") == PlayerPair(playerOne: "lucio", playerTwo: "alex"))
        #expect(pair.choosing(playerOne: "mia") == PlayerPair(playerOne: "mia", playerTwo: "lucio"))
        #expect(pair.choosing(playerTwo: "sam") == PlayerPair(playerOne: "alex", playerTwo: "sam"))
    }

    @Test func defaultsToTheLatestPairAndKeepsAChoiceAcrossReloads() {
        let model = StatsModel()
        #expect(model.pair == nil)
        model.load([Self.match("Mia", "Sam"), Self.match("Lucio", "Alex")])
        #expect(model.pair == PlayerPair(playerOne: "lucio", playerTwo: "alex"))
        model.playerTwo = "sam"
        #expect(model.pair == PlayerPair(playerOne: "lucio", playerTwo: "sam"))
        // A new match between others keeps the choice
        model.load([Self.match("Mia", "Sam"), Self.match("Lucio", "Alex"), Self.match("Alex", "Mia")])
        #expect(model.pair == PlayerPair(playerOne: "lucio", playerTwo: "sam"))
        // Sam's only match deleted: back to the latest pair
        model.load([Self.match("Lucio", "Alex"), Self.match("Alex", "Mia")])
        #expect(model.pair == PlayerPair(playerOne: "alex", playerTwo: "mia"))
        model.load([])
        #expect(model.pair == nil)
    }
}
