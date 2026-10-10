//
//  ServingLogicTests.swift
//  scoreTests
//
//  Table-tennis serving rules: serve alternates every 2 points, every point from 10-10.
//

import Testing

@testable import score

@Suite("ServingLogic")
struct ServingLogicTests {
    @Test(
        "Serve changes every two points before deuce",
        arguments: [
            (0, 0, 1), (1, 0, 1), (2, 0, 2), (1, 2, 2), (2, 2, 1), (4, 1, 1), (3, 3, 2), (9, 0, 1), (10, 9, 2),
            (9, 10, 2),
        ])
    func serverBeforeDeuce(p1: Int, p2: Int, expected: Int) {
        #expect(ServingLogic.calculateCurrentServer(firstServer: 1, playerOneScore: p1, playerTwoScore: p2) == expected)
    }

    @Test(
        "Serve changes every point from 10-10",
        arguments: [
            (10, 10, 1), (11, 10, 2), (11, 11, 1), (12, 11, 2), (12, 12, 1), (10, 12, 1),
        ])
    func serverInDeuce(p1: Int, p2: Int, expected: Int) {
        #expect(ServingLogic.calculateCurrentServer(firstServer: 1, playerOneScore: p1, playerTwoScore: p2) == expected)
    }

    @Test("First server is mirrored when player 2 starts")
    func mirroredFirstServer() {
        #expect(ServingLogic.calculateCurrentServer(firstServer: 2, playerOneScore: 0, playerTwoScore: 0) == 2)
        #expect(ServingLogic.calculateCurrentServer(firstServer: 2, playerOneScore: 2, playerTwoScore: 0) == 1)
        #expect(ServingLogic.calculateCurrentServer(firstServer: 2, playerOneScore: 10, playerTwoScore: 11) == 1)
    }

    @Test("Loser of the previous match serves first")
    func initialServerFromHistory() {
        let p1Won = MatchResult(playerOneGames: 3, playerTwoGames: 1, winner: 1, games: [])
        let p2Won = MatchResult(playerOneGames: 0, playerTwoGames: 3, winner: 2, games: [])
        #expect(ServingLogic.determineInitialServer(matchHistory: [p1Won]) == 2)
        #expect(ServingLogic.determineInitialServer(matchHistory: [p2Won]) == 1)
        #expect([1, 2].contains(ServingLogic.determineInitialServer(matchHistory: [])))
    }

    @Test("Game first server alternates between games")
    func gameFirstServerAlternates() {
        let game = GameResult(playerOneScore: 11, playerTwoScore: 5, winner: 1, firstServer: 1)
        #expect(
            ServingLogic.determineGameFirstServer(currentGameNumber: 0, previousGames: [], matchFirstServer: 2) == 2)
        #expect(
            ServingLogic.determineGameFirstServer(currentGameNumber: 1, previousGames: [game], matchFirstServer: 1) == 2
        )
    }

    @Test("Point on serve detection")
    func pointOnServe() {
        #expect(ServingLogic.wasPointScoredOnServe(scoringPlayer: 1, servingPlayer: 1))
        #expect(!ServingLogic.wasPointScoredOnServe(scoringPlayer: 2, servingPlayer: 1))
    }

    @Test("Total serves across a game sum to the total points")
    func totalServesSum() {
        for (p1, p2) in [(11, 0), (11, 9), (12, 10), (7, 11), (15, 13)] {
            let s1 = ServingLogic.calculateTotalServes(forPlayer: 1, firstServer: 1, finalP1Score: p1, finalP2Score: p2)
            let s2 = ServingLogic.calculateTotalServes(forPlayer: 2, firstServer: 1, finalP1Score: p1, finalP2Score: p2)
            #expect(s1 + s2 == p1 + p2, "serves for \(p1)-\(p2)")
        }
    }
}
