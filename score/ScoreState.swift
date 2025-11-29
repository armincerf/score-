//
//  ScoreState.swift
//  score
//
//  Shared model for syncing scores between iOS and watchOS
//  Add to BOTH targets in Xcode
//

import Foundation

// MARK: - Point Event (for video timestamp tracking)

struct PointEvent: Codable, Sendable {
    let player: Int              // 1 or 2
    let timestamp: Date          // When point was scored
    var isHighlight: Bool        // Was this marked as a highlight?
    let videoTimestamp: Double?  // Seconds from video start (set by iOS only)
    var wasServing: Bool         // Was the scoring player serving?

    init(player: Int, timestamp: Date = Date(), isHighlight: Bool = false, videoTimestamp: Double? = nil, wasServing: Bool = false) {
        self.player = player
        self.timestamp = timestamp
        self.isHighlight = isHighlight
        self.videoTimestamp = videoTimestamp
        self.wasServing = wasServing
    }
}

// MARK: - Highlight Event (for highlight reel generation)

struct HighlightClip: Codable, Identifiable, Sendable {
    let id: UUID
    let startTimestamp: Double   // Video time when clip starts (last score before highlight)
    let endTimestamp: Double     // Video time when highlight button was pressed
    let player: Int?             // Player responsible for the highlight (nil if pending)
    let gameNumber: Int          // Which game this highlight belongs to

    init(id: UUID = UUID(), startTimestamp: Double, endTimestamp: Double, player: Int? = nil, gameNumber: Int) {
        self.id = id
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.player = player
        self.gameNumber = gameNumber
    }
}

// MARK: - Game Result

struct GameResult: Codable, Sendable {
    let playerOneScore: Int
    let playerTwoScore: Int
    let winner: Int // 1 or 2
    let timestamp: Date
    let points: [PointEvent]  // All points scored in this game
    let duration: TimeInterval?  // Game duration in seconds
    let firstServer: Int  // Who served first in this game (1 or 2)

    init(playerOneScore: Int, playerTwoScore: Int, winner: Int, timestamp: Date = Date(), points: [PointEvent] = [], duration: TimeInterval? = nil, firstServer: Int = 1) {
        self.playerOneScore = playerOneScore
        self.playerTwoScore = playerTwoScore
        self.winner = winner
        self.timestamp = timestamp
        self.points = points
        self.duration = duration
        self.firstServer = firstServer
    }

    // MARK: - Statistics

    var averagePointTime: TimeInterval? {
        guard points.count > 1 else { return nil }

        // Calculate time between consecutive points using video timestamps
        var totalTime: TimeInterval = 0
        var validIntervals = 0

        for i in 1..<points.count {
            if let prevTime = points[i-1].videoTimestamp,
               let currTime = points[i].videoTimestamp {
                totalTime += (currTime - prevTime)
                validIntervals += 1
            }
        }

        return validIntervals > 0 ? totalTime / Double(validIntervals) : nil
    }

    // MARK: - Serving Statistics

    var pointsWonOnServeP1: Int {
        points.filter { $0.player == 1 && $0.wasServing }.count
    }

    var pointsWonOnServeP2: Int {
        points.filter { $0.player == 2 && $0.wasServing }.count
    }
}

// MARK: - Match Result

struct MatchResult: Codable, Sendable {
    let name: String?  // Match name (e.g., "John vs Jane")
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int // 1 or 2
    let games: [GameResult]
    let timestamp: Date
    let fullVideoURL: String?  // Path to full unedited video
    let highlightVideoURL: String?  // Path to generated highlight reel
    let duration: TimeInterval?  // Total match duration in seconds

    init(name: String? = nil, playerOneGames: Int, playerTwoGames: Int, winner: Int, games: [GameResult], timestamp: Date = Date(), fullVideoURL: String? = nil, highlightVideoURL: String? = nil, duration: TimeInterval? = nil) {
        self.name = name
        self.playerOneGames = playerOneGames
        self.playerTwoGames = playerTwoGames
        self.winner = winner
        self.games = games
        self.timestamp = timestamp
        self.fullVideoURL = fullVideoURL
        self.highlightVideoURL = highlightVideoURL
        self.duration = duration
    }

    // MARK: - Statistics

