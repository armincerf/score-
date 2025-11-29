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

// MARK: - Game Result

struct GameResult: Codable, Sendable {
    let playerOneScore: Int
    let playerTwoScore: Int
    let winner: Int // 1 or 2
    let timestamp: Date
    let points: [PointEvent]  // All points scored in this game
    let firstServer: Int  // Who served first in this game (1 or 2)

    init(playerOneScore: Int, playerTwoScore: Int, winner: Int, timestamp: Date = Date(), points: [PointEvent] = [], firstServer: Int = 1) {
        self.playerOneScore = playerOneScore
        self.playerTwoScore = playerTwoScore
        self.winner = winner
        self.timestamp = timestamp
        self.points = points
        self.firstServer = firstServer
    }
}

// MARK: - Match Result

struct MatchResult: Codable, Sendable {
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int // 1 or 2
    let games: [GameResult]
    let timestamp: Date
    let highlightVideoURL: String?  // Path to generated highlight reel

    init(playerOneGames: Int, playerTwoGames: Int, winner: Int, games: [GameResult], timestamp: Date = Date(), highlightVideoURL: String? = nil) {
        self.playerOneGames = playerOneGames
        self.playerTwoGames = playerTwoGames
        self.winner = winner
        self.games = games
        self.timestamp = timestamp
        self.highlightVideoURL = highlightVideoURL
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

    // Pending highlight that needs player attribution
    var hasPendingHighlight: Bool

    // Highlight count (synced from iOS)
    var highlightCount: Int

    // Recording state
    var isRecording: Bool
    var recordingStartTime: Date?

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
        hasPendingHighlight: Bool = false,
        highlightCount: Int = 0,
        isRecording: Bool = false,
        recordingStartTime: Date? = nil,
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
        self.hasPendingHighlight = hasPendingHighlight
        self.highlightCount = highlightCount
        self.isRecording = isRecording
        self.recordingStartTime = recordingStartTime
        self.playerOneName = playerOneName
        self.playerTwoName = playerTwoName
        self.servingPlayer = servingPlayer
        self.currentGameFirstServer = currentGameFirstServer
    }

    // MARK: - Computed Properties

    var totalHighlightsInMatch: Int {
        highlightCount
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

        if let firstServer = currentGameFirstServer {
            dict["currentGameFirstServer"] = firstServer
        }

        // Include highlight count for watch display
        dict["highlightCount"] = totalHighlightsInMatch

        // Include player names
        if let name = playerOneName {
            dict["playerOneName"] = name
        }
        if let name = playerTwoName {
            dict["playerTwoName"] = name
        }

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
        self.hasPendingHighlight = dictionary["hasPendingHighlight"] as? Bool ?? false
        self.highlightCount = dictionary["highlightCount"] as? Int ?? 0
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
    }
}
