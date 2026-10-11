//
//  MatchHistoryView.swift
//  score
//
//  View all past matches
//

import SwiftData
import SwiftUI

struct MatchHistoryView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity

    var body: some View {
        List {
            if connectivity.scoreState.matchHistory.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No matches yet")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Start a new game to begin recording")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                // History is oldest first; the list shows newest first. Rows are identified by match id.
                ForEach(connectivity.scoreState.matchHistory.enumerated().reversed(), id: \.element.id) {
                    index, match in
                    NavigationLink(
                        destination: MatchDetailView(
                            match: match,
                            matchNumber: index + 1,
                            allMatches: connectivity.scoreState.matchHistory
                        )
                    ) {
                        MatchRowView(match: match, matchNumber: index + 1)
                    }
                }
                .onDelete { displayOffsets in
                    // Resolve every row to its match id before deleting: each deletion shifts the indices
                    let history = connectivity.scoreState.matchHistory
                    let ids = displayOffsets.map { history[history.count - 1 - $0].id }
                    for id in ids {
                        if let index = connectivity.scoreState.matchHistory.firstIndex(where: { $0.id == id }) {
                            connectivity.deleteMatchFromHistory(at: index)
                        }
                    }
                }
            }
        }
        .navigationTitle("All Matches")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct MatchRowView: View {
    let match: MatchResult
    let matchNumber: Int

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    /// First name of player 1 or 2, from the names stored with the match.
    private func shortName(_ player: Int) -> String {
        let fullName = player == 1 ? match.playerOneName : match.playerTwoName
        return fullName?.split(separator: " ").first.map(String.init) ?? "P\(player)"
    }

    private var resultBadge: String {
        switch match.winner {
        case 1: return "\(shortName(1)) Won"
        case 2: return "\(shortName(2)) Won"
        default: return "No winner"
        }
    }

    private var hasVideo: Bool {
        VideoStore.exists(match.highlightVideoURL) || VideoStore.exists(match.fullVideoURL)
    }

    private var winnerColor: Color {
        switch match.winner {
        case 1: return .blue
        case 2: return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = match.name {
                        Text(name)
                            .font(.headline)
                        Text("Match \(matchNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Match \(matchNumber)")
                            .font(.headline)
                    }
                }

                Spacer()

                Text(dateFormatter.string(from: match.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                // Score
                HStack(spacing: 4) {
                    Text("\(match.playerOneGames)")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.blue)
                    Text("-")
                        .foregroundColor(.gray)
                    Text("\(match.playerTwoGames)")
                        .font(.title2)
                        .bold()
                        .foregroundColor(.red)
                }

                // Winner badge
                Text(resultBadge)
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(winnerColor.opacity(0.2))
                    .foregroundColor(winnerColor)
                    .cornerRadius(6)

                Spacer()

                // Highlights indicator
                let totalHighlights = match.highlightCount
                if totalHighlights > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                        Text("\(totalHighlights)")
                    }
                    .font(.caption)
                    .foregroundColor(.yellow)
                }

                // Video indicator: only when a video file is actually on disk
                if hasVideo {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(.green)
                }
            }

            // Match info
            HStack(spacing: 12) {
                // Duration
                if let duration = match.duration {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text(formatDuration(duration))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Total points
                let totalPoints = match.totalPoints
                if totalPoints > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.grid.cross")
                        Text("\(totalPoints) pts")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Games breakdown
                if !match.games.isEmpty {
                    HStack(spacing: 4) {
                        Text("Games:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ForEach(Array(match.games.enumerated()), id: \.offset) { _, game in
                            Text("\(game.playerOneScore)-\(game.playerTwoScore)")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        }
        return String(format: "%ds", secs)
    }
}

#Preview {
    let fixture = PreviewSupport.makeFixture()
    NavigationStack {
        MatchHistoryView()
    }
    .environment(fixture.connectivity)
    .modelContainer(fixture.container)
}
