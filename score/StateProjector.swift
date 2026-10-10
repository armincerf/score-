//
//  StateProjector.swift
//  score
//
//  Rebuilds ScoreState from events (event replay)
//

import Foundation
import os

class StateProjector {
    /// Scratch state carried through one replay of a match's events.
    private struct Replay {
        var state = ScoreState()
        var currentGamePoints: [PointEvent] = []
        var pointTimestamps: [Double] = []  // Point video timestamps, for highlight start times
        var pendingHighlights: [UUID: HighlightMarkedEvent] = [:]
        var highlightClips: [HighlightClip] = []
    }

    // MARK: - Full State Projection

    /// Rebuild complete ScoreState from all events in a match
    func project(events: [StoredMatchEvent], matchMetadata: StoredMatch) throws -> ScoreState {
        var replay = Replay()
        for storedEvent in events where !storedEvent.isUndone {
            do {
                try apply(storedEvent, to: &replay)
            } catch {
                // One corrupt event must not make the whole match unloadable
                Log.store.error(
                    "Skipping undecodable \(storedEvent.eventType) event #\(storedEvent.sequenceNumber): \(error)")
            }
        }
        replay.state.currentGamePoints = replay.currentGamePoints
        replay.state.highlightClips = replay.highlightClips
        return replay.state
    }

    private func apply(_ storedEvent: StoredMatchEvent, to replay: inout Replay) throws {
        let decoder = JSONDecoder()
        switch EventType(rawValue: storedEvent.eventType) {
        case .matchStarted:
            apply(try decoder.decode(MatchStartedEvent.self, from: storedEvent.eventData), to: &replay)
        case .pointScored:
            apply(try decoder.decode(PointScoredEvent.self, from: storedEvent.eventData), to: &replay)
        case .highlightMarked:
            apply(try decoder.decode(HighlightMarkedEvent.self, from: storedEvent.eventData), to: &replay)
        case .highlightAttributed:
            apply(try decoder.decode(HighlightAttributedEvent.self, from: storedEvent.eventData), to: &replay)
        case .gameEnded:
            apply(try decoder.decode(GameEndedEvent.self, from: storedEvent.eventData), to: &replay)
        case .matchEnded:
            replay.state.isRecording = false
        case .recordingSegmentStarted:
            let event = try decoder.decode(RecordingSegmentStartedEvent.self, from: storedEvent.eventData)
            replay.state.recordingSegments.append(
                RecordingSegment(fileReference: event.fileReference, startOffset: event.startOffset))
        case .eventUndone, .none:
            break  // Undo markers and unknown types carry no state
        }
    }

    private func apply(_ event: MatchStartedEvent, to replay: inout Replay) {
        replay.state.currentMatchName = event.matchName
        replay.state.playerOneName = event.playerOneName
        replay.state.playerTwoName = event.playerTwoName
        replay.state.isRecording = true
        replay.state.recordingStartTime = event.recordingStartTime
        // Use the persisted initial server from the event (ensures replay consistency)
        replay.state.servingPlayer = event.initialServer
        replay.state.currentGameFirstServer = event.initialServer
    }

    private func apply(_ event: PointScoredEvent, to replay: inout Replay) {
        // Check if point was won on serve (before updating score)
        let wasServing = ServingLogic.wasPointScoredOnServe(
            scoringPlayer: event.player,
            servingPlayer: replay.state.servingPlayer
        )

        if event.player == 1 {
            replay.state.playerOneScore += 1
        } else {
            replay.state.playerTwoScore += 1
        }

        if let videoTimestamp = event.videoTimestamp {
            replay.pointTimestamps.append(videoTimestamp)
        }

        replay.currentGamePoints.append(
            PointEvent(
                player: event.player,
                timestamp: event.timestamp,
                isHighlight: false,
                videoTimestamp: event.videoTimestamp,
                wasServing: wasServing
            )
        )

        replay.state.servingPlayer = ServingLogic.calculateCurrentServer(
            firstServer: replay.state.currentGameFirstServer ?? 1,
            playerOneScore: replay.state.playerOneScore,
            playerTwoScore: replay.state.playerTwoScore
        )
    }

    private func apply(_ event: HighlightMarkedEvent, to replay: inout Replay) {
        if event.player == nil, let pending = replay.state.pendingHighlight {
            // A second mark before the next point belongs to the same rally: extend the pending clip
            replay.state.pendingHighlight = HighlightClip(
                id: pending.id,
                startTimestamp: pending.startTimestamp,
                endTimestamp: max(pending.endTimestamp, event.videoTimestamp),
                player: nil,
                gameNumber: pending.gameNumber
            )
            return
        }
        // The clip starts at the last scored point before the highlight was marked
        let clip = HighlightClip(
            id: event.id,
            startTimestamp: replay.pointTimestamps.last ?? 0,
            endTimestamp: event.videoTimestamp,
            player: event.player,
            gameNumber: event.gameNumber
        )
        if event.player != nil {
            replay.highlightClips.append(clip)  // Already attributed
        } else {
            replay.pendingHighlights[event.id] = event
            replay.state.pendingHighlight = clip
        }
    }

    private func apply(_ event: HighlightAttributedEvent, to replay: inout Replay) {
        guard let pendingEvent = replay.pendingHighlights[event.highlightEventId] else { return }
        // A second mark before the point extended the pending clip; keep that end, not the first mark's
        let pendingClip = replay.state.pendingHighlight?.id == pendingEvent.id ? replay.state.pendingHighlight : nil
        let endTimestamp = max(pendingClip?.endTimestamp ?? 0, pendingEvent.videoTimestamp)
        let lastPointTimestamp = replay.pointTimestamps.last(where: { $0 < pendingEvent.videoTimestamp }) ?? 0
        replay.highlightClips.append(
            HighlightClip(
                id: pendingEvent.id,
                startTimestamp: lastPointTimestamp,
                endTimestamp: endTimestamp,
                player: event.player,
                gameNumber: pendingEvent.gameNumber
            )
        )
        replay.pendingHighlights.removeValue(forKey: event.highlightEventId)
        replay.state.pendingHighlight = nil
    }

    private func apply(_ event: GameEndedEvent, to replay: inout Replay) {
        replay.state.currentMatchGames.append(
            GameResult(
                playerOneScore: event.playerOneScore,
                playerTwoScore: event.playerTwoScore,
                winner: event.winner,
                timestamp: event.timestamp,
                points: replay.currentGamePoints,
                duration: event.gameDuration,
                firstServer: replay.state.currentGameFirstServer ?? 1
            )
        )

        if event.winner == 1 {
            replay.state.playerOneGames += 1
        } else {
            replay.state.playerTwoGames += 1
        }

        // First server alternates between games
        if let firstServerThisGame = replay.state.currentGameFirstServer {
            let nextServer = firstServerThisGame == 1 ? 2 : 1
            replay.state.currentGameFirstServer = nextServer
            replay.state.servingPlayer = nextServer
        }

        replay.state.playerOneScore = 0
        replay.state.playerTwoScore = 0
        replay.currentGamePoints = []
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
        guard
            let lastPointEvent =
                currentGameEvents
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
