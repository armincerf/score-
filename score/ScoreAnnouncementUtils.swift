//
//  ScoreAnnouncementUtils.swift
//  score
//
//  Utility functions for generating table tennis score announcements.
//  Follows official table tennis rules: first to 11, must win by 2.
//

import Foundation

enum ScoreAnnouncementUtils {
    
    struct ScoreAnnouncement {
        let text: String
        let isGamePoint: Bool
        let isMatchPoint: Bool
    }
    
    static func generateAnnouncement(
        playerOneScore: Int,
        playerTwoScore: Int,
        playerOneName: String?,
        playerTwoName: String?,
        playerOneGames: Int = 0,
        playerTwoGames: Int = 0,
        bestOf: Int = 5
    ) -> ScoreAnnouncement {
        let p1Name = playerOneName ?? "Player 1"
        let p2Name = playerTwoName ?? "Player 2"
        
        let text = generateScoreText(
            playerOneScore: playerOneScore,
            playerTwoScore: playerTwoScore,
            playerOneName: p1Name,
            playerTwoName: p2Name
        )
        
        let isGamePoint = checkIsGamePoint(p1Score: playerOneScore, p2Score: playerTwoScore)
        let isMatchPoint = checkIsMatchPoint(
            p1Score: playerOneScore,
            p2Score: playerTwoScore,
            p1Games: playerOneGames,
            p2Games: playerTwoGames,
            bestOf: bestOf
        )
        
        return ScoreAnnouncement(text: text, isGamePoint: isGamePoint, isMatchPoint: isMatchPoint)
    }
    
    private static func generateScoreText(
        playerOneScore: Int,
        playerTwoScore: Int,
        playerOneName: String,
        playerTwoName: String
    ) -> String {
        
        // Check for deuce (10-10 or any tied score at 10+)
        if playerOneScore == playerTwoScore && playerOneScore >= 10 {
            return "Deuce"
        }
        
        // Check for tied scores below 10 -> "X all"
        if playerOneScore == playerTwoScore {
            return "\(playerOneScore) all"
        }
        
        // Check for advantage situations (both at 10+, one ahead by 1)
        if playerOneScore >= 10 && playerTwoScore >= 10 {
            let diff = playerOneScore - playerTwoScore
            if diff == 1 {
                return "Advantage \(playerOneName)"
            } else if diff == -1 {
                return "Advantage \(playerTwoName)"
            }
        }
        
        // Standard score announcement: leading score first, then trailing, then leader's name
        if playerOneScore > playerTwoScore {
            return "\(playerOneScore) \(playerTwoScore) to \(playerOneName)"
        } else {
            return "\(playerTwoScore) \(playerOneScore) to \(playerTwoName)"
        }
    }
    
    private static func checkIsGamePoint(p1Score: Int, p2Score: Int) -> Bool {
        // Game point if either player is at 10+ and ahead by at least 1
        let maxScore = max(p1Score, p2Score)
        let minScore = min(p1Score, p2Score)
        
        if maxScore >= 10 && maxScore > minScore {
            return true
        }
        return false
    }
    
    private static func checkIsMatchPoint(
        p1Score: Int,
        p2Score: Int,
        p1Games: Int,
        p2Games: Int,
        bestOf: Int
    ) -> Bool {
        let gamesToWin = (bestOf / 2) + 1
        
        // Check if P1 is one game away from winning and has game point
        if p1Games == gamesToWin - 1 && p1Score >= 10 && p1Score > p2Score {
            return true
        }
        
        // Check if P2 is one game away from winning and has game point
        if p2Games == gamesToWin - 1 && p2Score >= 10 && p2Score > p1Score {
            return true
        }
        
        return false
    }
    
    static func checkGameWon(playerOneScore: Int, playerTwoScore: Int) -> Int? {
        let maxScore = max(playerOneScore, playerTwoScore)
        let minScore = min(playerOneScore, playerTwoScore)
        
        // Must reach 11 (or more in deuce) and win by 2
        if maxScore >= 11 && maxScore - minScore >= 2 {
            return playerOneScore > playerTwoScore ? 1 : 2
        }
        return nil
    }
    
    static func checkMatchWon(
        playerOneGames: Int,
        playerTwoGames: Int,
        bestOf: Int = 5
    ) -> Int? {
        let gamesToWin = (bestOf / 2) + 1
        
        if playerOneGames >= gamesToWin {
            return 1
        }
        if playerTwoGames >= gamesToWin {
            return 2
        }
        return nil
    }
}
