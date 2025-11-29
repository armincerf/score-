//
//  MatchSummaryView.swift
//  score
//
//  SwiftUI view for displaying AI-generated match summaries
//

import SwiftUI
import FoundationModels
import SwiftData

// MARK: - Match Summary Card View

@available(iOS 26.0, *)
struct MatchSummaryCardView: View {
    let analysis: MatchAnalysis
    let playerOneName: String
    let playerTwoName: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("AI Match Summary")
                    .font(.headline)
                Spacer()
            }
            
            Text(analysis.matchSummary.headline)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text(analysis.matchSummary.narrative)
                .font(.body)
                .foregroundStyle(.secondary)
            
            Divider()
            
            SummarySection(title: "Winner Insights", content: analysis.matchSummary.winnerInsights, icon: "trophy.fill")
            
            SummarySection(title: "Key Moments", content: analysis.matchSummary.keyMoments, icon: "star.fill")
            
            SummarySection(title: "Fun Fact", content: analysis.matchSummary.funFact, icon: "lightbulb.fill")
            
            if let rivalry = analysis.rivalryAnalysis {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.orange)
                        Text("Head-to-Head")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    
                    Text(rivalry.rivalryOverview)
                        .font(.callout)
                    
                    if !rivalry.recentTrend.isEmpty {
                        Text(rivalry.recentTrend)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !rivalry.lookAhead.isEmpty {
                        Text(rivalry.lookAhead)
                            .font(.callout)
                            .italic()
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Summary Section

private struct SummarySection: View {
    let title: String
    let content: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            Text(content)
                .font(.callout)
        }
    }
}

// MARK: - Loading State View

struct MatchSummaryLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("AI Match Summary")
                    .font(.headline)
                Spacer()
            }
            
            HStack(spacing: 8) {
                ProgressView()
                Text("Generating summary...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Error State View

struct MatchSummaryErrorView: View {
    let error: String
    let onRetry: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("AI Match Summary")
                    .font(.headline)
                Spacer()
            }
            
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Unavailable State View

struct MatchSummaryUnavailableView: View {
    let reason: String
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.gray)
                Text("AI Match Summary")
                    .font(.headline)
                Spacer()
            }
            
            VStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                
                Text("AI features require Apple Intelligence")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Container View with State Management

@available(iOS 26.0, *)
struct MatchSummaryContainer: View {
    @StateObject private var summaryService = MatchSummaryService()
    @Environment(\.modelContext) private var modelContext
    @State private var cachedSummary: MatchAnalysis?

    let matchResult: MatchResult
    let allMatches: [MatchResult]

    var body: some View {
        Group {
            if !summaryService.isAvailable {
                MatchSummaryUnavailableView(reason: summaryService.availabilityDescription)
            } else if summaryService.isGenerating {
                MatchSummaryLoadingView()
            } else if let error = summaryService.lastError {
                MatchSummaryErrorView(error: error.localizedDescription) {
                    Task {
                        await summaryService.generateSummary(for: matchResult, allMatches: allMatches)
                    }
                }
            } else if let analysis = summaryService.lastSummary ?? cachedSummary {
                MatchSummaryCardView(
                    analysis: analysis,
                    playerOneName: extractPlayerName(1),
                    playerTwoName: extractPlayerName(2)
                )
            } else {
                Button {
                    Task {
                        await summaryService.generateSummary(for: matchResult, allMatches: allMatches)
                    }
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Generate AI Summary")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut, value: summaryService.isGenerating)
        .task {
            // Load cached summary from database
            await loadCachedSummary()
        }
    }

    private func loadCachedSummary() async {
        guard let matchName = matchResult.name else { return }

        do {
            let descriptor = FetchDescriptor<StoredMatch>(
                predicate: #Predicate<StoredMatch> { $0.matchName == matchName }
            )

            let matches = try modelContext.fetch(descriptor)
            if let storedMatch = matches.first,
               let summaryData = storedMatch.aiSummaryData {
                let codableSummary = try JSONDecoder().decode(MatchAnalysisCodable.self, from: summaryData)
                cachedSummary = codableSummary.toMatchAnalysis()
                print("[MatchSummary] 📖 Loaded cached AI summary from database")
            }
        } catch {
            print("[MatchSummary] ⚠️ Failed to load cached summary: \(error.localizedDescription)")
        }
    }

    private func extractPlayerName(_ player: Int) -> String {
        guard let name = matchResult.name else { return "Player \(player)" }
        let components = name.components(separatedBy: " vs ")
        guard components.count == 2 else { return "Player \(player)" }
        return player == 1 ? components[0].trimmingCharacters(in: .whitespaces)
                           : components[1].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Fallback Container for older iOS

struct MatchSummaryFallbackContainer: View {
    let matchResult: MatchResult
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text("Match Summary")
                    .font(.headline)
                Spacer()
            }
            
            Text(generateBasicSummary())
                .font(.body)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func generateBasicSummary() -> String {
        guard let name = matchResult.name else {
            return "Match completed \(matchResult.playerOneGames)-\(matchResult.playerTwoGames)"
        }
        
        let components = name.components(separatedBy: " vs ")
        guard components.count == 2 else {
            return "Match completed \(matchResult.playerOneGames)-\(matchResult.playerTwoGames)"
        }
        
        let p1 = components[0].trimmingCharacters(in: .whitespaces)
        let p2 = components[1].trimmingCharacters(in: .whitespaces)
        
        return MatchSummaryFallback.generateBasicSummary(
            playerOneName: p1,
            playerTwoName: p2,
            winner: matchResult.winner,
            playerOneGames: matchResult.playerOneGames,
            playerTwoGames: matchResult.playerTwoGames
        )
    }
}
