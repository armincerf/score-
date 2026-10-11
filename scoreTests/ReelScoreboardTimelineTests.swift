//
//  ReelScoreboardTimelineTests.swift
//  scoreTests
//
//  The reel scoreboard's rules: the score and server at each clip's start, the celebration state at the end of
//  attributed clips that are long enough and whose point the game recorded (the game's next timed point, won by
//  the highlight's player), and the reel-time ranges laid end to end in clip order.
//

import CoreMedia
import Foundation
import Testing

@testable import score

@Suite("ReelScoreboardTimeline")
struct ReelScoreboardTimelineTests {
    // MARK: - Fixtures

    /// Points scored in `order` (player numbers), one every `step` seconds of wall clock from `start`.
    private static func points(_ order: [Int], from start: Double, every step: Double = 1) -> [PointEvent] {
        order.enumerated().map { index, player in
            PointEvent(player: player, videoTimestamp: start + Double(index) * step)
        }
    }

    /// A finished game made of `order`, won by whoever scored more.
    private static func game(_ order: [Int], from start: Double, firstServer: Int) -> GameResult {
        let one = order.filter { $0 == 1 }.count
        let two = order.count - one
        return GameResult(
            playerOneScore: one, playerTwoScore: two, winner: one > two ? 1 : 2,
            points: points(order, from: start), firstServer: firstServer)
    }

    private static func timeline(
        games: [GameResult], current: [PointEvent] = [], currentFirstServer: Int? = nil
    ) -> ReelScoreboardTimeline {
        ReelScoreboardTimeline(
            playerOneName: "Alex", playerTwoName: "Lucio", games: games, currentGamePoints: current,
            currentGameFirstServer: currentFirstServer)
    }

    private static func clip(
        game: Int, start: Double, player: Int?, reelDuration: Double, end: Double? = nil
    ) -> ReelClip {
        ReelClip(
            highlight: HighlightClip(
                startTimestamp: start, endTimestamp: end ?? start + reelDuration, player: player, gameNumber: game),
            reelDuration: reelDuration)
    }

