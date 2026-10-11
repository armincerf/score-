//
//  MatchScoreboardTimelineTests.swift
//  scoreTests
//
//  The full match video's scoreboard rules: contiguous cues over the whole video, each point lit for the
//  celebration (cut short by a quicker next point), the next server (deuce included), the game change, the game in
//  progress, untimed points left out, recording gaps and out-of-order times.
//

import CoreMedia
import Foundation
import Testing

@testable import score

@Suite("MatchScoreboardTimeline")
struct MatchScoreboardTimelineTests {
    // MARK: - Fixtures

    /// One segment from wall clock 0, so wall time = video time.
    private static func recording(_ duration: Double) -> RecordingTimeline {
        RecordingTimeline(segments: [RecordingSegment(fileReference: "a.mov", startOffset: 0, duration: duration)])
    }

    private static func points(_ scored: [(player: Int, at: Double)]) -> [PointEvent] {
        scored.map { PointEvent(player: $0.player, videoTimestamp: $0.at) }
    }

    private static func match(
        games: [GameResult] = [], current: [PointEvent] = [], currentFirstServer: Int? = 1
    ) -> ReelScoreboardTimeline {
        ReelScoreboardTimeline(
            playerOneName: "Alex", playerTwoName: "Lucio", games: games, currentGamePoints: current,
            currentGameFirstServer: currentFirstServer)
    }

    private static func state(
        games: (Int, Int) = (0, 0), _ one: Int, _ two: Int, server: Int?, wonBy: Int? = nil
    ) -> ReelScoreboardState {
        ReelScoreboardState(
            playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: games.0, playerTwoGames: games.1,
            playerOnePoints: one, playerTwoPoints: two, server: server, pointWonBy: wonBy)
    }

    /// The cues as (start, end, state) in seconds, for readable expectations.
    private static func spans(_ cues: [ReelScoreboardCue]) -> [(start: Double, end: Double, state: ReelScoreboardState)]
    {
        cues.map { ($0.timeRange.start.seconds, $0.timeRange.end.seconds, $0.state) }
    }

