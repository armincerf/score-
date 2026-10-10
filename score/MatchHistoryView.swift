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
                ForEach(Array(connectivity.scoreState.matchHistory.enumerated().reversed()), id: \.offset) {
                    index, match in
                    NavigationLink(
                        destination: MatchDetailView(
                            match: match,
                            matchNumber: connectivity.scoreState.matchHistory.count - index,
                            allMatches: connectivity.scoreState.matchHistory
                        )
                    ) {
                        MatchRowView(match: match, matchNumber: connectivity.scoreState.matchHistory.count - index)
                    }
                }
                .onDelete { indexSet in
                    for displayIndex in indexSet {
                        let reversedIndices = Array(connectivity.scoreState.matchHistory.indices.reversed())
                        let actualIndex = reversedIndices[displayIndex]
                        connectivity.deleteMatchFromHistory(at: actualIndex)
                    }
                }
            }
        }
        .navigationTitle("Match History")
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

    private func extractPlayerName(playerNumber: Int) -> String {
        if let stored = playerNumber == 1 ? match.playerOneName : match.playerTwoName {
            return stored.split(separator: " ").first.map(String.init) ?? stored
        }
        guard let name = match.name else {
            return playerNumber == 1 ? "P1" : "P2"
        }

        // Extract base name (before timestamp)
        let baseName: String
        if let dashRange = name.range(of: " - ", options: .backwards) {
            baseName = String(name[..<dashRange.lowerBound])
        } else {
            baseName = name
        }

        // Split by " vs "
        if let vsRange = baseName.range(of: " vs ") {
            if playerNumber == 1 {
                let fullName = String(baseName[..<vsRange.lowerBound])
                return fullName.split(separator: " ").first.map(String.init) ?? "P1"
            }
            let fullName = String(baseName[vsRange.upperBound...])
            return fullName.split(separator: " ").first.map(String.init) ?? "P2"
        }

        return playerNumber == 1 ? "P1" : "P2"
    }

    private var resultBadge: String {
        switch match.winner {
        case 1: return "\(extractPlayerName(playerNumber: 1)) Won"
        case 2: return "\(extractPlayerName(playerNumber: 2)) Won"
        default: return "No winner"
        }
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
                let totalHighlights = match.games.reduce(0) { $0 + $1.points.filter(\.isHighlight).count }
                if totalHighlights > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                        Text("\(totalHighlights)")
                    }
                    .font(.caption)
                    .foregroundColor(.yellow)
                }

                // Video indicator
                if match.highlightVideoURL != nil {
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
