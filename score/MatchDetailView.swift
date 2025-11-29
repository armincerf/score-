//
//  MatchDetailView.swift
//  score
//
//  Detailed match view with highlight reel playback
//

import SwiftUI
import AVKit
import FoundationModels

struct MatchDetailView: View {
    let match: MatchResult
    let matchNumber: Int
    let allMatches: [MatchResult]
    
    init(match: MatchResult, matchNumber: Int, allMatches: [MatchResult] = []) {
        self.match = match
        self.matchNumber = matchNumber
        self.allMatches = allMatches
    }

    @State private var highlightPlayer: AVPlayer?
    @State private var fullVideoPlayer: AVPlayer?
    @State private var currentVideoIndex = 0

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }

    private var hasHighlightVideo: Bool {
        guard let urlString = match.highlightVideoURL,
              let url = URL(string: urlString) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var hasFullVideo: Bool {
        guard let urlString = match.fullVideoURL,
              let url = URL(string: urlString) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var availableVideos: [(title: String, player: AVPlayer?, url: URL?, icon: String)] {
        var videos: [(String, AVPlayer?, URL?, String)] = []

        if hasHighlightVideo, let urlString = match.highlightVideoURL, let url = URL(string: urlString) {
            videos.append(("Highlight Reel", highlightPlayer, url, "star.fill"))
        }

        if hasFullVideo, let urlString = match.fullVideoURL, let url = URL(string: urlString) {
            videos.append(("Full Match", fullVideoPlayer, url, "video.fill"))
        }

        return videos
    }

    private var playerOneName: String {
        extractPlayerName(from: match.name, playerNumber: 1) ?? "Player 1"
    }

    private var playerTwoName: String {
        extractPlayerName(from: match.name, playerNumber: 2) ?? "Player 2"
    }

    private func extractPlayerName(from matchName: String?, playerNumber: Int) -> String? {
        guard let name = matchName else { return nil }

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
                return String(baseName[..<vsRange.lowerBound])
            } else {
                return String(baseName[vsRange.upperBound...])
            }
        }

        return nil
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
                    Text(match.winner == 1 ? "\(playerOneName) Wins!" : "\(playerTwoName) Wins!")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(match.winner == 1 ? Color.blue.opacity(0.2) : Color.red.opacity(0.2))
                        .foregroundColor(match.winner == 1 ? .blue : .red)
                        .cornerRadius(8)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

                // AI Match Summary
                if #available(iOS 26.0, *) {
                    MatchSummaryContainer(matchResult: match, allMatches: allMatches)
                } else {
                    MatchSummaryFallbackContainer(matchResult: match)
                }
                
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

                        let totalHighlights = match.games.reduce(0) { $0 + $1.points.filter { $0.isHighlight }.count }
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

                // Video carousel
                if !availableVideos.isEmpty {
                    VStack(spacing: 0) {
                        TabView(selection: $currentVideoIndex) {
                            ForEach(Array(availableVideos.enumerated()), id: \.offset) { index, video in
                                VStack(spacing: 12) {
                                    // Video header
                                    HStack {
                                        Image(systemName: video.icon)
                                            .foregroundColor(index == 0 ? .yellow : .blue)
                                        Text(video.title)
                                            .font(.headline)
                                        Spacer()

                                        // Share button
                                        if let url = video.url {
                                            ShareLink(
                                                item: VideoTransferable(
                                                    url: url,
                                                    name: video.title
                                                ),
                                                preview: SharePreview(
                                                    video.title,
                                                    image: Image(systemName: video.icon)
                                                )
                                            ) {
                                                Image(systemName: "square.and.arrow.up")
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.top, 12)

                                    // Video player
                                    if let player = video.player {
                                        VideoPlayer(player: player)
                                            .frame(height: 300)
                                            .cornerRadius(12)
                                            .padding(.horizontal)
                                            .onDisappear {
                                                player.pause()
                                            }
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .frame(height: 300)
                                            .cornerRadius(12)
                                            .padding(.horizontal)
                                            .overlay(
                                                ProgressView()
                                            )
                                    }

                                    // Page indicator hint
                                    if availableVideos.count > 1 {
                                        Text("Swipe to see \(index == 0 ? "full match" : "highlights")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .padding(.bottom, 8)
                                    }
                                }
                                .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: availableVideos.count > 1 ? .always : .never))
                        .frame(height: availableVideos.count > 1 ? 400 : 370)
                    }
                } else {
                    // No videos message
                    let totalHighlights = match.games.reduce(0) { $0 + $1.points.filter { $0.isHighlight }.count }
                    if totalHighlights == 0 {
                        VStack(spacing: 12) {
                            Image(systemName: "star.slash")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                            Text("No highlights marked")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Use the double-tap gesture on your watch or the star button to mark highlights during play")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                            Text("Video processing...")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("\(totalHighlights) highlights were marked")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                    }
                }

                // Games breakdown
                VStack(alignment: .leading, spacing: 12) {
                    Text("Games")
                        .font(.headline)

                    ForEach(Array(match.games.enumerated()), id: \.offset) { index, game in
                        GameDetailRow(game: game, gameNumber: index + 1)
                    }
                }

                // Highlights list
                let allHighlights = match.games.flatMap { $0.points.filter { $0.isHighlight } }
                if !allHighlights.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text("Highlights (\(allHighlights.count))")
                                .font(.headline)
                        }

                        ForEach(Array(allHighlights.enumerated()), id: \.offset) { index, point in
                            HighlightRow(
                                point: point,
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
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadVideos()
        }
    }

    private func loadVideos() {
        // Debug logging
        print("[MatchDetail] Loading videos for match")
        print("[MatchDetail] Highlight URL: \(match.highlightVideoURL ?? "nil")")
        print("[MatchDetail] Full video URL: \(match.fullVideoURL ?? "nil")")

        // Load highlight reel
        if let videoURLString = match.highlightVideoURL,
           let url = URL(string: videoURLString) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            print("[MatchDetail] Highlight file exists: \(exists) at \(url.path)")
            if exists {
                highlightPlayer = AVPlayer(url: url)
            }
        } else {
            print("[MatchDetail] No highlight URL or invalid URL")
        }

        // Load full video
        if let videoURLString = match.fullVideoURL,
           let url = URL(string: videoURLString) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            print("[MatchDetail] Full video file exists: \(exists) at \(url.path)")
            if exists {
                fullVideoPlayer = AVPlayer(url: url)
            }
        } else {
            print("[MatchDetail] No full video URL or invalid URL")
        }

        print("[MatchDetail] Available videos count: \(availableVideos.count)")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
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

                let highlights = game.points.filter { $0.isHighlight }.count
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
        } else {
            return String(format: "%ds", secs)
        }
    }
}

