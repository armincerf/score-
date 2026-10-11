//
//  DebugSeed.swift
//  score
//
//  Sample data for screenshots and manual testing. DEBUG builds only, and only when the app is
//  launched with one of these arguments (see scripts/screenshot.sh and AGENTS.md, "Screenshots"):
//    -seedEmpty           remove every stored match (the empty home screen)
//    -seedSampleMatches   replace every stored match with six finished sample matches
//    -seedLeague          replace every stored match with twelve finished matches between four players (Alex,
//                         Lucio, Mia, Sam) over the last three months, Alex vs Lucio in both orders, one without a
//                         winner: the Stats page with a leaderboard and a choice of players
//    -seedActiveMatch     add an in-progress match (combine with the above for a full home screen)
//    -showNewMatchSheet   open the new-match sheet as soon as the home screen appears
//    -seedReel            with -seedSampleMatches: give the newest match a 20 s mock recording and export its
//                         highlight reel, scoreboard included, through the real export (a few seconds)
//    -seedReelPortrait    like -seedReel, but the mock recording is portrait (720x1280), for the player's portrait shape
//    -openLatestMatch     open the newest match's detail screen (once the -seedReel export, if any, is done)
//    -openStats           open the Stats page as the home screen appears
//    -landscapeAfter N    turn the interface to landscape N seconds after the home screen first appears (the
//                         simulator cannot be rotated from the shell); e.g. 25 leaves time to start a video first
//  e.g. `xcrun simctl launch booted armincerf.score -seedSampleMatches -seedActiveMatch`
//

