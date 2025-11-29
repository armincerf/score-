//
//  WatchSyncState.swift
//  score
//
//  Minimal state sync payload for watch communication
//  Shared between iOS and watchOS
//

import Foundation

// MARK: - Watch Sync State

/// Minimal state synced to watch (only current game info, no history)
/// Reduces payload from 10-50KB to ~500 bytes
struct WatchSyncState: Codable {
    // Current game scores
    let playerOneScore: Int
    let playerTwoScore: Int
    let playerOneGames: Int
    let playerTwoGames: Int

    // Match metadata
    let isRecording: Bool
    let playerOneName: String?
    let playerTwoName: String?

    // Highlight tracking
    let highlightCountInCurrentGame: Int
    let highlightCountInMatch: Int

    // Action confirmation (for fixing race condition)
    let confirmedActionId: String?

    init(
        playerOneScore: Int,
        playerTwoScore: Int,
        playerOneGames: Int,
        playerTwoGames: Int,
        isRecording: Bool,
        playerOneName: String? = nil,
        playerTwoName: String? = nil,
        highlightCountInCurrentGame: Int = 0,
        highlightCountInMatch: Int = 0,
        confirmedActionId: String? = nil
    ) {
        self.playerOneScore = playerOneScore
        self.playerTwoScore = playerTwoScore
        self.playerOneGames = playerOneGames
        self.playerTwoGames = playerTwoGames
        self.isRecording = isRecording
        self.playerOneName = playerOneName
        self.playerTwoName = playerTwoName
        self.highlightCountInCurrentGame = highlightCountInCurrentGame
        self.highlightCountInMatch = highlightCountInMatch
        self.confirmedActionId = confirmedActionId
    }

    // MARK: - Dictionary Conversion

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "playerOneScore": playerOneScore,
            "playerTwoScore": playerTwoScore,
            "playerOneGames": playerOneGames,
            "playerTwoGames": playerTwoGames,
            "isRecording": isRecording,
            "highlightCountInCurrentGame": highlightCountInCurrentGame,
            "highlightCountInMatch": highlightCountInMatch
        ]

        if let name = playerOneName {
            dict["playerOneName"] = name
        }

        if let name = playerTwoName {
            dict["playerTwoName"] = name
        }

        if let actionId = confirmedActionId {
            dict["confirmedActionId"] = actionId
        }

        return dict
    }

    // MARK: - Parse from Dictionary

    init?(dictionary: [String: Any]) {
        guard
            let p1Score = dictionary["playerOneScore"] as? Int,
            let p2Score = dictionary["playerTwoScore"] as? Int,
            let p1Games = dictionary["playerOneGames"] as? Int,
            let p2Games = dictionary["playerTwoGames"] as? Int,
            let recording = dictionary["isRecording"] as? Bool
        else {
            return nil
        }

        self.playerOneScore = p1Score
        self.playerTwoScore = p2Score
        self.playerOneGames = p1Games
        self.playerTwoGames = p2Games
        self.isRecording = recording
        self.playerOneName = dictionary["playerOneName"] as? String
        self.playerTwoName = dictionary["playerTwoName"] as? String
        self.highlightCountInCurrentGame = dictionary["highlightCountInCurrentGame"] as? Int ?? 0
        self.highlightCountInMatch = dictionary["highlightCountInMatch"] as? Int ?? 0
        self.confirmedActionId = dictionary["confirmedActionId"] as? String
    }
}

// MARK: - Pending Action (with UUID for race condition fix)

struct PendingAction: Codable {
    let id: UUID
    let type: ActionType
    let timestamp: Date

    enum ActionType: String, Codable {
        case player1Score
        case player2Score
        case highlight
    }

    init(id: UUID = UUID(), type: ActionType, timestamp: Date = Date()) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
    }
}
