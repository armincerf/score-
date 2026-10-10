//
//  MatchSummaryView.swift
//  score
//
//  SwiftUI view for displaying AI-generated match summaries
//

import FoundationModels
import SwiftData
import SwiftUI
import os

// MARK: - Match Summary Card View

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

/// Shows the summary for one match: the saved (or just generated) summary first, whatever the
/// model's current availability; otherwise progress, the unavailable card, an error or the button.
/// Generation and persistence go through `MatchSummaryService`, which shares one in-flight
/// generation per match with the background auto-summary.
struct MatchSummaryContainer: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var cachedSummary: MatchAnalysis?

    let matchResult: MatchResult
    let allMatches: [MatchResult]
    private let summaryService: MatchSummaryService

    init(matchResult: MatchResult, allMatches: [MatchResult], summaryService: MatchSummaryService = .shared) {
        self.matchResult = matchResult
        self.allMatches = allMatches
        self.summaryService = summaryService
    }

    private var matchId: UUID { matchResult.id }

    private var isGenerating: Bool {
        summaryService.isGenerating(matchId: matchId)
    }

    var body: some View {
        content
            .animation(.easeInOut, value: isGenerating)
            .task(id: matchId) {
                summaryService.refreshAvailability()
                loadCachedSummary()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    summaryService.refreshAvailability()
                }
            }
            .onChange(of: isGenerating) { _, generating in
                // A generation for this match (ours or the background one) finished and saved.
                if !generating {
                    loadCachedSummary()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let analysis = summaryService.latestSummary(for: matchId) ?? cachedSummary {
            let names = MatchPlayers.names(of: matchResult)
            MatchSummaryCardView(
                analysis: analysis,
                playerOneName: names?.playerOne ?? "Player 1",
                playerTwoName: names?.playerTwo ?? "Player 2"
            )
        } else if isGenerating {
            MatchSummaryLoadingView()
        } else if !summaryService.isAvailable {
            MatchSummaryUnavailableView(reason: summaryService.availabilityDescription)
        } else if let error = summaryService.error(for: matchId) {
            MatchSummaryErrorView(error: error.localizedDescription, onRetry: generate)
        } else {
            Button(action: generate) {
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

    private func generate() {
        let store = EventStore(modelContext: modelContext)
        Task {
            await summaryService.generateAndStoreSummary(for: matchResult, history: allMatches, store: store)
            loadCachedSummary()
        }
    }

    /// Re-reads StoredMatch.aiSummaryData for this match (by id).
    private func loadCachedSummary() {
        cachedSummary = MatchSummaryService.cachedSummary(for: matchId, in: EventStore(modelContext: modelContext))
        if cachedSummary != nil {
            Log.ai.debug("Loaded the cached summary for match \(self.matchId)")
        }
    }
}
