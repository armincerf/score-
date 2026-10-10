//
//  UndoService.swift
//  score
//
//  Undo for the current game: soft-deletes the latest point or highlight mark by marking its
//  event `isUndone` and appending an `eventUndone` event, so projection and relaunch agree.
//

import Foundation
import os

class UndoService {
    private let eventStore: EventStore
    private let stateProjector: StateProjector

    init(eventStore: EventStore, stateProjector: StateProjector) {
        self.eventStore = eventStore
        self.stateProjector = stateProjector
    }

    private static let undoableTypes: Set<String> = [
        EventType.pointScored.rawValue, EventType.highlightMarked.rawValue,
    ]
    /// Events that can sit between a point and the game end it caused without being user actions.
    private static let bookkeepingTypes: Set<String> = [
        EventType.highlightAttributed.rawValue, EventType.eventUndone.rawValue,
        EventType.recordingSegmentStarted.rawValue,
    ]

    private struct Target {
        let event: StoredMatchEvent
        /// The game end that this point produced and that must be undone with it (reopening the game).
        let reopensGameEnd: StoredMatchEvent?
    }

    /// The latest undoable action. When the current game has none, a game end that directly followed a
    /// point counts as part of that point, so a mistaken game-winning tap can be corrected.
    private func lastUndoable(in matchId: UUID) throws -> Target? {
        let current = try eventStore.getCurrentGameEvents(matchId: matchId)
        if let last = current.last(where: { Self.undoableTypes.contains($0.eventType) && !$0.isUndone }) {
            return Target(event: last, reopensGameEnd: nil)
        }
        // Only user actions matter here; undo markers, attributions and segment starts are bookkeeping
        let actions = try eventStore.getEvents(matchId: matchId).filter {
            !Self.bookkeepingTypes.contains($0.eventType)
        }
        guard let gameEnd = actions.last, gameEnd.eventType == EventType.gameEnded.rawValue,
            let point = actions.dropLast().last, point.eventType == EventType.pointScored.rawValue
        else {
            return nil
        }
        return Target(event: point, reopensGameEnd: gameEnd)
    }

    private func reopenGameIfEndedByLastPoint(in matchId: UUID) throws {
        guard let target = try lastUndoable(in: matchId), let gameEnd = target.reopensGameEnd else { return }
        try undo(eventId: gameEnd.id, matchId: matchId, reason: "user_undo_game_end")
        Log.store.debug("Reopened game ended by event #\(gameEnd.sequenceNumber)")
    }

    // MARK: - Undo Operations

    /// Undoes whichever of the last point or the last highlight mark came latest in the current game.
    /// Returns the id of the undo event, or nil if there is nothing to undo.
    func undoLastAction(in matchId: UUID) throws -> UUID? {
        guard let target = try lastUndoable(in: matchId) else { return nil }
        if target.event.eventType == EventType.pointScored.rawValue {
            return try undoLastPoint(in: matchId)
        }
        return try undoLastHighlight(in: matchId)
    }

    /// Undo the last point in the current game. A highlight that this point attributed goes back to
    /// pending (its attribution event is undone too).
    /// Returns the ID of the undo event if successful, nil if nothing to undo
    func undoLastPoint(in matchId: UUID) throws -> UUID? {
        try reopenGameIfEndedByLastPoint(in: matchId)
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        guard
            let lastPointEvent = currentGameEvents.last(where: {
                $0.eventType == EventType.pointScored.rawValue && !$0.isUndone
            })
        else {
            Log.store.debug("No points to undo in current game")
            return nil
        }

        // Attributions made by this point (they follow it, before any later point) are undone with it
        let dependentAttributions = currentGameEvents.filter {
            $0.eventType == EventType.highlightAttributed.rawValue && !$0.isUndone
                && $0.sequenceNumber > lastPointEvent.sequenceNumber
        }
        for attribution in dependentAttributions {
            try undo(eventId: attribution.id, matchId: matchId, reason: "user_undo_point")
        }

        let undoEventId = try undo(eventId: lastPointEvent.id, matchId: matchId, reason: "user_undo")

        let pointEvent = try JSONDecoder().decode(PointScoredEvent.self, from: lastPointEvent.eventData)
        Log.store.debug("Undid point for player \(pointEvent.player)")
        return undoEventId
    }

    /// Undo the last highlight mark in the current game
    /// Returns the ID of the undo event if successful, nil if nothing to undo
    func undoLastHighlight(in matchId: UUID) throws -> UUID? {
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        guard
            let lastHighlightEvent = currentGameEvents.last(where: {
                $0.eventType == EventType.highlightMarked.rawValue && !$0.isUndone
            })
        else {
            Log.store.debug("No highlights to undo in current game")
            return nil
        }

        let undoEventId = try undo(eventId: lastHighlightEvent.id, matchId: matchId, reason: "user_undo")
        Log.store.debug("Undid highlight mark")
        return undoEventId
    }

    @discardableResult
    private func undo(eventId: UUID, matchId: UUID, reason: String) throws -> UUID {
        let undoEvent = EventUndoneEvent(
            matchId: matchId,
            sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
            undoneEventId: eventId,
            reason: reason
        )
        try eventStore.markEventAsUndone(eventId: eventId)
        try eventStore.append(event: undoEvent)
        return undoEvent.id
    }

    // MARK: - Undo Availability

    /// Check if there are any actions that can be undone in the current game
    func canUndo(in matchId: UUID) throws -> Bool {
        try getUndoableActionCount(in: matchId) > 0
    }

    /// Get count of actions that can be undone (a reopenable game end counts as one with its point)
    func getUndoableActionCount(in matchId: UUID) throws -> Int {
        let live = try eventStore.getCurrentGameEvents(matchId: matchId)
            .filter { Self.undoableTypes.contains($0.eventType) && !$0.isUndone }
            .count
        if live > 0 { return live }
        return try lastUndoable(in: matchId) == nil ? 0 : 1
    }

    /// Get description of what would be undone
    func getUndoDescription(in matchId: UUID) throws -> String? {
        guard let target = try lastUndoable(in: matchId) else { return nil }
        switch target.event.eventType {
        case EventType.pointScored.rawValue:
            let event = try JSONDecoder().decode(PointScoredEvent.self, from: target.event.eventData)
            return target.reopensGameEnd == nil
                ? "Point for Player \(event.player)" : "Point for Player \(event.player) (reopens the game)"
        case EventType.highlightMarked.rawValue:
            return "Highlight Mark"
        default:
            return nil
        }
    }
}

// MARK: - Errors

enum UndoError: Error {
    case nothingToUndo
    case cannotUndoAcrossGames
}
