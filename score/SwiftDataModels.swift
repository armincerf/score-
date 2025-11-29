//
//  SwiftDataModels.swift
//  score
//
//  SwiftData persistence models for event sourcing
//

import Foundation
import SwiftData

// MARK: - User Preferences

@Model
final class UserPreferences {
    @Attribute(.unique) var id: UUID
    var mostRecentPlayer1Name: String
    var mostRecentPlayer2Name: String
    var lastUpdated: Date

    // Camera settings (optional for migration compatibility)
    var cameraEnabled: Bool = true  // Master switch for camera recording
    var cameraDeviceType: String?  // Stored as string: "wide", "ultraWide", "telephoto", "dual", "triple"
    var videoQualityPreset: String?  // Stored as string: "high", "medium", "low", "hd720p", "hd1080p", "hd4K"

    init(
        id: UUID = UUID(),
        mostRecentPlayer1Name: String = "Player 1",
        mostRecentPlayer2Name: String = "Player 2",
        lastUpdated: Date = Date(),
        cameraEnabled: Bool = true,
        cameraDeviceType: String? = "wide",
        videoQualityPreset: String? = "hd720p"
    ) {
        self.id = id
        self.mostRecentPlayer1Name = mostRecentPlayer1Name
        self.mostRecentPlayer2Name = mostRecentPlayer2Name
        self.lastUpdated = lastUpdated
        self.cameraEnabled = cameraEnabled
        self.cameraDeviceType = cameraDeviceType
        self.videoQualityPreset = videoQualityPreset
    }
}

// MARK: - Stored Match Event

@Model
final class StoredMatchEvent {
    @Attribute(.unique) var id: UUID
    var matchId: UUID
    var timestamp: Date
    var sequenceNumber: Int
    var eventType: String  // EventType.rawValue
    var eventData: Data  // JSON-encoded specific event
    var isUndone: Bool  // For undo functionality

    // Relationship
    @Relationship(inverse: \StoredMatch.events) var match: StoredMatch?

    init(
        id: UUID,
        matchId: UUID,
        timestamp: Date,
        sequenceNumber: Int,
        eventType: String,
        eventData: Data,
        isUndone: Bool = false
    ) {
        self.id = id
        self.matchId = matchId
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.eventType = eventType
        self.eventData = eventData
        self.isUndone = isUndone
    }
}

// MARK: - Stored Match

@Model
final class StoredMatch {
    @Attribute(.unique) var id: UUID
    var matchName: String
    var playerOneName: String
    var playerTwoName: String
    var startTimestamp: Date
    var endTimestamp: Date?
    var isActive: Bool

    // Cached denormalized data for query performance
    var playerOneGames: Int
    var playerTwoGames: Int
    var winner: Int?
    var fullVideoURL: String?  // Full unedited video
    var highlightVideoURL: String?  // Highlight reel
    var totalDuration: TimeInterval?

    // AI-generated summary (JSON-encoded MatchAnalysisCodable)
    var aiSummaryData: Data?

    // Relationship
    @Relationship(deleteRule: .cascade) var events: [StoredMatchEvent]

    init(
        id: UUID,
        matchName: String,
        playerOneName: String,
        playerTwoName: String,
        startTimestamp: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.matchName = matchName
        self.playerOneName = playerOneName
        self.playerTwoName = playerTwoName
        self.startTimestamp = startTimestamp
        self.isActive = isActive
        self.events = []
        self.playerOneGames = 0
        self.playerTwoGames = 0
    }
}
