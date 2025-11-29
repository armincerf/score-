//
//  MatchSummaryService.swift
//  score
//
//  Service for generating AI-powered match summaries using Apple's Foundation Models framework
//

import Foundation
import FoundationModels
import SwiftData
import Combine

// MARK: - Match Summary Service

@available(iOS 26.0, *)
@MainActor
final class MatchSummaryService: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: AIError?
    @Published private(set) var lastSummary: MatchAnalysis?
    
    // MARK: - Private Properties
    
    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    
    // MARK: - Error Types
    
    enum AIError: LocalizedError {
        case modelUnavailable(String)
        case generationFailed(Error)
        case noMatchData
        
        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason):
                return "AI model unavailable: \(reason)"
            case .generationFailed(let error):
                return "Failed to generate summary: \(error.localizedDescription)"
            case .noMatchData:
                return "No match data available"
            }
        }
    }
    
    // MARK: - Public API
    
    var isAvailable: Bool {
        model.availability == .available
    }
    
    var availabilityDescription: String {
        switch model.availability {
        case .available:
            return "AI summaries available"
        case .unavailable(let reason):
            return "AI unavailable: \(reason)"
        }
    }
    
    func generateSummary(for match: MatchResult, allMatches: [MatchResult]) async -> MatchAnalysis? {
        guard isAvailable else {
            if case .unavailable(let reason) = model.availability {
                lastError = .modelUnavailable(String(describing: reason))
            }
            return nil
        }
        
        guard let playerOneName = extractPlayerName(from: match, player: 1),
              let playerTwoName = extractPlayerName(from: match, player: 2) else {
            lastError = .noMatchData
            return nil
        }
        
        let previousMatches = findPreviousMatches(
            playerOne: playerOneName,
            playerTwo: playerTwoName,
            in: allMatches,
            excluding: match
        )
        
        let context = MatchContext(
            playerOneName: playerOneName,
            playerTwoName: playerTwoName,
            winner: match.winner,
            playerOneGames: match.playerOneGames,
            playerTwoGames: match.playerTwoGames,
            games: match.games,
            duration: match.duration,
            previousMatches: previousMatches
        )
        
        return await generateSummary(from: context)
    }
    
    func generateSummary(
        playerOneName: String,
        playerTwoName: String,
        winner: Int,
        playerOneGames: Int,
        playerTwoGames: Int,
        games: [GameResult],
        duration: TimeInterval?,
        allMatches: [MatchResult]
    ) async -> MatchAnalysis? {
        let previousMatches = findPreviousMatches(
            playerOne: playerOneName,
            playerTwo: playerTwoName,
            in: allMatches,
            excluding: nil
        )
        
        let context = MatchContext(
            playerOneName: playerOneName,
            playerTwoName: playerTwoName,
            winner: winner,
            playerOneGames: playerOneGames,
            playerTwoGames: playerTwoGames,
            games: games,
            duration: duration,
            previousMatches: previousMatches
        )
        
        return await generateSummary(from: context)
    }
    
    // MARK: - Private Methods
    
    private func generateSummary(from context: MatchContext) async -> MatchAnalysis? {
        guard isAvailable else { return nil }
        
        isGenerating = true
        lastError = nil
        
        defer { isGenerating = false }
        
        do {
            let instructions = Instructions("""
            You are a sports commentator specializing in table tennis. Generate engaging, 
            concise match summaries that capture the excitement of the game. Use player names 
            naturally, highlight close games and comebacks, and be enthusiastic but professional.
            Keep responses brief and punchy - this is for a mobile app display.
            """)
            
            let session = LanguageModelSession(instructions: instructions)
            self.session = session
            
            let prompt = context.buildPrompt()
            
            let response = try await session.respond(
                to: prompt,
                generating: MatchAnalysis.self
            )
            
            let analysis = response.content
            lastSummary = analysis
            return analysis
            
        } catch {
            lastError = .generationFailed(error)
            return nil
        }
    }
    
    private func extractPlayerName(from match: MatchResult, player: Int) -> String? {
        guard let matchName = match.name else { return nil }
        
        let components = matchName.components(separatedBy: " vs ")
        guard components.count == 2 else { return nil }
        
        return player == 1 ? components[0].trimmingCharacters(in: .whitespaces)
                           : components[1].trimmingCharacters(in: .whitespaces)
    }
    
    private func findPreviousMatches(
        playerOne: String,
        playerTwo: String,
        in allMatches: [MatchResult],
        excluding currentMatch: MatchResult?
    ) -> [MatchResult] {
        let p1Lower = playerOne.lowercased()
        let p2Lower = playerTwo.lowercased()
        
        return allMatches.filter { match in
            guard match.timestamp != currentMatch?.timestamp else { return false }
            guard let name = match.name?.lowercased() else { return false }
            
            let containsP1 = name.contains(p1Lower)
            let containsP2 = name.contains(p2Lower)
            
            return containsP1 && containsP2
        }
        .sorted { $0.timestamp > $1.timestamp }
    }
}

// MARK: - Convenience Extensions

@available(iOS 26.0, *)
extension MatchSummaryService {
    
    func generateSummary(for storedMatch: StoredMatch, allMatches: [StoredMatch]) async -> MatchAnalysis? {
        let matchResults = allMatches.compactMap { stored -> MatchResult? in
            let events = stored.events
            
            let games = reconstructGames(from: events)
            
            return MatchResult(
                name: stored.matchName,
                playerOneGames: stored.playerOneGames,
                playerTwoGames: stored.playerTwoGames,
                winner: stored.winner ?? (stored.playerOneGames > stored.playerTwoGames ? 1 : 2),
                games: games,
                timestamp: stored.startTimestamp,
                fullVideoURL: stored.fullVideoURL,
                highlightVideoURL: stored.highlightVideoURL,
                duration: stored.totalDuration
            )
        }
        
        let currentMatchResult = MatchResult(
            name: storedMatch.matchName,
            playerOneGames: storedMatch.playerOneGames,
            playerTwoGames: storedMatch.playerTwoGames,
            winner: storedMatch.winner ?? (storedMatch.playerOneGames > storedMatch.playerTwoGames ? 1 : 2),
            games: reconstructGames(from: storedMatch.events),
            timestamp: storedMatch.startTimestamp,
            fullVideoURL: storedMatch.fullVideoURL,
            highlightVideoURL: storedMatch.highlightVideoURL,
            duration: storedMatch.totalDuration
        )
        
        return await generateSummary(for: currentMatchResult, allMatches: matchResults)
    }
    
    private func reconstructGames(from events: [StoredMatchEvent]) -> [GameResult] {
        return []
    }
}

// MARK: - Preview/Fallback for older iOS

struct MatchSummaryFallback {
    static func generateBasicSummary(
        playerOneName: String,
        playerTwoName: String,
        winner: Int,
        playerOneGames: Int,
        playerTwoGames: Int
    ) -> String {
        let winnerName = winner == 1 ? playerOneName : playerTwoName
        let score = "\(playerOneGames)-\(playerTwoGames)"
        return "\(winnerName) wins \(score) in a competitive match!"
    }
}
