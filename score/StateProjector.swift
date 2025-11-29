//
//  StateProjector.swift
//  score
//
//  Rebuilds ScoreState from events (event replay)
//

import Foundation

class StateProjector {
    // MARK: - Full State Projection

    /// Rebuild complete ScoreState from all events in a match
    func project(events: [StoredMatchEvent], matchMetadata: StoredMatch) throws -> ScoreState {
        var state = ScoreState()
        var currentGameNumber = 0
        var currentGamePoints: [PointEvent] = []
        var pointTimestamps: [Double] = []  // Track point timestamps for highlight start times

        // Track pending highlights and their attributions
        var pendingHighlights: [UUID: HighlightMarkedEvent] = [:]
        var highlightClips: [HighlightClip] = []

        // Replay events in sequence order
        for storedEvent in events where !storedEvent.isUndone {
            switch storedEvent.eventType {
            case EventType.matchStarted.rawValue:
                let event = try JSONDecoder().decode(MatchStartedEvent.self, from: storedEvent.eventData)
                state.currentMatchName = event.matchName
                state.playerOneName = event.playerOneName
                state.playerTwoName = event.playerTwoName
                state.isRecording = true
                state.recordingStartTime = event.recordingStartTime

                // Use the persisted initial server from the event (ensures replay consistency)
                state.servingPlayer = event.initialServer
                state.currentGameFirstServer = event.initialServer

            case EventType.pointScored.rawValue:
                let event = try JSONDecoder().decode(PointScoredEvent.self, from: storedEvent.eventData)

                // Update score
                if event.player == 1 {
                    state.playerOneScore += 1
                } else {
                    state.playerTwoScore += 1
                }

                // Track point timestamp
                if let videoTimestamp = event.videoTimestamp {
                    pointTimestamps.append(videoTimestamp)
                }

                // Check if point was won on serve (before updating score)
                let wasServing = ServingLogic.wasPointScoredOnServe(
                    scoringPlayer: event.player,
                    servingPlayer: state.servingPlayer
                )

                // Create point event
                let pointEvent = PointEvent(
                    player: event.player,
                    timestamp: event.timestamp,
                    isHighlight: false,
                    videoTimestamp: event.videoTimestamp,
                    wasServing: wasServing
                )

                currentGamePoints.append(pointEvent)

                // Recalculate current server based on new score
                state.servingPlayer = ServingLogic.calculateCurrentServer(
                    firstServer: state.currentGameFirstServer ?? 1,
                    playerOneScore: state.playerOneScore,
                    playerTwoScore: state.playerTwoScore
                )

            case EventType.highlightMarked.rawValue:
                let event = try JSONDecoder().decode(HighlightMarkedEvent.self, from: storedEvent.eventData)

                // Calculate start timestamp (last scored point before this highlight)
                let lastPointTimestamp = pointTimestamps.last ?? 0

                // Create pending highlight clip
                let clip = HighlightClip(
                    id: event.id,
                    startTimestamp: lastPointTimestamp,
                    endTimestamp: event.videoTimestamp,
                    player: event.player,
                    gameNumber: event.gameNumber
                )

                if event.player != nil {
                    // Already attributed (legacy or immediate attribution)
                    highlightClips.append(clip)
                } else {
                    // Store as pending
                    pendingHighlights[event.id] = event
                    state.pendingHighlight = clip
                }

            case EventType.highlightAttributed.rawValue:
                let event = try JSONDecoder().decode(HighlightAttributedEvent.self, from: storedEvent.eventData)

                // Find the pending highlight and attribute it
                if let pendingEvent = pendingHighlights[event.highlightEventId] {
                    let lastPointTimestamp = pointTimestamps.filter { $0 < pendingEvent.videoTimestamp }.last ?? 0

                    let attributedClip = HighlightClip(
                        id: pendingEvent.id,
                        startTimestamp: lastPointTimestamp,
                        endTimestamp: pendingEvent.videoTimestamp,
                        player: event.player,
                        gameNumber: pendingEvent.gameNumber
                    )
                    highlightClips.append(attributedClip)
                    pendingHighlights.removeValue(forKey: event.highlightEventId)
                    state.pendingHighlight = nil
                }

            case EventType.gameEnded.rawValue:
                let event = try JSONDecoder().decode(GameEndedEvent.self, from: storedEvent.eventData)

                // Create game result
                let game = GameResult(
                    playerOneScore: event.playerOneScore,
                    playerTwoScore: event.playerTwoScore,
                    winner: event.winner,
                    timestamp: event.timestamp,
                    points: currentGamePoints,
                    duration: event.gameDuration,
                    firstServer: state.currentGameFirstServer ?? 1
                )
                state.currentMatchGames.append(game)

                // Update games won
                if event.winner == 1 {
                    state.playerOneGames += 1
                } else {
                    state.playerTwoGames += 1
                }

                // Determine first server for next game (alternate from current game)
                if let firstServerThisGame = state.currentGameFirstServer {
                    state.currentGameFirstServer = (firstServerThisGame == 1) ? 2 : 1
                    state.servingPlayer = state.currentGameFirstServer!
                }

                // Reset for next game
                state.playerOneScore = 0
                state.playerTwoScore = 0
                currentGamePoints = []
                currentGameNumber += 1

            case EventType.matchEnded.rawValue:
                _ = try JSONDecoder().decode(MatchEndedEvent.self, from: storedEvent.eventData)
                state.isRecording = false

            default:
                // EventUndone or unknown types - skip
                break
            }
        }

        // Set current game points and highlight clips
        state.currentGamePoints = currentGamePoints
        state.highlightClips = highlightClips

        return state
    }

