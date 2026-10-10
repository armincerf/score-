//
//  ServingLogic.swift
//  score
//
//  Pure functions for table tennis serving rules
//  Add to BOTH iOS and watchOS targets in Xcode
//

import Foundation

nonisolated enum ServingLogic {
    // MARK: - Initial Server Determination

    /// Determines who serves first in a new match based on match history
    /// - Parameter matchHistory: Previous matches
    /// - Returns: Player number (1 or 2) who should serve first
    static func determineInitialServer(matchHistory: [MatchResult]) -> Int {
        guard let lastMatch = matchHistory.last, lastMatch.hasWinner else {
            // No history (or last match had no winner) - random selection
            return Bool.random() ? 1 : 2
        }

        // Loser of previous match serves first
        return lastMatch.winner == 1 ? 2 : 1
    }

    // MARK: - Game First Server

    /// Determines who serves first in a specific game
    /// - Parameters:
    ///   - currentGameNumber: The game number (0-based)
    ///   - previousGames: Games completed in this match
    ///   - matchFirstServer: Who served first in the entire match
    /// - Returns: Player number (1 or 2) who should serve first in this game
    static func determineGameFirstServer(
        currentGameNumber: Int,
        previousGames: [GameResult],
        matchFirstServer: Int
    ) -> Int {
        if currentGameNumber == 0 {
            // First game - use match's first server
            return matchFirstServer
        }

        // Get who served first in previous game
        guard let previousGame = previousGames.last else {
            return matchFirstServer
        }

        // Alternate from previous game
        return previousGame.firstServer == 1 ? 2 : 1
    }

    // MARK: - Current Server Calculation

    /// Calculates who is currently serving based on the score
    /// Table tennis rules:
    /// - Before 10-10: Serve changes every 2 points
    /// - At 10-10 or higher (deuce): Serve changes every point
    /// - Parameters:
    ///   - firstServer: Who served first in this game (1 or 2)
    ///   - playerOneScore: Current score for player 1
    ///   - playerTwoScore: Current score for player 2
    /// - Returns: Player number (1 or 2) who is currently serving
    static func calculateCurrentServer(
        firstServer: Int,
        playerOneScore: Int,
        playerTwoScore: Int
    ) -> Int {
        let totalPoints = playerOneScore + playerTwoScore

        // Check if we're in deuce (both players at 10 or above)
        if playerOneScore >= 10 && playerTwoScore >= 10 {
            // Service changes every point
            // If total points is even, first server serves; if odd, other player serves
            return totalPoints.isMultiple(of: 2) ? firstServer : (firstServer == 1 ? 2 : 1)
        }

        // Normal game (before 10-10): service changes every 2 points
        // Calculate how many "service turns" have passed (each turn is 2 points)
        let serviceTurns = totalPoints / 2

        // If service turns is even, first server serves; if odd, other player serves
        return serviceTurns.isMultiple(of: 2) ? firstServer : (firstServer == 1 ? 2 : 1)
    }

    // MARK: - Point Analysis

    /// Checks if a point was won while serving
    /// - Parameters:
    ///   - scoringPlayer: Who scored the point (1 or 2)
    ///   - servingPlayer: Who was serving when the point was scored (1 or 2)
    /// - Returns: True if the scoring player was serving
    static func wasPointScoredOnServe(scoringPlayer: Int, servingPlayer: Int) -> Bool {
        return scoringPlayer == servingPlayer
    }

    // MARK: - Statistics Calculation

    /// Who serves the point at 0-based `index` of a game in which `firstServer` served first.
    /// Service changes every two points until 10-10 (20 points played), then every point.
    static func serverForPoint(index: Int, firstServer: Int) -> Int {
        let other = firstServer == 1 ? 2 : 1
        let turn = index < 20 ? index / 2 : index - 10
        return turn.isMultiple(of: 2) ? firstServer : other
    }

    /// Calculates the total number of serves a player had in a game from its final score.
    /// Serve order depends only on how many points have been played, not on who scored them.
    static func calculateTotalServes(
        forPlayer player: Int,
        firstServer: Int,
        finalP1Score: Int,
        finalP2Score: Int
    ) -> Int {
        (0..<(finalP1Score + finalP2Score)).filter { serverForPoint(index: $0, firstServer: firstServer) == player }
            .count
    }
}
