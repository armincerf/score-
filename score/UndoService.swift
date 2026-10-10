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

    // MARK: - Undo Operations

    /// Undoes whichever of the last point or the last highlight mark came latest in the current game.
    /// Returns the id of the undo event, or nil if there is nothing to undo.
    func undoLastAction(in matchId: UUID) throws -> UUID? {
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)
        guard let last = currentGameEvents.last(where: { Self.undoableTypes.contains($0.eventType) && !$0.isUndone })
        else {
            return nil
        }
        if last.eventType == EventType.pointScored.rawValue {
            return try undoLastPoint(in: matchId)
        }
        return try undoLastHighlight(in: matchId)
    }

    /// Undo the last point in the current game. A highlight that this point attributed goes back to
    /// pending (its attribution event is undone too).
    /// Returns the ID of the undo event if successful, nil if nothing to undo
    func undoLastPoint(in matchId: UUID) throws -> UUID? {
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

    /// Get count of actions that can be undone
    func getUndoableActionCount(in matchId: UUID) throws -> Int {
        try eventStore.getCurrentGameEvents(matchId: matchId)
            .filter { Self.undoableTypes.contains($0.eventType) && !$0.isUndone }
            .count
    }

    /// Get description of what would be undone
    func getUndoDescription(in matchId: UUID) throws -> String? {
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        guard
            let lastAction = currentGameEvents.last(where: { Self.undoableTypes.contains($0.eventType) && !$0.isUndone }
            )
        else {
            return nil
        }

        switch lastAction.eventType {
        case EventType.pointScored.rawValue:
            let event = try JSONDecoder().decode(PointScoredEvent.self, from: lastAction.eventData)
            return "Point for Player \(event.player)"
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