    var averageGameTime: TimeInterval? {
        let durations = games.compactMap { $0.duration }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    var averagePointTime: TimeInterval? {
        let pointTimes = games.compactMap { $0.averagePointTime }
        guard !pointTimes.isEmpty else { return nil }
        return pointTimes.reduce(0, +) / Double(pointTimes.count)
    }

    var totalPoints: Int {
        games.reduce(0) { $0 + $1.points.count }
    }

    // MARK: - Serving Statistics

    var totalPointsWonOnServeP1: Int {
        games.reduce(0) { $0 + $1.pointsWonOnServeP1 }
    }

    var totalPointsWonOnServeP2: Int {
        games.reduce(0) { $0 + $1.pointsWonOnServeP2 }
    }

    var serveWinPercentageP1: Double? {
        // Calculate total serves for P1 across all games
        let totalServes = games.reduce(0) { sum, game in
            sum + ServingLogic.calculateTotalServes(
                forPlayer: 1,
                firstServer: game.firstServer,
                finalP1Score: game.playerOneScore,
                finalP2Score: game.playerTwoScore
            )
        }

        guard totalServes > 0 else { return nil }
        return (Double(totalPointsWonOnServeP1) / Double(totalServes)) * 100.0
    }

    var serveWinPercentageP2: Double? {
        // Calculate total serves for P2 across all games
        let totalServes = games.reduce(0) { sum, game in
            sum + ServingLogic.calculateTotalServes(
                forPlayer: 2,
                firstServer: game.firstServer,
                finalP1Score: game.playerOneScore,
                finalP2Score: game.playerTwoScore
            )
        }

        guard totalServes > 0 else { return nil }
        return (Double(totalPointsWonOnServeP2) / Double(totalServes)) * 100.0
    }
}

// MARK: - Score State

struct ScoreState: Codable, Sendable {
    var playerOneScore: Int
    var playerTwoScore: Int
    var playerOneGames: Int
    var playerTwoGames: Int
    var currentMatchGames: [GameResult]
    var matchHistory: [MatchResult]

    // Point-level tracking for current game
    var currentGamePoints: [PointEvent]

    // Highlight clips for the match (for video generation)
    var highlightClips: [HighlightClip]

    // Pending highlight that needs player attribution
    var pendingHighlight: HighlightClip?

    // Recording state
    var isRecording: Bool
    var recordingStartTime: Date?
    var currentMatchName: String?

    // Player names for current match
    var playerOneName: String?
    var playerTwoName: String?

    // Serving state
    var servingPlayer: Int  // 1 or 2 - who is currently serving
    var currentGameFirstServer: Int?  // Who served first in current game

    init(
        playerOneScore: Int = 0,
        playerTwoScore: Int = 0,
        playerOneGames: Int = 0,
        playerTwoGames: Int = 0,
        currentMatchGames: [GameResult] = [],
        matchHistory: [MatchResult] = [],
        currentGamePoints: [PointEvent] = [],
        highlightClips: [HighlightClip] = [],
        pendingHighlight: HighlightClip? = nil,
        isRecording: Bool = false,
        recordingStartTime: Date? = nil,
        currentMatchName: String? = nil,
        playerOneName: String? = nil,
        playerTwoName: String? = nil,
        servingPlayer: Int = 1,
        currentGameFirstServer: Int? = nil
    ) {
        self.playerOneScore = playerOneScore
        self.playerTwoScore = playerTwoScore
        self.playerOneGames = playerOneGames
        self.playerTwoGames = playerTwoGames
        self.currentMatchGames = currentMatchGames
        self.matchHistory = matchHistory
        self.currentGamePoints = currentGamePoints
        self.highlightClips = highlightClips
        self.pendingHighlight = pendingHighlight
        self.isRecording = isRecording
        self.recordingStartTime = recordingStartTime
        self.currentMatchName = currentMatchName
        self.playerOneName = playerOneName
        self.playerTwoName = playerTwoName
        self.servingPlayer = servingPlayer
        self.currentGameFirstServer = currentGameFirstServer
    }

    // MARK: - Computed Properties

    var totalHighlightsInCurrentGame: Int {
        highlightClips.filter { $0.gameNumber == currentMatchGames.count }.count
    }

    var totalHighlightsInMatch: Int {
        highlightClips.count + (pendingHighlight != nil ? 1 : 0)
    }

    var hasPendingHighlight: Bool {
        pendingHighlight != nil
    }

