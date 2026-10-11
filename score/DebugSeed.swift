//
//  DebugSeed.swift
//  score
//
//  Sample data for screenshots and manual testing. DEBUG builds only, and only when the app is
//  launched with one of these arguments (see scripts/screenshot.sh and AGENTS.md, "Screenshots"):
//    -seedEmpty           remove every stored match (the empty home screen)
//    -seedSampleMatches   replace every stored match with six finished sample matches
//    -seedActiveMatch     add an in-progress match (combine with the above for a full home screen)
//    -showNewMatchSheet   open the new-match sheet as soon as the home screen appears
//  e.g. `xcrun simctl launch booted armincerf.score -seedSampleMatches -seedActiveMatch`
//

#if DEBUG
    import Foundation
    import SwiftData
    import os

    enum DebugSeed {
        static let playerOne = "Alex"
        static let playerTwo = "Lucio"

        private static let arguments = ProcessInfo.processInfo.arguments
        static var seedsEmpty: Bool { arguments.contains("-seedEmpty") }
        static var seedsSampleMatches: Bool { arguments.contains("-seedSampleMatches") }
        static var seedsActiveMatch: Bool { arguments.contains("-seedActiveMatch") }
        static var showsNewMatchSheet: Bool { arguments.contains("-showNewMatchSheet") }

        /// Finished sample matches, oldest first: game scores (player one first) and how many days ago.
        private static let sampleMatches: [(games: [(Int, Int)], daysAgo: Int)] = [
            ([(11, 7), (9, 11), (11, 9), (11, 5)], 24),  // 3-1 player one
            ([(8, 11), (11, 13), (11, 6), (7, 11)], 17),  // 1-3 player two
            ([(11, 9), (11, 4), (11, 8)], 12),  // 3-0 player one
            ([(12, 10), (9, 11)], 8),  // 1-1, ended early: no winner
            ([(11, 8), (6, 11), (11, 9), (10, 12), (11, 7)], 4),  // 3-2 player one
            ([(9, 11), (11, 7), (8, 11), (11, 13)], 1),  // 1-3 player two
        ]

        /// Wipes the stored matches and writes the requested sample data. Call before anything reads the store.
        static func applyIfRequested(eventStore: EventStore, modelContext: ModelContext) {
            guard seedsEmpty || seedsSampleMatches || seedsActiveMatch else { return }
            do {
                // Row by row: a batch delete trips over the match <-> events inverse relationship
                for match in try modelContext.fetch(FetchDescriptor<StoredMatch>()) {
                    modelContext.delete(match)  // cascades to its events
                }
                for orphan in try modelContext.fetch(FetchDescriptor<StoredMatchEvent>()) {
                    modelContext.delete(orphan)
                }
                try modelContext.save()
                if seedsSampleMatches {
                    for (index, sample) in sampleMatches.enumerated() {
                        try writeFinishedMatch(sample.games, daysAgo: sample.daysAgo, index: index, store: eventStore)
                    }
                }
                if seedsActiveMatch {
                    try writeActiveMatch(store: eventStore)
                }
                UserPreferencesService(modelContext: modelContext)
                    .updatePlayerNames(player1: playerOne, player2: playerTwo)
                Log.store.info(
                    "Debug seed applied (sample matches: \(seedsSampleMatches), active: \(seedsActiveMatch))")
            } catch {
                Log.store.error("Debug seed failed: \(error)")
            }
        }

        // MARK: - Writers

        /// A finished best-of-five match: every point, one highlight per game, game and match end events.
        private static func writeFinishedMatch(
            _ games: [(Int, Int)], daysAgo: Int, index: Int, store: EventStore
        ) throws {
            let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: eveningToday) ?? Date()
            var match = MatchWriter(store: store, start: start, seed: UInt64(index + 1))
            try match.start(initialServer: index.isMultiple(of: 2) ? 1 : 2)
            for (number, game) in games.enumerated() {
                try match.playGame(number: number, playerOne: game.0, playerTwo: game.1, highlightAt: 4)
            }
            try match.end()
        }

        /// A live match 14 minutes in: first game won 11-8, second game at 5-3.
        private static func writeActiveMatch(store: EventStore) throws {
            let start = Date().addingTimeInterval(-14 * 60)
            var match = MatchWriter(store: store, start: start, seed: 99)
            try match.start(initialServer: 1)
            try match.playGame(number: 0, playerOne: 11, playerTwo: 8, highlightAt: 6)
            try match.playPoints(game: 1, order: [1, 2, 1, 1, 2, 1, 2, 1], highlightAt: 3)
        }

        /// 18:30 today, so sample matches sit at a plausible time of day whatever the current time.
        private static var eveningToday: Date {
            Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
        }

        // MARK: - Event writer

        /// Appends one match's events in order with wall-clock offsets, mirroring what the live app records.
        private struct MatchWriter {
            let store: EventStore
            let start: Date
            let matchId = UUID()
            private var sequence = 0
            private var elapsed: TimeInterval = 0
            private var random: UInt64
            private var gamesWon = (one: 0, two: 0)

            init(store: EventStore, start: Date, seed: UInt64) {
                self.store = store
                self.start = start
                random = seed
            }

            private var now: Date { start.addingTimeInterval(elapsed) }

            private mutating func nextSequence() -> Int {
                defer { sequence += 1 }
                return sequence
            }

            /// Deterministic pseudo-random number so screenshots are reproducible.
            private mutating func roll(_ bound: Int) -> Int {
                random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((random >> 33) % UInt64(bound))
            }

            mutating func start(initialServer: Int) throws {
                let name = "\(playerOne) vs \(playerTwo) - \(start.formatted(date: .abbreviated, time: .shortened))"
                _ = try store.createMatch(
                    id: matchId, matchName: name, playerOneName: playerOne, playerTwoName: playerTwo,
                    startTimestamp: start)
                try store.append(
                    event: MatchStartedEvent(
                        matchId: matchId, timestamp: start, sequenceNumber: nextSequence(), matchName: name,
                        playerOneName: playerOne, playerTwoName: playerTwo, recordingStartTime: start,
                        initialServer: initialServer))
            }

            /// Plays a whole game to the given score (the winner takes the last point) and ends it.
            mutating func playGame(number: Int, playerOne: Int, playerTwo: Int, highlightAt: Int) throws {
                let winner = playerOne > playerTwo ? 1 : 2
                var remaining = winner == 1 ? (playerOne - 1, playerTwo) : (playerOne, playerTwo - 1)
                var order: [Int] = []
                while remaining.0 > 0 || remaining.1 > 0 {
                    let player = roll(remaining.0 + remaining.1) < remaining.0 ? 1 : 2
                    if player == 1 { remaining.0 -= 1 } else { remaining.1 -= 1 }
                    order.append(player)
                }
                order.append(winner)
                let gameStart = elapsed
                try playPoints(game: number, order: order, highlightAt: highlightAt)
                try store.append(
                    event: GameEndedEvent(
                        matchId: matchId, timestamp: now, sequenceNumber: nextSequence(), gameNumber: number,
                        playerOneScore: playerOne, playerTwoScore: playerTwo, winner: winner,
                        gameDuration: elapsed - gameStart))
                if winner == 1 { gamesWon.one += 1 } else { gamesWon.two += 1 }
                elapsed += 45
            }

            /// Scores points in the given order; a highlight is marked before point `highlightAt` (0-based).
            mutating func playPoints(game: Int, order: [Int], highlightAt: Int) throws {
                var pendingHighlight: UUID?
                for (index, player) in order.enumerated() {
                    elapsed += TimeInterval(8 + roll(18))
                    if index == highlightAt {
                        let highlight = HighlightMarkedEvent(
                            matchId: matchId, timestamp: now, sequenceNumber: nextSequence(),
                            videoTimestamp: elapsed, gameNumber: game)
                        try store.append(event: highlight)
                        pendingHighlight = highlight.id
                        elapsed += 3
                    }
                    try store.append(
                        event: PointScoredEvent(
                            matchId: matchId, timestamp: now, sequenceNumber: nextSequence(), player: player,
                            videoTimestamp: elapsed, gameNumber: game))
                    if let highlightId = pendingHighlight {
                        try store.append(
                            event: HighlightAttributedEvent(
                                matchId: matchId, timestamp: now, sequenceNumber: nextSequence(),
                                highlightEventId: highlightId, player: player))
                        pendingHighlight = nil
                    }
                }
            }

            /// Ends the match the way `WatchConnectivityManager.endMatch` persists it.
            mutating func end() throws {
                let winner =
                    gamesWon.one == gamesWon.two
                    ? MatchResult.noWinner : (gamesWon.one > gamesWon.two ? 1 : 2)
                try store.append(
                    event: MatchEndedEvent(
                        matchId: matchId, timestamp: now, sequenceNumber: nextSequence(),
                        playerOneGames: gamesWon.one, playerTwoGames: gamesWon.two, winner: winner,
                        matchDuration: elapsed, highlightVideoURL: nil))
                guard let stored = try store.getMatch(id: matchId) else { return }
                stored.isActive = false
                stored.endTimestamp = now
                stored.playerOneGames = gamesWon.one
                stored.playerTwoGames = gamesWon.two
                stored.winner = winner
                stored.totalDuration = elapsed
                try store.updateMatch(stored)
            }
        }
    }
#endif