    private static func expectRange(
        _ range: CMTimeRange, from start: Double, to end: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(range.start.seconds - start) < 1e-6, "start \(range.start.seconds)", sourceLocation: sourceLocation)
        #expect(abs(range.end.seconds - end) < 1e-6, "end \(range.end.seconds)", sourceLocation: sourceLocation)
    }

    /// Game 1 won 10-6 by player one, game 2 won 8-11 by player two, then a deuce game won 13-11 by player one
    /// (first server 1): alternating points to 10-10 (index 19), then 1, 2, 1, 1; its point `i` is at 200 + i s.
    private static let threeGames = [
        game([1, 1, 2, 1, 1, 2, 1, 1, 2, 1, 2, 1, 1, 2, 2, 1], from: 0, firstServer: 1),
        game([2, 1, 2, 2, 1, 2, 1, 2, 2, 1, 2, 1, 1, 2, 1, 2, 2, 1, 2], from: 100, firstServer: 2),
        game((0..<20).map { $0.isMultiple(of: 2) ? 1 : 2 } + [1, 2, 1, 1], from: 200, firstServer: 1),
    ]

    // MARK: - Score at the clip's start

    @Test("A clip in the first game shows the score at its start, who serves, then the winner's point")
    func clipInFirstGame() throws {
        // Points at 10, 11, 12 and 13 s; the clip starts at the third and player two wins the rally (13 s)
        let timeline = Self.timeline(
            games: [], current: Self.points([1, 2, 1, 2], from: 10), currentFirstServer: 1)
        let cues = timeline.cues(for: [Self.clip(game: 0, start: 12, player: 2, reelDuration: 8)])

        try #require(cues.count == 2)
        #expect(
            cues[0].state
                == ReelScoreboardState(
                    playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 0, playerTwoGames: 0,
                    playerOnePoints: 2, playerTwoPoints: 1, server: 2, pointWonBy: nil))
        Self.expectRange(cues[0].timeRange, from: 0, to: 6.8)
        // Last 1.2 s: player two's row lit with the new score; four points played, so player one serves
        #expect(
            cues[1].state
                == ReelScoreboardState(
                    playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 0, playerTwoGames: 0,
                    playerOnePoints: 2, playerTwoPoints: 2, server: 1, pointWonBy: 2))
        Self.expectRange(cues[1].timeRange, from: 6.8, to: 8)
    }

    @Test(
        "A clip in game 3 counts the games before it and serve changes every point from 10-10",
        arguments: [(19, 10, 10, 1), (20, 11, 10, 2), (21, 11, 11, 1), (22, 12, 11, 2)])
    func deuceInGameThree(lastPoint: Int, one: Int, two: Int, server: Int) throws {
        let timeline = Self.timeline(games: Self.threeGames, current: [], currentFirstServer: 2)
        // The highlight goes to whoever won the rally, as the app attributes it: game 3's next point
        let winner = Self.threeGames[2].points[lastPoint + 1].player
        let states = timeline.states(
            for: HighlightClip(
                startTimestamp: 200 + Double(lastPoint), endTimestamp: 230, player: winner, gameNumber: 2))

        // Games before game 3 only (1-1): game 3's own result is not on the board yet
        #expect(states.start.playerOneGames == 1 && states.start.playerTwoGames == 1)
        #expect(states.start.playerOnePoints == one && states.start.playerTwoPoints == two)
        #expect(states.start.server == server)
        #expect(
            server == ServingLogic.calculateCurrentServer(firstServer: 1, playerOneScore: one, playerTwoScore: two))
        let won = try #require(states.celebration)
        #expect(won.pointWonBy == winner)
        #expect(won.playerOnePoints == (winner == 1 ? one + 1 : one))
        #expect(won.playerTwoPoints == (winner == 2 ? two + 1 : two))
        #expect(won.server == (server == 1 ? 2 : 1), "at deuce the serve changes after every point")
    }

    @Test("A point at exactly the clip's start counts; a later one does not")
    func pointAtClipStartCounts() {
        let timeline = Self.timeline(
            games: [], current: Self.points([1, 2, 1], from: 1, every: 0.75), currentFirstServer: 1)
        // Points at 1.0, 1.75 and 2.5
        let atLastPoint = timeline.states(
            for: HighlightClip(startTimestamp: 2.5, endTimestamp: 9, player: nil, gameNumber: 0))
        #expect(atLastPoint.start.playerOnePoints == 2 && atLastPoint.start.playerTwoPoints == 1)
        let justBefore = timeline.states(
            for: HighlightClip(startTimestamp: 2.499, endTimestamp: 9, player: nil, gameNumber: 0))
        #expect(justBefore.start.playerOnePoints == 1 && justBefore.start.playerTwoPoints == 1)
    }

    @Test("Points without a wall-clock time cannot be placed and are not counted")
    func untimedPointsAreIgnored() {
        let current = [PointEvent(player: 1, videoTimestamp: nil), PointEvent(player: 2, videoTimestamp: 3)]
        let timeline = Self.timeline(games: [], current: current, currentFirstServer: 1)
        let states = timeline.states(for: HighlightClip(startTimestamp: 5, endTimestamp: 9, player: nil, gameNumber: 0))
        #expect(states.start.playerOnePoints == 0 && states.start.playerTwoPoints == 1)
    }

    // MARK: - Celebration window

    @Test("A pending (unattributed) highlight shows one state for the whole clip, without a celebration")
    func pendingHighlightHasNoCelebration() throws {
        let timeline = Self.timeline(games: [], current: Self.points([1, 1], from: 0), currentFirstServer: 2)
        let cues = timeline.cues(for: [Self.clip(game: 0, start: 1, player: nil, reelDuration: 6)])
        try #require(cues.count == 1)
        #expect(cues[0].state.pointWonBy == nil)
        #expect(cues[0].state.playerOnePoints == 2 && cues[0].state.server == 1)
        Self.expectRange(cues[0].timeRange, from: 0, to: 6)
    }

    @Test(
        "Only clips of at least 3 s get the 1.2 s celebration at their end",
        arguments: [(0.5, 1), (2.99, 1), (3.0, 2), (10.0, 2)])
    func celebrationNeedsThreeSeconds(duration: Double, expectedCues: Int) throws {
        // 0-1 at 0 s, the clip's start; player one wins the rally (1-1 at 1 s)
        let timeline = Self.timeline(games: [], current: Self.points([2, 1], from: 0), currentFirstServer: 1)
        let cues = timeline.cues(for: [Self.clip(game: 0, start: 0, player: 1, reelDuration: duration)])
        try #require(cues.count == expectedCues)
        #expect(cues[0].state.pointWonBy == nil)
        Self.expectRange(cues.last?.timeRange ?? .zero, from: expectedCues == 1 ? 0 : duration - 1.2, to: duration)
        if expectedCues == 2 {
            Self.expectRange(cues[0].timeRange, from: 0, to: duration - 1.2)
            #expect(cues[1].state.pointWonBy == 1 && cues[1].state.playerOnePoints == 1)
        }
    }

    @Test("An attributed clip with no later point in its game (a forced End Game) shows one state, no celebration")
    func attributedClipWithoutItsPoint() throws {
        // Game 1 ended by End Game at 6-4 (last point at 9 s) and awarded to player one, who was credited with the
        // still-pending highlight; game 2 has a point by player one, which belongs to game 2, not to the clip
        let forced = GameResult(
            playerOneScore: 6, playerTwoScore: 4, winner: 1,
            points: Self.points([1, 2, 1, 1, 2, 2, 1, 2, 1, 1], from: 0),
            firstServer: 1)
        let timeline = Self.timeline(games: [forced], current: Self.points([1], from: 60), currentFirstServer: 2)
        let cues = timeline.cues(for: [Self.clip(game: 0, start: 9, player: 1, reelDuration: 6)])

        try #require(cues.count == 1, "no point after the clip's start, so nothing to celebrate")
        #expect(
            cues[0].state
                == ReelScoreboardState(
                    playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 0, playerTwoGames: 0,
                    playerOnePoints: 6, playerTwoPoints: 4, server: 2, pointWonBy: nil))
        Self.expectRange(cues[0].timeRange, from: 0, to: 6)
    }

    @Test("A clip whose next recorded point went to the other player shows no celebration")
    func nextPointByTheOtherPlayer() {
        let timeline = Self.timeline(games: [], current: Self.points([1, 2, 2], from: 0), currentFirstServer: 1)
        // The clip starts at 1-1 (1 s); the game's next point (2 s) is player two's, not the highlight's player one
        let states = timeline.states(for: HighlightClip(startTimestamp: 1, endTimestamp: 6, player: 1, gameNumber: 0))
        #expect(states.start.playerOnePoints == 1 && states.start.playerTwoPoints == 1)
        #expect(states.celebration == nil)
    }

    // MARK: - Reel time

    @Test("Clips are laid end to end from reel time 0, in clip order, each with its own game's score")
    func clipsAreLaidEndToEnd() throws {
        let timeline = Self.timeline(
            games: Array(Self.threeGames.prefix(1)), current: Self.points([2, 2], from: 50), currentFirstServer: 2)
        // Clip 1 starts at game 1's fifth point (4 s); player two won the next one (5 s)
        let cues = timeline.cues(for: [
            Self.clip(game: 0, start: 4, player: 2, reelDuration: 4),
            Self.clip(game: 1, start: 51, player: 2, reelDuration: 2.5),
        ])

        try #require(cues.count == 3)
        Self.expectRange(cues[0].timeRange, from: 0, to: 2.8)
        Self.expectRange(cues[1].timeRange, from: 2.8, to: 4)
        Self.expectRange(cues[2].timeRange, from: 4, to: 6.5)
        for (previous, next) in zip(cues, cues.dropFirst()) {
            #expect(previous.timeRange.end == next.timeRange.start, "no gap or overlap between cues")
        }
        // Clip 2 is in game 2: player one has won game 1; the current game is 0-2
        #expect(cues[2].state.playerOneGames == 1 && cues[2].state.playerTwoGames == 0)
        #expect(cues[2].state.playerOnePoints == 0 && cues[2].state.playerTwoPoints == 2)
    }

    @Test("A clip that contributes no footage gets no cue and does not shift the next clip")
    func emptyClipIsSkipped() throws {
        let timeline = Self.timeline(games: [], current: [], currentFirstServer: 1)
        let cues = timeline.cues(for: [
            Self.clip(game: 0, start: 0, player: 1, reelDuration: 0),
            Self.clip(game: 0, start: 1, player: nil, reelDuration: 2),
        ])
        try #require(cues.count == 1)
        Self.expectRange(cues[0].timeRange, from: 0, to: 2)
    }

    // MARK: - Inconsistent data

    @Test("A clip whose game is beyond the match data falls back to the games so far, 0-0 and no server")
    func gameBeyondTheData() throws {
        let timeline = Self.timeline(games: Self.threeGames, current: Self.points([1], from: 300))
        let cues = timeline.cues(for: [Self.clip(game: 7, start: 400, player: 1, reelDuration: 5)])
        try #require(cues.count == 1, "no celebration is invented for a game with no data")
        let state = cues[0].state
        #expect(state.playerOneGames == 2 && state.playerTwoGames == 1)
        #expect(state.playerOnePoints == 0 && state.playerTwoPoints == 0)
        #expect(state.server == nil && state.pointWonBy == nil)
        Self.expectRange(cues[0].timeRange, from: 0, to: 5)
    }

    @Test("Without the current game's first server the board shows no serve marker")
    func unknownFirstServer() throws {
        // 1-0 at 0 s, the clip's start; player two wins the rally (1-1 at 1 s)
        let timeline = Self.timeline(games: [], current: Self.points([1, 2], from: 0), currentFirstServer: nil)
        let states = timeline.states(for: HighlightClip(startTimestamp: 0, endTimestamp: 5, player: 2, gameNumber: 0))
        let won = try #require(states.celebration)
        #expect(states.start.server == nil && won.server == nil)
        #expect(won.playerOnePoints == 1 && won.playerTwoPoints == 1 && won.pointWonBy == 2)
    }

    // MARK: - From the live match

    @Test("The live match's names, finished games and current game feed the timeline")
    func fromScoreState() {
        var state = ScoreState()
        state.playerOneName = "Ana"
        state.currentMatchGames = Array(Self.threeGames.prefix(2))
        state.currentGamePoints = Self.points([2], from: 150)
        state.currentGameFirstServer = 1
        let timeline = ReelScoreboardTimeline(scoreState: state)
        #expect(timeline.playerOneName == "Ana" && timeline.playerTwoName == "Player 2")
        let states = timeline.states(
            for: HighlightClip(startTimestamp: 150, endTimestamp: 155, player: nil, gameNumber: 2))
        #expect(states.start.playerOneGames == 1 && states.start.playerTwoGames == 1)
        #expect(states.start.playerTwoPoints == 1 && states.start.server == 1)
    }
}
