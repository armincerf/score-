//
//  ServingLogic.swift
//  score
//
//  Pure functions for table tennis serving rules
//  Add to BOTH iOS and watchOS targets in Xcode
//

import Foundation

enum ServingLogic {

    // MARK: - Initial Server Determination

    /// Determines who serves first in a new match based on match history
    /// - Parameter matchHistory: Previous matches
    /// - Returns: Player number (1 or 2) who should serve first
    static func determineInitialServer(matchHistory: [MatchResult]) -> Int {
        guard let lastMatch = matchHistory.last else {
            // No history - random selection
            return Bool.random() ? 1 : 2
        }

        // Loser of previous match serves first
        let loser = lastMatch.winner == 1 ? 2 : 1
        return loser
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
            return totalPoints % 2 == 0 ? firstServer : (firstServer == 1 ? 2 : 1)
        }

        // Normal game (before 10-10): service changes every 2 points
        // Calculate how many "service turns" have passed (each turn is 2 points)
        let serviceTurns = totalPoints / 2

        // If service turns is even, first server serves; if odd, other player serves
        return serviceTurns % 2 == 0 ? firstServer : (firstServer == 1 ? 2 : 1)
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

    /// Calculates the total number of serves a player had in a game
    /// - Parameters:
    ///   - player: Player number (1 or 2)
    ///   - firstServer: Who served first in the game
    ///   - finalP1Score: Final score for player 1
    ///   - finalP2Score: Final score for player 2
    /// - Returns: Number of points where the player was serving
    static func calculateTotalServes(
        forPlayer player: Int,
        firstServer: Int,
        finalP1Score: Int,
        finalP2Score: Int
    ) -> Int {
        let totalPoints = finalP1Score + finalP2Score
        var serveCount = 0

        // Iterate through all points and check who was serving
        for pointIndex in 0..<totalPoints {
            let servingPlayer = calculateCurrentServer(
                firstServer: firstServer,
                playerOneScore: pointIndex >= finalP1Score ? finalP1Score : min(pointIndex, finalP1Score),
                playerTwoScore: pointIndex >= finalP2Score ? finalP2Score : pointIndex - min(pointIndex, finalP1Score)
            )

            if servingPlayer == player {
                serveCount += 1
            }
        }

        return serveCount
    }
}
