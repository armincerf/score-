//
//  EventModels.swift
//  score
//
//  Event sourcing models - stores every action as an immutable event
//

import Foundation

// MARK: - Event Type Enum

enum EventType: String, Codable, Sendable {
    case matchStarted
    case pointScored
    case highlightMarked
    case highlightAttributed  // When player is assigned to a highlight
    case gameEnded
    case matchEnded
    case eventUndone
}

// MARK: - Base Event Protocol

protocol MatchEvent: Codable, Identifiable, Sendable {
    var id: UUID { get }
    var matchId: UUID { get }
    var timestamp: Date { get }
    var sequenceNumber: Int { get }
    var eventType: EventType { get }
}

// MARK: - Match Started Event

struct MatchStartedEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .matchStarted }

    let matchName: String
    let playerOneName: String
    let playerTwoName: String
    let recordingStartTime: Date
    let videoFilePath: String?  // Path to video file being recorded
    let initialServer: Int  // Who serves first (1 or 2) - persisted for replay consistency

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        matchName: String,
        playerOneName: String,
        playerTwoName: String,
        recordingStartTime: Date,
        videoFilePath: String? = nil,
        initialServer: Int = 1
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.matchName = matchName
        self.playerOneName = playerOneName
        self.playerTwoName = playerTwoName
        self.recordingStartTime = recordingStartTime
        self.videoFilePath = videoFilePath
        self.initialServer = initialServer
    }
}

// MARK: - Point Scored Event

struct PointScoredEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .pointScored }

    let player: Int  // 1 or 2
    let videoTimestamp: Double?
    let gameNumber: Int  // Which game in the match (0-based)

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        player: Int,
        videoTimestamp: Double?,
        gameNumber: Int
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.player = player
        self.videoTimestamp = videoTimestamp
        self.gameNumber = gameNumber
    }
}

// MARK: - Highlight Marked Event

struct HighlightMarkedEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .highlightMarked }

    let videoTimestamp: Double  // When the highlight button was pressed (video time)
    let player: Int?  // Player who won this point (1 or 2), set when next score happens
    let gameNumber: Int  // Which game this highlight belongs to

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        videoTimestamp: Double,
        player: Int? = nil,
        gameNumber: Int
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.videoTimestamp = videoTimestamp
        self.player = player
        self.gameNumber = gameNumber
    }
}

// MARK: - Highlight Attributed Event

struct HighlightAttributedEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .highlightAttributed }

    let highlightEventId: UUID  // References the HighlightMarkedEvent
    let player: Int  // Player who won this point (1 or 2)

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        highlightEventId: UUID,
        player: Int
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.highlightEventId = highlightEventId
        self.player = player
    }
}

// MARK: - Game Ended Event

struct GameEndedEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .gameEnded }

    let gameNumber: Int
    let playerOneScore: Int
    let playerTwoScore: Int
    let winner: Int
    let gameDuration: TimeInterval

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        gameNumber: Int,
        playerOneScore: Int,
        playerTwoScore: Int,
        winner: Int,
        gameDuration: TimeInterval
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.gameNumber = gameNumber
        self.playerOneScore = playerOneScore
        self.playerTwoScore = playerTwoScore
        self.winner = winner
        self.gameDuration = gameDuration
    }
}

// MARK: - Match Ended Event

struct MatchEndedEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .matchEnded }

    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int
    let matchDuration: TimeInterval
    let highlightVideoURL: String?

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        playerOneGames: Int,
        playerTwoGames: Int,
        winner: Int,
        matchDuration: TimeInterval,
        highlightVideoURL: String?
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.playerOneGames = playerOneGames
        self.playerTwoGames = playerTwoGames
        self.winner = winner
        self.matchDuration = matchDuration
        self.highlightVideoURL = highlightVideoURL
    }
}

// MARK: - Event Undone (Soft Delete)

struct EventUndoneEvent: MatchEvent {
    let id: UUID
    let matchId: UUID
    let timestamp: Date
    let sequenceNumber: Int
    var eventType: EventType { .eventUndone }

    let undoneEventId: UUID  // Which event is being undone
    let reason: String?  // "user_undo", "auto_correction", etc.

    init(
        id: UUID = UUID(),
        matchId: UUID,
        timestamp: Date = Date(),
        sequenceNumber: Int,
        undoneEventId: UUID,
        reason: String? = nil
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.undoneEventId = undoneEventId
        self.reason = reason
    }
}