    private static func expectContiguous(
        _ cues: [ReelScoreboardCue], duration: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(cues.first?.timeRange.start == .zero, sourceLocation: sourceLocation)
        #expect(
            abs((cues.last?.timeRange.end.seconds ?? 0) - duration) < 1e-6, "ends at the video's end",
            sourceLocation: sourceLocation)
        for (earlier, later) in zip(cues, cues.dropFirst()) {
            #expect(earlier.timeRange.end == later.timeRange.start, "no gap or overlap", sourceLocation: sourceLocation)
            #expect(earlier.timeRange.duration > .zero, sourceLocation: sourceLocation)
        }
    }

    private static func near(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 1e-3
    }

    // MARK: - Points

    @Test("Each point lights the winner's row for 1.2 s, then shows the score with the next server")
    func pointsLightThenSettle() throws {
        let match = Self.match(current: Self.points([(1, 2), (2, 5), (2, 9)]))
        let cues = MatchScoreboardTimeline.cues(match: match, recording: Self.recording(20), videoDuration: 20)
        Self.expectContiguous(cues, duration: 20)
        let spans = Self.spans(cues)
        try #require(spans.count == 7)
        let expected: [(Double, Double, ReelScoreboardState)] = [
            (0, 2, Self.state(0, 0, server: 1)),
            (2, 3.2, Self.state(1, 0, server: 1, wonBy: 1)),  // one point played: player one still serves
            (3.2, 5, Self.state(1, 0, server: 1)),
            (5, 6.2, Self.state(1, 1, server: 2, wonBy: 2)),  // two played: the serve changes
            (6.2, 9, Self.state(1, 1, server: 2)),
            (9, 10.2, Self.state(1, 2, server: 2, wonBy: 2)),
            (10.2, 20, Self.state(1, 2, server: 2)),
        ]
        for (span, want) in zip(spans, expected) {
            #expect(Self.near(span.start, want.0) && Self.near(span.end, want.1), "\(span.start)-\(span.end)")
            #expect(span.state == want.2, "at \(span.start): \(span.state)")
        }
    }

    @Test("A point within 1.2 s of the previous one cuts its celebration short")
    func quickPointCutsCelebration() throws {
        let match = Self.match(current: Self.points([(1, 2), (1, 2.5)]))
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(10), videoDuration: 10))
        try #require(spans.count == 4)
        #expect(Self.near(spans[1].start, 2) && Self.near(spans[1].end, 2.5))
        #expect(spans[1].state == Self.state(1, 0, server: 1, wonBy: 1))
        #expect(Self.near(spans[2].start, 2.5) && Self.near(spans[2].end, 3.7))
        #expect(spans[2].state == Self.state(2, 0, server: 2, wonBy: 1))
        #expect(spans[3].state == Self.state(2, 0, server: 2))
    }

    @Test("At deuce the serve changes every point")
    func deuceServing() throws {
        // Alternating points, one every 2 s from 2 s, to 10-10 (20 points), then two more
        let order = (0..<22).map { $0.isMultiple(of: 2) ? 1 : 2 }
        let match = Self.match(current: Self.points(order.enumerated().map { ($1, Double(2 * ($0 + 1))) }))
        let cues = MatchScoreboardTimeline.cues(match: match, recording: Self.recording(50), videoDuration: 50)
        Self.expectContiguous(cues, duration: 50)
        // The settled board after point n (at 2n + 1.2 s) shows who serves point n + 1
        func settled(after played: Int) -> ReelScoreboardState? {
            cues.first { Self.near($0.timeRange.start.seconds, Double(2 * played) + 1.2) }?.state
        }
        #expect(settled(after: 18)?.server == 2, "two serves each: points 19 and 20 are player two's")
        #expect(settled(after: 19)?.server == 2, "player two's second serve")
        #expect(settled(after: 20)?.server == 1, "10-10: the first server serves")
        #expect(settled(after: 21)?.server == 2, "11-10: the serve changes every point")
        #expect(settled(after: 22)?.server == 1)
        #expect(settled(after: 22)?.playerOnePoints == 11 && settled(after: 22)?.playerTwoPoints == 11)
    }

    // MARK: - Games

    @Test("After a game's last point: the lit final score, then the games box, 0-0 and the next first server")
    func gameChange() throws {
        let gameOne = GameResult(
            playerOneScore: 3, playerTwoScore: 0, winner: 1, points: Self.points([(1, 1), (1, 2), (1, 3)]),
            firstServer: 1)
        let match = Self.match(games: [gameOne], current: Self.points([(2, 8)]), currentFirstServer: 2)
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(12), videoDuration: 12))
        let final = try #require(spans.first { Self.near($0.start, 3) })
        #expect(final.state == Self.state(3, 0, server: nil, wonBy: 1), "game over: nobody serves")
        #expect(Self.near(final.end, 4.2))
        let next = try #require(spans.first { Self.near($0.start, 4.2) })
        #expect(next.state == Self.state(games: (1, 0), 0, 0, server: 2))
        #expect(Self.near(next.end, 8))
        let inProgress = try #require(spans.first { Self.near($0.start, 8) })
        #expect(inProgress.state == Self.state(games: (1, 0), 0, 1, server: 2, wonBy: 2))
        #expect(spans.last?.state == Self.state(games: (1, 0), 0, 1, server: 2))
    }

    @Test("After the last game, with no next game's server known, the board shows the games and nobody to serve")
    func matchOver() throws {
        let game = GameResult(
            playerOneScore: 0, playerTwoScore: 2, winner: 2, points: Self.points([(2, 1), (2, 2)]), firstServer: 2)
        let match = Self.match(games: [game], current: [], currentFirstServer: nil)
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(6), videoDuration: 6))
        #expect(spans.first?.state == Self.state(0, 0, server: 2), "game 1's first server from the start")
        #expect(spans.last?.state == Self.state(games: (0, 1), 0, 0, server: nil))
        #expect(Self.near(spans.last?.start ?? 0, 3.2))
    }

    /// Three games of two points each, all won by `winners[n]`, game n's points at 10n + 1 and 10n + 2 s; first
    /// servers alternate from player 1.
    private static func games(won winners: [Int]) -> [GameResult] {
        winners.enumerated().map { number, winner in
            let start = Double(number * 10)
            return GameResult(
                playerOneScore: winner == 1 ? 2 : 0, playerTwoScore: winner == 2 ? 2 : 0, winner: winner,
                points: points([(winner, start + 1), (winner, start + 2)]), firstServer: number % 2 + 1)
        }
    }

    @Test("Once the games decide the match nobody serves, though the state names the next game's server")
    func decidedMatchHasNoServer() throws {
        // As the app leaves it: the first server moved on after the deciding game too
        let match = Self.match(games: Self.games(won: [1, 1, 1]), current: [], currentFirstServer: 2)
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(40), videoDuration: 40))
        let last = try #require(spans.last)
        #expect(last.state == Self.state(games: (3, 0), 0, 0, server: nil))
        #expect(Self.near(last.start, 23.2), "after the deciding point's celebration")
        #expect(spans.allSatisfy { $0.state.server != nil || $0.state.pointWonBy != nil || $0.start >= 23.2 })
    }

    @Test("A match ended before it is decided shows the next game's server")
    func undecidedMatchKeepsTheServer() throws {
        let match = Self.match(games: Self.games(won: [1, 2, 1]), current: [], currentFirstServer: 2)
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(40), videoDuration: 40))
        #expect(spans.last?.state == Self.state(games: (2, 1), 0, 0, server: 2))
    }

    @Test("Played on after the match was decided, the next game has its server")
    func playedOnAfterTheMatch() throws {
        let match = Self.match(
            games: Self.games(won: [2, 2, 2]), current: Self.points([(1, 35)]), currentFirstServer: 2)
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(40), videoDuration: 40))
        let between = try #require(spans.first { Self.near($0.start, 23.2) })
        #expect(between.state == Self.state(games: (0, 3), 0, 0, server: 2))
        #expect(spans.last?.state == Self.state(games: (0, 3), 1, 0, server: 2))
    }

    @Test("A finished game without timed points still moves the games box")
    func untimedGame() throws {
        let untimed = GameResult(
            playerOneScore: 11, playerTwoScore: 5, winner: 1, points: [PointEvent(player: 1)], firstServer: 1)
        let match = Self.match(games: [untimed], current: Self.points([(1, 4)]), currentFirstServer: 2)
        let cues = MatchScoreboardTimeline.cues(match: match, recording: Self.recording(8), videoDuration: 8)
        Self.expectContiguous(cues, duration: 8)
        let spans = Self.spans(cues)
        #expect(spans.first?.state == Self.state(games: (1, 0), 0, 0, server: 2), "nothing to show of game 1")
        #expect(spans.last?.state == Self.state(games: (1, 0), 1, 0, server: 2))
    }

    // MARK: - Time

    @Test("Points without a video time are left out")
    func untimedPointsSkipped() {
        let match = Self.match(current: [PointEvent(player: 1)] + Self.points([(2, 3)]))
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(6), videoDuration: 6))
        #expect(spans.map(\.state.playerOnePoints) == [0, 0, 0])
        #expect(spans.last?.state == Self.state(0, 1, server: 1))
    }

    @Test("A point in a recording gap shows when the footage resumes; video time follows the segments")
    func recordingGap() throws {
        // Footage: wall 0-10 (video 0-10), then wall 30-40 (video 10-20)
        let recording = RecordingTimeline(segments: [
            RecordingSegment(fileReference: "a.mov", startOffset: 0, duration: 10),
            RecordingSegment(fileReference: "b.mov", startOffset: 30, duration: 10),
        ])
        let match = Self.match(current: Self.points([(1, 5), (2, 20), (1, 35)]))
        let spans = Self.spans(MatchScoreboardTimeline.cues(match: match, recording: recording, videoDuration: 20))
        let starts = spans.map(\.start)
        #expect(starts.contains { Self.near($0, 5) })
        #expect(starts.contains { Self.near($0, 10) }, "the point at wall 20 (a gap) shows at video 10")
        #expect(starts.contains { Self.near($0, 15) }, "wall 35 is video 15")
    }

    @Test("A point timed before the previous one is shown at the previous one's time, never earlier")
    func outOfOrderClamps() throws {
        let match = Self.match(current: Self.points([(1, 5), (2, 3)]))
        let cues = MatchScoreboardTimeline.cues(match: match, recording: Self.recording(10), videoDuration: 10)
        Self.expectContiguous(cues, duration: 10)
        let spans = Self.spans(cues)
        try #require(spans.count == 3)
        #expect(Self.near(spans[1].start, 5) && spans[1].state == Self.state(1, 1, server: 2, wonBy: 2))
        #expect(spans[2].state == Self.state(1, 1, server: 2))
    }

    @Test("Changes after the video's end are dropped, and a video without length has no cues")
    func videoEnd() {
        let match = Self.match(current: Self.points([(1, 2), (1, 9)]))
        let spans = Self.spans(
            MatchScoreboardTimeline.cues(match: match, recording: Self.recording(10), videoDuration: 5))
        #expect(spans.count == 3)
        #expect(Self.near(spans.last?.end ?? 0, 5))
        #expect(MatchScoreboardTimeline.cues(match: match, recording: Self.recording(10), videoDuration: 0).isEmpty)
    }

    @Test("Built from a ScoreState: names, finished games and the game in progress")
    func fromScoreState() throws {
        var state = ScoreState()
        state.playerOneName = "Ann"
        state.playerTwoName = "Bob"
        state.currentGamePoints = Self.points([(1, 1)])
        state.currentGameFirstServer = 2
        let cues = MatchScoreboardTimeline.cues(
            match: ReelScoreboardTimeline(scoreState: state), recording: Self.recording(4), videoDuration: 4)
        let first = try #require(cues.first)
        #expect(first.state.playerOneName == "Ann" && first.state.playerTwoName == "Bob")
        #expect(first.state.server == 2)
        #expect(cues.last?.state.playerOnePoints == 1)
    }
}