#if DEBUG
    import Foundation
    import SwiftData
    import UIKit
    import os

    enum DebugSeed {
        static let playerOne = "Alex"
        static let playerTwo = "Lucio"

        private static let arguments = ProcessInfo.processInfo.arguments
        static var seedsEmpty: Bool { arguments.contains("-seedEmpty") }
        static var seedsSampleMatches: Bool { arguments.contains("-seedSampleMatches") }
        static var seedsActiveMatch: Bool { arguments.contains("-seedActiveMatch") }
        static var seedsLeague: Bool { arguments.contains("-seedLeague") }
        static var opensStats: Bool { arguments.contains("-openStats") }
        static var showsNewMatchSheet: Bool { arguments.contains("-showNewMatchSheet") }
        static var seedsReel: Bool { arguments.contains("-seedReel") || seedsPortraitReel }
        static var seedsPortraitReel: Bool { arguments.contains("-seedReelPortrait") }
        static var opensLatestMatch: Bool { arguments.contains("-openLatestMatch") }
        /// Seconds after `-landscapeAfter`, if given.
        static var landscapeDelay: Double? {
            guard let index = arguments.firstIndex(of: "-landscapeAfter"), index + 1 < arguments.count else {
                return nil
            }
            return Double(arguments[index + 1])
        }
        private static var turnedToLandscape = false

        /// The `-seedReel` export, started at launch; the `-openLatestMatch` hook waits for it.
        private(set) static var reelExport: Task<Void, Never>?
        private static var openedLatestMatch = false
        private static var openedStats = false

        /// True once per launch with `-openLatestMatch` (the home screen appears again on the way back).
        static func takeOpenLatestMatchRequest() -> Bool {
            guard opensLatestMatch, !openedLatestMatch else { return false }
            openedLatestMatch = true
            return true
        }

        /// True once per launch with `-openStats` (the home screen appears again on the way back).
        static func takeOpenStatsRequest() -> Bool {
            guard opensStats, !openedStats else { return false }
            openedStats = true
            return true
        }

        /// Turns the interface to landscape once per launch, `-landscapeAfter` seconds after the first call.
        static func turnToLandscapeIfRequested() async {
            guard let delay = landscapeDelay, !turnedToLandscape else { return }
            turnedToLandscape = true
            try? await Task.sleep(for: .seconds(delay))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                Log.ui.error("Debug seed: landscape refused: \(error)")
            }
            Log.ui.info("Debug seed: turned to landscape")
        }

        /// Finished sample matches, oldest first: game scores (player one first) and how many days ago.
        private static let sampleMatches: [(games: [(Int, Int)], daysAgo: Int)] = [
            ([(11, 7), (9, 11), (11, 9), (11, 5)], 24),  // 3-1 player one
            ([(8, 11), (11, 13), (11, 6), (7, 11)], 17),  // 1-3 player two
            ([(11, 9), (11, 4), (11, 8)], 12),  // 3-0 player one
            ([(12, 10), (9, 11)], 8),  // 1-1, ended early: no winner
            ([(11, 8), (6, 11), (11, 9), (10, 12), (11, 7)], 4),  // 3-2 player one
            ([(9, 11), (11, 7), (8, 11), (11, 13)], 1),  // 1-3 player two
        ]

        /// The `-seedLeague` matches, oldest first: players (player one first), game scores and how many days ago.
        /// Mia 3-2, Lucio 4-2-1, Alex 3-4-1, Sam 1-3; Alex vs Lucio 1-3 with one match without a winner.
        private static let leagueMatches: [(players: (String, String), games: [(Int, Int)], daysAgo: Int)] = [
            (("Alex", "Lucio"), [(11, 7), (11, 9), (8, 11), (11, 6)], 84),
            (("Mia", "Sam"), [(11, 4), (11, 8), (11, 9)], 78),
            (("Lucio", "Alex"), [(11, 9), (7, 11), (11, 8), (11, 13), (11, 6)], 71),
            (("Sam", "Alex"), [(9, 11), (11, 7), (6, 11), (8, 11)], 63),
            (("Mia", "Lucio"), [(11, 9), (9, 11), (11, 7), (11, 5)], 55),
            (("Alex", "Mia"), [(8, 11), (11, 9), (9, 11), (11, 13)], 47),
            (("Lucio", "Sam"), [(11, 6), (11, 8), (12, 10)], 39),
            (("Alex", "Lucio"), [(11, 8), (9, 11)], 31),  // ended early: no winner
            (("Sam", "Mia"), [(11, 9), (8, 11), (11, 7), (11, 9)], 22),
            (("Lucio", "Alex"), [(11, 6), (9, 11), (11, 9), (11, 7)], 14),
            (("Mia", "Alex"), [(9, 11), (11, 8), (6, 11), (9, 11)], 7),
            (("Alex", "Lucio"), [(11, 9), (8, 11), (11, 13), (11, 7), (9, 11)], 2),
        ]

        /// Wipes the stored matches and writes the requested sample data. Call before anything reads the store.
        static func applyIfRequested(eventStore: EventStore, modelContext: ModelContext) {
            guard seedsEmpty || seedsSampleMatches || seedsLeague || seedsActiveMatch else { return }
            do {
                // Row by row: a batch delete trips over the match <-> events inverse relationship
                for match in try modelContext.fetch(FetchDescriptor<StoredMatch>()) {
                    VideoStore.removeAll(matchId: match.id)  // its recordings and exports
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
                if seedsLeague {
                    for (index, sample) in leagueMatches.enumerated() {
                        try writeFinishedMatch(
                            sample.games, players: sample.players, daysAgo: sample.daysAgo, index: index,
                            store: eventStore)
                    }
                }
                if seedsReel {
                    if seedsSampleMatches {
                        try startReelExport(store: eventStore)
                    } else {
                        Log.store.warning("Debug seed: -seedReel / -seedReelPortrait need -seedSampleMatches")
                    }
                }
                if seedsActiveMatch {
                    try writeActiveMatch(store: eventStore)
                }
                UserPreferencesService(modelContext: modelContext)
                    .updatePlayerNames(player1: playerOne, player2: playerTwo)
                Log.store.info(
                    "Debug seed applied (sample matches: \(seedsSampleMatches), league: \(seedsLeague), active: \(seedsActiveMatch))"
                )
            } catch {
                Log.store.error("Debug seed failed: \(error)")
            }
        }

        // MARK: - Writers

        /// A finished best-of-five match: every point, one highlight per game, game and match end events.
        private static func writeFinishedMatch(
            _ games: [(Int, Int)], players: (String, String) = (playerOne, playerTwo), daysAgo: Int, index: Int,
            store: EventStore
        ) throws {
            let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: eveningToday) ?? Date()
            var match = MatchWriter(store: store, start: start, seed: UInt64(index + 1), players: players)
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

        // MARK: - Highlight reel

        /// Points the newest finished match at its full video and reel files and starts writing them: a 20 s mock
        /// recording, then the real reel export with the scoreboard (see `exportReel`).
        private static func startReelExport(store: EventStore) throws {
            guard let match = try store.getAllMatches().first(where: { !$0.isActive }) else { return }
            var state = try StateProjector().project(events: store.getEvents(matchId: match.id), matchMetadata: match)
            state.playerOneName = match.playerOneName
            state.playerTwoName = match.playerTwoName
            let full = VideoStore.fileURL(matchId: match.id, kind: .full)
            let reel = VideoStore.fileURL(matchId: match.id, kind: .highlights)
            // Referenced before the files exist: history is loaded right after the seed, the export finishes later
            match.fullVideoURL = VideoStore.storedReference(for: full)
            match.highlightVideoURL = VideoStore.storedReference(for: reel)
            try store.updateMatch(match)
            let highlights = state.highlightClips + (state.pendingHighlight.map { [$0] } ?? [])
            let timeline = ReelScoreboardTimeline(scoreState: state)
            reelExport = Task { await exportReel(timeline: timeline, highlights: highlights, full: full, reel: reel) }
        }

        /// The match's first four highlights (scored from the match's own points), each cut as 4.5 s of a 20 s mock
        /// recording (720x1280 with -seedReelPortrait, 1280x720 otherwise): clip k covers 5k to 5k + 4.5 s, long
        /// enough for the celebration at its end.
        private static func exportReel(
            timeline: ReelScoreboardTimeline, highlights: [HighlightClip], full: URL, reel: URL
        ) async {
            let clock = ContinuousClock()
            let start = clock.now
            let size = seedsPortraitReel ? CGSize(width: 720, height: 1280) : MockVideoGenerator.defaultSize
            guard let source = await MockVideoGenerator.generateMockVideo(duration: 20, to: full, size: size) else {
                Log.store.error("Debug seed: mock recording failed")
                return
            }
            let picked = Array(highlights.prefix(4))
            let clipLength = 4.5
            let clips = picked.enumerated().map { index, highlight in
                MediaExportService.HighlightClipInfo(
                    startTimestamp: Double(index) * 5, endTimestamp: Double(index) * 5 + clipLength,
                    player: highlight.player, gameNumber: highlight.gameNumber)
            }
            let cues = timeline.cues(for: picked.map { ReelClip(highlight: $0, reelDuration: clipLength) })
            do {
                let overlays = try await MediaExportService.scoreboardOverlays(cues, forReelFrom: source)
                let result = try await MediaExportService.exportHighlightReel(
                    from: source, to: reel, clips: clips, scoreboard: overlays)
                Log.store.info(
                    "Debug seed: reel of \(clips.count) clips, \(overlays.count) scoreboard cues, \(result.duration)s, written in \(String(describing: start.duration(to: clock.now)))"
                )
            } catch {
                Log.store.error("Debug seed: reel export failed: \(error)")
            }
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
            /// Player one's and player two's names.
            let players: (one: String, two: String)
            let matchId = UUID()
            private var sequence = 0
            private var elapsed: TimeInterval = 0
            private var random: UInt64
            private var gamesWon = (one: 0, two: 0)

            init(store: EventStore, start: Date, seed: UInt64, players: (String, String) = (playerOne, playerTwo)) {
                self.store = store
                self.start = start
                self.players = players
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
                let name = "\(players.one) vs \(players.two) - \(start.formatted(date: .abbreviated, time: .shortened))"
                _ = try store.createMatch(
                    id: matchId, matchName: name, playerOneName: players.one, playerTwoName: players.two,
                    startTimestamp: start)
                try store.append(
                    event: MatchStartedEvent(
                        matchId: matchId, timestamp: start, sequenceNumber: nextSequence(), matchName: name,
                        playerOneName: players.one, playerTwoName: players.two, recordingStartTime: start,
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
