//
//  MatchDetailView.swift
//  score
//
//  One finished match: header, videos (MatchVideosSection), AI summary, stats, games and highlights
//

import FoundationModels
import SwiftUI
import os

struct MatchDetailView: View {
    let match: MatchResult
    let matchNumber: Int
    let allMatches: [MatchResult]
    /// Visible height of the scroll view, for the video player's height cap (see `InlinePlayerLayout`).
    @State private var viewportHeight: CGFloat = 0

    init(match: MatchResult, matchNumber: Int, allMatches: [MatchResult] = []) {
        self.match = match
        self.matchNumber = matchNumber
        self.allMatches = allMatches
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }

    /// The file behind a stored video reference, or nil when there is none or it is not on disk.
    private static func existingVideo(_ reference: String?) -> URL? {
        VideoStore.exists(reference) ? VideoStore.resolve(reference) : nil
    }

    private var highlightVideoURL: URL? { Self.existingVideo(match.highlightVideoURL) }

    private var fullVideoURL: URL? { Self.existingVideo(match.fullVideoURL) }

    private var playerOneName: String {
        match.playerOneName ?? "Player 1"
    }

    private var playerTwoName: String {
        match.playerTwoName ?? "Player 2"
    }

    private var resultBadgeText: String {
        switch match.winner {
        case 1: return "\(playerOneName) Wins!"
        case 2: return "\(playerTwoName) Wins!"
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
        ScrollView {
            VStack(spacing: 24) {
                // Match header
                VStack(spacing: 12) {
                    if let name = match.name {
                        Text(name)
                            .font(.title)
                            .bold()
                            .multilineTextAlignment(.center)
                        Text("Match \(matchNumber)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Match \(matchNumber)")
                            .font(.title)
                            .bold()
                    }

                    Text(dateFormatter.string(from: match.timestamp))
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // Final score
                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text(playerOneName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("\(match.playerOneGames)")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(.blue)
                        }

                        Text("-")
                            .font(.largeTitle)
                            .foregroundColor(.gray)

                        VStack(spacing: 4) {
                            Text(playerTwoName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("\(match.playerTwoGames)")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }

                    // Winner badge
                    Text(resultBadgeText)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(winnerColor.opacity(0.2))
                        .foregroundColor(winnerColor)
                        .cornerRadius(8)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                MatchVideosSection(
                    highlightVideo: highlightVideoURL, fullVideo: fullVideoURL, highlightCount: match.highlightCount,
                    viewportHeight: viewportHeight)

                // AI Match Summary
                MatchSummaryContainer(matchResult: match, allMatches: allMatches)

                // Match Statistics
                VStack(alignment: .leading, spacing: 12) {
                    Text("Match Statistics")
                        .font(.headline)

                    VStack(spacing: 8) {
                        if let duration = match.duration {
                            StatRow(label: "Match Duration", value: formatDuration(duration))
                        }

                        if let avgGameTime = match.averageGameTime {
                            StatRow(label: "Avg Game Time", value: formatDuration(avgGameTime))
                        }

                        if let avgPointTime = match.averagePointTime {
                            StatRow(label: "Avg Point Time", value: formatDuration(avgPointTime))
                        }

                        StatRow(label: "Total Points", value: "\(match.totalPoints)")

                        let totalHighlights = match.highlightCount
                        if totalHighlights > 0 {
                            StatRow(label: "Highlights", value: "\(totalHighlights)")
                        }

                        // Serving statistics
                        let p1ServePoints = match.totalPointsWonOnServeP1
                        let p2ServePoints = match.totalPointsWonOnServeP2
                        if p1ServePoints > 0 || p2ServePoints > 0 {
                            StatRow(
                                label: "Points Won on Serve",
                                value: "\(p1ServePoints) - \(p2ServePoints)"
                            )
                        }

                        if let p1Pct = match.serveWinPercentageP1 {
                            StatRow(
                                label: "\(playerOneName) Serve Win %",
                                value: "\(Int(p1Pct))%"
                            )
                        }

                        if let p2Pct = match.serveWinPercentageP2 {
                            StatRow(
                                label: "\(playerTwoName) Serve Win %",
                                value: "\(Int(p2Pct))%"
                            )
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                // Games breakdown
                VStack(alignment: .leading, spacing: 12) {
                    Text("Games")
                        .font(.headline)

                    ForEach(Array(match.games.enumerated()), id: \.offset) { index, game in
                        GameDetailRow(
                            game: game,
                            gameNumber: index + 1,
                            highlightCount: match.highlightClips.filter { $0.gameNumber == index }.count
                        )
                    }
                }

                // Highlights list
                let allHighlights = match.highlightClips
                if !allHighlights.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text("Highlights (\(allHighlights.count))")
                                .font(.headline)
                        }

                        ForEach(Array(allHighlights.enumerated()), id: \.element.id) { index, clip in
                            HighlightRow(
                                clip: clip,
                                number: index + 1,
                                playerOneName: playerOneName,
                                playerTwoName: playerTwoName
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height  // the safe area: below the navigation bar, above the home indicator
        } action: { height in
            viewportHeight = height
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Formatting helpers

extension MatchDetailView {
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        }
        return String(format: "%ds", secs)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .bold()
                .monospacedDigit()
        }
    }
}

struct GameDetailRow: View {
    let game: GameResult
    let gameNumber: Int
    var highlightCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Game \(gameNumber)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 8) {
                    Text("\(game.playerOneScore)")
                        .font(.headline)
                        .foregroundColor(.blue)
                    Text("-")
                        .foregroundColor(.gray)
                    Text("\(game.playerTwoScore)")
                        .font(.headline)
                        .foregroundColor(.red)

                    Text(game.winner == 1 ? "P1" : "P2")
                        .font(.caption)
                        .bold()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(game.winner == 1 ? Color.blue.opacity(0.2) : Color.red.opacity(0.2))
                        .foregroundColor(game.winner == 1 ? .blue : .red)
                        .cornerRadius(4)
                }

                let highlights = highlightCount
                if highlights > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                        Text("\(highlights)")
                    }
                    .font(.caption)
                    .foregroundColor(.yellow)
                }
            }

            // Game stats
            HStack(spacing: 16) {
                if let duration = game.duration {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text(formatGameDuration(duration))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                if let avgPointTime = game.averagePointTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text("\(Int(avgPointTime))s/pt")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "circle.grid.cross")
                    Text("\(game.points.count) pts")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func formatGameDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        }
        return String(format: "%ds", secs)
    }
}

struct HighlightRow: View {
    let clip: HighlightClip
    let number: Int
    let playerOneName: String
    let playerTwoName: String

    private var playerName: String {
        switch clip.player {
        case 1: return playerOneName
        case 2: return playerTwoName
        default: return "Unattributed"
        }
    }

    private var playerColor: Color {
        switch clip.player {
        case 1: return .blue
        case 2: return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Text("\(number).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(playerName)
                    .font(.subheadline)
                    .foregroundColor(playerColor)

                Text("Game \(clip.gameNumber + 1)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(formatTimestamp(clip.startTimestamp)) – \(formatTimestamp(clip.endTimestamp))")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(6)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    NavigationStack {
        MatchDetailView(
            match: MatchResult(
                name: "John vs Jane - Nov 29, 3:45 PM",
                playerOneName: "John",
                playerTwoName: "Jane",
                playerOneGames: 3,
                playerTwoGames: 1,
                winner: 1,
                games: [
                    GameResult(
                        playerOneScore: 11, playerTwoScore: 7, winner: 1,
                        points: [
                            PointEvent(player: 1, isHighlight: true, videoTimestamp: 45.2)
                        ], duration: 180),
                    GameResult(playerOneScore: 11, playerTwoScore: 9, winner: 1, points: [], duration: 210),
                    GameResult(playerOneScore: 9, playerTwoScore: 11, winner: 2, points: [], duration: 195),
                    GameResult(playerOneScore: 11, playerTwoScore: 8, winner: 1, points: [], duration: 165),
                ],
                duration: 750
            ),
            matchNumber: 1,
            allMatches: []
        )
    }
}
