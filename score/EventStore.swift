//
//  EventStore.swift
//  score
//
//  Service for persisting and querying events
//

import Foundation
import SwiftData

class EventStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Append Events

    func append<T: MatchEvent>(event: T) throws {
        let eventData = try JSONEncoder().encode(event)
        let storedEvent = StoredMatchEvent(
            id: event.id,
            matchId: event.matchId,
            timestamp: event.timestamp,
            sequenceNumber: event.sequenceNumber,
            eventType: event.eventType.rawValue,
            eventData: eventData,
            isUndone: false
        )

        modelContext.insert(storedEvent)
        try modelContext.save()

        print("[EventStore] Appended \(event.eventType) event #\(event.sequenceNumber) for match \(event.matchId)")
    }

    // MARK: - Query Events

    func getEvents(matchId: UUID, includeUndone: Bool = false) throws -> [StoredMatchEvent] {
        let predicate = includeUndone
            ? #Predicate<StoredMatchEvent> { $0.matchId == matchId }
            : #Predicate<StoredMatchEvent> { $0.matchId == matchId && !$0.isUndone }

        let descriptor = FetchDescriptor<StoredMatchEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.sequenceNumber)]
        )

        return try modelContext.fetch(descriptor)
    }

    func getEvent(id: UUID) throws -> StoredMatchEvent? {
        let predicate = #Predicate<StoredMatchEvent> { $0.id == id }
        let descriptor = FetchDescriptor<StoredMatchEvent>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    // MARK: - Sequence Numbers

    func getNextSequenceNumber(matchId: UUID) throws -> Int {
        let events = try getEvents(matchId: matchId, includeUndone: true)
        return (events.map { $0.sequenceNumber }.max() ?? -1) + 1
    }

    // MARK: - Match Operations

    func createMatch(
        id: UUID,
        matchName: String,
        playerOneName: String,
        playerTwoName: String,
        startTimestamp: Date
    ) throws -> StoredMatch {
        let match = StoredMatch(
            id: id,
            matchName: matchName,
            playerOneName: playerOneName,
            playerTwoName: playerTwoName,
            startTimestamp: startTimestamp,
            isActive: true
        )

        modelContext.insert(match)
        try modelContext.save()

        print("[EventStore] Created match: \(matchName)")
        return match
    }

    func getMatch(id: UUID) throws -> StoredMatch? {
        let predicate = #Predicate<StoredMatch> { $0.id == id }
        let descriptor = FetchDescriptor<StoredMatch>(predicate: predicate)
        return try modelContext.fetch(descriptor).first
    }

    func getActiveMatch() throws -> StoredMatch? {
        let predicate = #Predicate<StoredMatch> { $0.isActive }
        let descriptor = FetchDescriptor<StoredMatch>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startTimestamp, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).first
    }

    func getAllMatches() throws -> [StoredMatch] {
        let descriptor = FetchDescriptor<StoredMatch>(
            sortBy: [SortDescriptor(\.startTimestamp, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func updateMatch(_ match: StoredMatch) throws {
        try modelContext.save()
    }

    func deleteMatch(id: UUID) throws {
        guard let match = try getMatch(id: id) else {
            throw EventStoreError.matchNotFound
        }

        // Delete all events for this match
        let events = try getEvents(matchId: id, includeUndone: true)
        for event in events {
            modelContext.delete(event)
        }

        // Delete the match itself
        modelContext.delete(match)
        try modelContext.save()

        print("[EventStore] Deleted match \(id) and \(events.count) events")
    }

    // MARK: - Undo Support

    func markEventAsUndone(eventId: UUID) throws {
        guard let event = try getEvent(id: eventId) else {
            throw EventStoreError.eventNotFound
        }

        event.isUndone = true
        try modelContext.save()

        print("[EventStore] Marked event #\(event.sequenceNumber) as undone")
    }

    // MARK: - Current Game Events

    /// Get events for the current game (since last GameEndedEvent)
    func getCurrentGameEvents(matchId: UUID) throws -> [StoredMatchEvent] {
        let allEvents = try getEvents(matchId: matchId, includeUndone: false)

        // Find the last GameEndedEvent
        guard let lastGameEndedIndex = allEvents.lastIndex(where: {
            $0.eventType == EventType.gameEnded.rawValue
        }) else {
            // No game ended yet, return all events
            return allEvents
        }

        // Return events after the last GameEndedEvent
        let startIndex = allEvents.index(after: lastGameEndedIndex)
        return Array(allEvents[startIndex...])
    }
}

// MARK: - Errors

enum EventStoreError: Error {
    case eventNotFound
    case matchNotFound
    case invalidEventData
}
