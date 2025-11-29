//
//  MatchSummaryModels.swift
//  score
//
//  Generable types for AI-powered match summaries using Foundation Models framework
//

import Foundation
import FoundationModels

// MARK: - Match Summary Output

@available(iOS 26.0, *)
@Generable(description: "A summary of a table tennis match between two players")
struct MatchSummary {
    @Guide(description: "A catchy headline for the match result in 5-10 words")
    var headline: String
    
    @Guide(description: "A 2-3 sentence narrative summary of how the match unfolded")
    var narrative: String
    
    @Guide(description: "Key performance insights about the winner")
    var winnerInsights: String
    
    @Guide(description: "Notable moments or turning points in the match")
    var keyMoments: String
    
    @Guide(description: "Fun or interesting observation about the match")
    var funFact: String
}

// MARK: - Head-to-Head Analysis

@available(iOS 26.0, *)
@Generable(description: "Analysis of the rivalry between two players based on their match history")
struct RivalryAnalysis {
    @Guide(description: "Description of the overall rivalry and who dominates")
    var rivalryOverview: String
    
    @Guide(description: "Trend observation about recent matches")
    var recentTrend: String
    
    @Guide(description: "Prediction or commentary for future matches")
    var lookAhead: String
}

// MARK: - Complete AI Summary

@available(iOS 26.0, *)
@Generable(description: "Complete AI-generated analysis of a match including rivalry context")
struct MatchAnalysis {
    @Guide(description: "Summary of the current match")
    var matchSummary: MatchSummary

    @Guide(description: "Analysis of the head-to-head rivalry if players have history")
    var rivalryAnalysis: RivalryAnalysis?
}

// MARK: - Codable Wrappers for Persistence

// Codable version for database storage (works on all iOS versions)
struct MatchAnalysisCodable: Codable {
    let headline: String
    let narrative: String
    let winnerInsights: String
    let keyMoments: String
    let funFact: String
    let rivalryOverview: String?
    let recentTrend: String?
    let lookAhead: String?

    @available(iOS 26.0, *)
    init(from analysis: MatchAnalysis) {
        self.headline = analysis.matchSummary.headline
        self.narrative = analysis.matchSummary.narrative
        self.winnerInsights = analysis.matchSummary.winnerInsights
        self.keyMoments = analysis.matchSummary.keyMoments
        self.funFact = analysis.matchSummary.funFact
        self.rivalryOverview = analysis.rivalryAnalysis?.rivalryOverview
        self.recentTrend = analysis.rivalryAnalysis?.recentTrend
        self.lookAhead = analysis.rivalryAnalysis?.lookAhead
    }

    @available(iOS 26.0, *)
    func toMatchAnalysis() -> MatchAnalysis {
        let rivalry = rivalryOverview.map { overview in
            RivalryAnalysis(
                rivalryOverview: overview,
                recentTrend: recentTrend ?? "",
                lookAhead: lookAhead ?? ""
            )
        }

        return MatchAnalysis(
            matchSummary: MatchSummary(
                headline: headline,
                narrative: narrative,
                winnerInsights: winnerInsights,
                keyMoments: keyMoments,
                funFact: funFact
            ),
            rivalryAnalysis: rivalry
        )
    }
}

// MARK: - Match Context for Prompting

struct MatchContext {
    let playerOneName: String
    let playerTwoName: String
    let winner: Int
    let playerOneGames: Int
    let playerTwoGames: Int
    let games: [GameResult]
    let duration: TimeInterval?
    let previousMatches: [MatchResult]
    
    var winnerName: String {
        winner == 1 ? playerOneName : playerTwoName
    }
    
    var loserName: String {
        winner == 1 ? playerTwoName : playerOneName
    }
    
    var winnerGames: Int {
        winner == 1 ? playerOneGames : playerTwoGames
    }
    
    var loserGames: Int {
        winner == 1 ? playerTwoGames : playerOneGames
    }
    
    func buildPrompt() -> String {
        var prompt = """
        Generate a match summary for this table tennis match:
        
        Players: \(playerOneName) vs \(playerTwoName)
        Final Score: \(playerOneName) \(playerOneGames) - \(playerTwoGames) \(playerTwoName)
        Winner: \(winnerName)
        
        Game-by-game breakdown:
        """
        
        for (index, game) in games.enumerated() {
            let gameWinner = game.winner == 1 ? playerOneName : playerTwoName
            prompt += "\nGame \(index + 1): \(game.playerOneScore)-\(game.playerTwoScore) (\(gameWinner) wins)"
            if let gameDuration = game.duration {
                prompt += " - Duration: \(formatDuration(gameDuration))"
            }
        }
        
        if let matchDuration = duration {
            prompt += "\n\nTotal match duration: \(formatDuration(matchDuration))"
        }
        
        if !previousMatches.isEmpty {
            prompt += "\n\nPrevious matches between these players:"
            var p1Wins = 0
            var p2Wins = 0
            
            for match in previousMatches.suffix(5) {
                let prevWinner = match.winner == 1 ? playerOneName : playerTwoName
                prompt += "\n- \(playerOneName) \(match.playerOneGames)-\(match.playerTwoGames) \(playerTwoName) (Winner: \(prevWinner))"
                if match.winner == 1 { p1Wins += 1 } else { p2Wins += 1 }
            }
            
            prompt += "\n\nHead-to-head record: \(playerOneName) \(p1Wins) - \(p2Wins) \(playerTwoName)"
        } else {
            prompt += "\n\nThis is the first recorded match between these players."
        }
        
        return prompt
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