struct HighlightRow: View {
    let point: PointEvent
    let number: Int
    let playerOneName: String
    let playerTwoName: String

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }

    private var playerName: String {
        point.player == 1 ? playerOneName : playerTwoName
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Text("\(number).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(playerName)
                    .font(.subheadline)
                    .foregroundColor(point.player == 1 ? .blue : .red)
            }

            Spacer()

            if let videoTimestamp = point.videoTimestamp {
                Text(formatTimestamp(videoTimestamp))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            } else {
                Text(timeFormatter.string(from: point.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
                playerOneGames: 3,
                playerTwoGames: 1,
                winner: 1,
                games: [
                    GameResult(playerOneScore: 11, playerTwoScore: 7, winner: 1, points: [
                        PointEvent(player: 1, isHighlight: true, videoTimestamp: 45.2)
                    ], duration: 180),
                    GameResult(playerOneScore: 11, playerTwoScore: 9, winner: 1, points: [], duration: 210),
                    GameResult(playerOneScore: 9, playerTwoScore: 11, winner: 2, points: [], duration: 195),
                    GameResult(playerOneScore: 11, playerTwoScore: 8, winner: 1, points: [], duration: 165)
                ],
                duration: 750
            ),
            matchNumber: 1,
            allMatches: []
        )
    }
}