    // MARK: - Current Game Projection (Optimized)

    /// Fast projection for current game only (since last GameEndedEvent)
    /// Used for real-time UI updates during active game
    func projectCurrentGame(events: [StoredMatchEvent]) throws -> CurrentGameState {
        var playerOneScore = 0
        var playerTwoScore = 0
        var currentGamePoints: [PointEvent] = []

        // Find last GameEndedEvent
        let lastGameEndedIndex = events.lastIndex { $0.eventType == EventType.gameEnded.rawValue }
        let startIndex = lastGameEndedIndex.map { events.index(after: $0) } ?? events.startIndex

        // Replay events since last game (or from start)
        for storedEvent in events[startIndex...] where !storedEvent.isUndone {
            switch storedEvent.eventType {
            case EventType.pointScored.rawValue:
                let event = try JSONDecoder().decode(PointScoredEvent.self, from: storedEvent.eventData)

                if event.player == 1 {
                    playerOneScore += 1
                } else {
                    playerTwoScore += 1
                }

                let pointEvent = PointEvent(
                    player: event.player,
                    timestamp: event.timestamp,
                    isHighlight: false,
                    videoTimestamp: event.videoTimestamp
                )

                currentGamePoints.append(pointEvent)

            default:
                break
            }
        }

        return CurrentGameState(
            playerOneScore: playerOneScore,
            playerTwoScore: playerTwoScore,
            currentGamePoints: currentGamePoints
        )
    }

    // MARK: - Point Tracking

    /// Get the most recent PointScoredEvent in current game
    func getLastPointEvent(in events: [StoredMatchEvent]) throws -> PointScoredEvent? {
        // Find events since last GameEndedEvent
        let lastGameEndedIndex = events.lastIndex { $0.eventType == EventType.gameEnded.rawValue }
        let startIndex = lastGameEndedIndex.map { events.index(after: $0) } ?? events.startIndex

        // Find last PointScored that's not undone
        let currentGameEvents = events[startIndex...]
        guard let lastPointEvent = currentGameEvents
            .reversed()
            .first(where: { $0.eventType == EventType.pointScored.rawValue && !$0.isUndone })
        else {
            return nil
        }

        return try JSONDecoder().decode(PointScoredEvent.self, from: lastPointEvent.eventData)
    }
}

// MARK: - Supporting Types

struct CurrentGameState {
    let playerOneScore: Int
    let playerTwoScore: Int
    let currentGamePoints: [PointEvent]
}