    // MARK: - Dictionary Conversion for WatchConnectivity

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "playerOneScore": playerOneScore,
            "playerTwoScore": playerTwoScore,
            "playerOneGames": playerOneGames,
            "playerTwoGames": playerTwoGames,
            "isRecording": isRecording,
            "servingPlayer": servingPlayer
        ]

        // Encode complex types to Data
        if let gamesData = try? JSONEncoder().encode(currentMatchGames) {
            dict["currentMatchGames"] = gamesData
        }

        if let matchData = try? JSONEncoder().encode(matchHistory) {
            dict["matchHistory"] = matchData
        }

        if let pointsData = try? JSONEncoder().encode(currentGamePoints) {
            dict["currentGamePoints"] = pointsData
        }

        if let startTime = recordingStartTime {
            dict["recordingStartTime"] = startTime.timeIntervalSince1970
        }

        if let matchName = currentMatchName {
            dict["currentMatchName"] = matchName
        }

        if let p1Name = playerOneName {
            dict["playerOneName"] = p1Name
        }

        if let p2Name = playerTwoName {
            dict["playerTwoName"] = p2Name
        }

        if let firstServer = currentGameFirstServer {
            dict["currentGameFirstServer"] = firstServer
        }

        // Include highlight info for watch display
        dict["highlightCount"] = totalHighlightsInMatch
        dict["hasPendingHighlight"] = hasPendingHighlight

        return dict
    }

    // Parse from dictionary
    init?(dictionary: [String: Any]) {
        guard
            let p1Score = dictionary["playerOneScore"] as? Int,
            let p2Score = dictionary["playerTwoScore"] as? Int
        else { return nil }

        self.playerOneScore = p1Score
        self.playerTwoScore = p2Score
        self.playerOneGames = dictionary["playerOneGames"] as? Int ?? 0
        self.playerTwoGames = dictionary["playerTwoGames"] as? Int ?? 0
        self.isRecording = dictionary["isRecording"] as? Bool ?? false
        self.currentMatchName = dictionary["currentMatchName"] as? String
        self.playerOneName = dictionary["playerOneName"] as? String
        self.playerTwoName = dictionary["playerTwoName"] as? String
        self.servingPlayer = dictionary["servingPlayer"] as? Int ?? 1
        self.currentGameFirstServer = dictionary["currentGameFirstServer"] as? Int

        if let startTimeInterval = dictionary["recordingStartTime"] as? TimeInterval {
            self.recordingStartTime = Date(timeIntervalSince1970: startTimeInterval)
        } else {
            self.recordingStartTime = nil
        }

        // Decode complex types from Data
        if let gamesData = dictionary["currentMatchGames"] as? Data {
            self.currentMatchGames = (try? JSONDecoder().decode([GameResult].self, from: gamesData)) ?? []
        } else {
            self.currentMatchGames = []
        }

        if let matchData = dictionary["matchHistory"] as? Data {
            self.matchHistory = (try? JSONDecoder().decode([MatchResult].self, from: matchData)) ?? []
        } else {
            self.matchHistory = []
        }

        if let pointsData = dictionary["currentGamePoints"] as? Data {
            self.currentGamePoints = (try? JSONDecoder().decode([PointEvent].self, from: pointsData)) ?? []
        } else {
            self.currentGamePoints = []
        }

        // Highlight clips are only managed on iOS side, not synced via dictionary
        self.highlightClips = []
        self.pendingHighlight = nil
    }

    // MARK: - Factory Methods

    /// Creates a fresh ScoreState for a new match, preserving only match history
    /// This ensures all match-scoped state is properly reset
    static func forNewMatch(
        preservingHistoryFrom previous: ScoreState,
        matchName: String,
        playerOneName: String,
        playerTwoName: String,
        initialServer: Int,
        recordingStartTime: Date? = nil
    ) -> ScoreState {
        return ScoreState(
            playerOneScore: 0,
            playerTwoScore: 0,
            playerOneGames: 0,
            playerTwoGames: 0,
            currentMatchGames: [],
            matchHistory: previous.matchHistory,  // Preserve match history only
            currentGamePoints: [],
            highlightClips: [],
            pendingHighlight: nil,
            isRecording: recordingStartTime != nil,
            recordingStartTime: recordingStartTime,
            currentMatchName: matchName,
            playerOneName: playerOneName,
            playerTwoName: playerTwoName,
            servingPlayer: initialServer,
            currentGameFirstServer: initialServer
        )
    }
}
