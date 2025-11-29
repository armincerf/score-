//
//  UndoService.swift
//  score
//
//  Service for undoing actions in the current game
//

import Foundation

class UndoService {
    private let eventStore: EventStore
    private let stateProjector: StateProjector

    // Maximum number of points that can be undone
    private let maxUndoDepth = 10

    init(eventStore: EventStore, stateProjector: StateProjector) {
        self.eventStore = eventStore
        self.stateProjector = stateProjector
    }

    // MARK: - Undo Operations

    /// Undo the last point in the current game
    /// Returns the ID of the undo event if successful, nil if nothing to undo
    func undoLastPoint(in matchId: UUID) throws -> UUID? {
        // Get current game events (since last GameEndedEvent)
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        // Find last non-undone PointScored event
        guard let lastPointEvent = currentGameEvents
            .reversed()
            .first(where: { $0.eventType == EventType.pointScored.rawValue && !$0.isUndone })
        else {
            print("[UndoService] No points to undo in current game")
            return nil
        }

        // Verify we're within undo depth limit
        let pointsSinceLastGame = currentGameEvents.filter {
            $0.eventType == EventType.pointScored.rawValue && !$0.isUndone
        }

        if pointsSinceLastGame.count > maxUndoDepth {
            let indexOfLastPoint = pointsSinceLastGame.firstIndex(where: { $0.id == lastPointEvent.id })
            if let index = indexOfLastPoint, index < pointsSinceLastGame.count - maxUndoDepth {
                print("[UndoService] Cannot undo - exceeds max undo depth of \(maxUndoDepth)")
                throw UndoError.exceedsMaxDepth
            }
        }

        // Create undo event
        let undoEvent = EventUndoneEvent(
            id: UUID(),
            matchId: matchId,
            timestamp: Date(),
            sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
            undoneEventId: lastPointEvent.id,
            reason: "user_undo"
        )

        // Mark original event as undone
        try eventStore.markEventAsUndone(eventId: lastPointEvent.id)

        // Store undo event
        try eventStore.append(event: undoEvent)

        // Decode the point event to get player info for logging
        let pointEvent = try JSONDecoder().decode(PointScoredEvent.self, from: lastPointEvent.eventData)
        print("[UndoService] Undid point for player \(pointEvent.player)")

        return undoEvent.id
    }

    /// Undo the last highlight mark in the current game
    /// Returns the ID of the undo event if successful, nil if nothing to undo
    func undoLastHighlight(in matchId: UUID) throws -> UUID? {
        // Get current game events
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        // Find last non-undone HighlightMarked event
        guard let lastHighlightEvent = currentGameEvents
            .reversed()
            .first(where: { $0.eventType == EventType.highlightMarked.rawValue && !$0.isUndone })
        else {
            print("[UndoService] No highlights to undo in current game")
            return nil
        }

        // Create undo event
        let undoEvent = EventUndoneEvent(
            id: UUID(),
            matchId: matchId,
            timestamp: Date(),
            sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
            undoneEventId: lastHighlightEvent.id,
            reason: "user_undo"
        )

        // Mark original event as undone
        try eventStore.markEventAsUndone(eventId: lastHighlightEvent.id)

        // Store undo event
        try eventStore.append(event: undoEvent)

        print("[UndoService] Undid highlight mark")

        return undoEvent.id
    }

    // MARK: - Undo Availability

    /// Check if there are any actions that can be undone in the current game
    func canUndo(in matchId: UUID) throws -> Bool {
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        // Check if there are any non-undone PointScored events
        return currentGameEvents.contains(where: {
            ($0.eventType == EventType.pointScored.rawValue ||
             $0.eventType == EventType.highlightMarked.rawValue) &&
            !$0.isUndone
        })
    }

    /// Get count of actions that can be undone
    func getUndoableActionCount(in matchId: UUID) throws -> Int {
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        return currentGameEvents.filter {
            ($0.eventType == EventType.pointScored.rawValue ||
             $0.eventType == EventType.highlightMarked.rawValue) &&
            !$0.isUndone
        }.count
    }

    /// Get description of what would be undone
    func getUndoDescription(in matchId: UUID) throws -> String? {
        let currentGameEvents = try eventStore.getCurrentGameEvents(matchId: matchId)

        // Find last non-undone action
        guard let lastAction = currentGameEvents
            .reversed()
            .first(where: {
                ($0.eventType == EventType.pointScored.rawValue ||
                 $0.eventType == EventType.highlightMarked.rawValue) &&
                !$0.isUndone
            })
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
    case exceedsMaxDepth
    case nothingToUndo
    case cannotUndoAcrossGames
}
