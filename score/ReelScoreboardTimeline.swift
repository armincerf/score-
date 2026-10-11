//
//  ReelScoreboardTimeline.swift
//  score
//
//  What the highlight reel's scoreboard shows, and when. For each clip of the reel (in reel order) the board
//  shows the score as the rally starts and, when the clip is long enough and the game recorded the rally's point
//  for the highlight's player, the winner's row lit with the new score for the clip's last 1.2 s. Pure, so the
//  rules are unit-tested; the bitmaps are rendered from these states as the export reaches them
//  (`ScoreboardOverlaySource`). The full match video's board is `MatchScoreboardTimeline`.
//

import CoreMedia
import Foundation

/// One stretch of the reel and the board shown during it.
nonisolated struct ReelScoreboardCue: Equatable, Sendable {
    /// Range in the reel's own timeline (from the start of the exported reel).
    let timeRange: CMTimeRange
    let state: ReelScoreboardState
}

/// A clip of the reel: the highlight it was cut from (wall-clock times, game, player) and how many seconds of
/// footage it contributes to the reel (the length of its range in the source video).
nonisolated struct ReelClip: Sendable {
    let highlight: HighlightClip
    let reelDuration: Double
}

/// Match data -> the scoreboard state(s) of each reel clip, laid end to end from reel time 0.
nonisolated struct ReelScoreboardTimeline: Sendable {
    /// How long the winner's row is lit at the end of a clip.
    static let celebrationDuration = 1.2
    /// Clips shorter than this show only the score at the start (no celebration).
    static let minimumCelebrationClipDuration = 3.0
    /// The reel composition's time base (`MediaExportService.clipTimeRanges` builds its ranges at 600).
    static let timescale: CMTimeScale = 600

    let playerOneName: String
    let playerTwoName: String
    /// Finished games of the match, in order (index = game number).
    let games: [GameResult]
    /// Points of the game in progress (game number `games.count`).
    let currentGamePoints: [PointEvent]
    let currentGameFirstServer: Int?

    init(
        playerOneName: String, playerTwoName: String, games: [GameResult], currentGamePoints: [PointEvent] = [],
        currentGameFirstServer: Int? = nil
    ) {
        self.playerOneName = playerOneName
        self.playerTwoName = playerTwoName
        self.games = games
        self.currentGamePoints = currentGamePoints
        self.currentGameFirstServer = currentGameFirstServer
    }

    /// The match as the phone holds it while the reel is exported.
    init(scoreState: ScoreState) {
        self.init(
            playerOneName: scoreState.playerOneName ?? "Player 1",
            playerTwoName: scoreState.playerTwoName ?? "Player 2",
            games: scoreState.currentMatchGames,
            currentGamePoints: scoreState.currentGamePoints,
            currentGameFirstServer: scoreState.currentGameFirstServer)
    }

    /// The board's cues for the reel's clips, in reel order. Each clip's cues cover exactly its reel duration and
    /// start where the previous clip's end; a clip that contributes no footage gets no cue.
    func cues(for clips: [ReelClip]) -> [ReelScoreboardCue] {
        var cues: [ReelScoreboardCue] = []
        var cursor = CMTime.zero
        for clip in clips where clip.reelDuration > 0 {
            let duration = CMTime(seconds: clip.reelDuration, preferredTimescale: Self.timescale)
            let states = states(for: clip.highlight)
            if let won = states.celebration, clip.reelDuration >= Self.minimumCelebrationClipDuration {
                let celebration = CMTime(seconds: Self.celebrationDuration, preferredTimescale: Self.timescale)
                let lead = CMTimeSubtract(duration, celebration)
                cues.append(
                    ReelScoreboardCue(timeRange: CMTimeRange(start: cursor, duration: lead), state: states.start))
                cues.append(
                    ReelScoreboardCue(
                        timeRange: CMTimeRange(start: CMTimeAdd(cursor, lead), duration: celebration), state: won))
            } else {
                cues.append(
                    ReelScoreboardCue(timeRange: CMTimeRange(start: cursor, duration: duration), state: states.start))
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        return cues
    }

    /// The board as the clip's rally starts and, for an attributed highlight whose point the game recorded (the
    /// game's first timed point after the clip's start, won by the highlight's player), after that point.
    func states(for clip: HighlightClip) -> (start: ReelScoreboardState, celebration: ReelScoreboardState?) {
        let gameNumber = max(0, clip.gameNumber)
        let earlier = games.prefix(gameNumber)
        let gamesOne = earlier.filter { $0.winner == 1 }.count
        let gamesTwo = earlier.filter { $0.winner == 2 }.count

        func board(points one: Int, _ two: Int, server: Int?, wonBy: Int? = nil) -> ReelScoreboardState {
            ReelScoreboardState(
                playerOneName: playerOneName, playerTwoName: playerTwoName, playerOneGames: gamesOne,
                playerTwoGames: gamesTwo, playerOnePoints: one, playerTwoPoints: two, server: server, pointWonBy: wonBy)
        }

        guard let game = game(number: gameNumber) else {
            // No data for that game (inconsistent input): the games so far, no points, no server, no celebration
            return (board(points: 0, 0, server: nil), nil)
        }
        // The clip starts at the last scored point (that point counts); points without a time cannot be placed
        let scored = game.points.filter { point in point.videoTimestamp.map { $0 <= clip.startTimestamp } ?? false }
        let one = scored.filter { $0.player == 1 }.count
        let two = scored.filter { $0.player == 2 }.count
        let start = board(points: one, two, server: server(afterPoints: one + two, firstServer: game.firstServer))

        // The celebration is the point the game recorded after the rally (its first timed point after the clip's
        // start), shown only when the highlight's player won it. A highlight credited to the game winner by a
        // forced End Game has no such point, and the board must not invent one.
        let next = game.points.first { point in point.videoTimestamp.map { $0 > clip.startTimestamp } ?? false }
        guard let next, let winner = clip.player, next.player == winner, winner == 1 || winner == 2 else {
            return (start, nil)
        }
        let won = board(
            points: winner == 1 ? one + 1 : one, winner == 2 ? two + 1 : two,
            server: server(afterPoints: one + two + 1, firstServer: game.firstServer), wonBy: winner)
        return (start, won)
    }

    // MARK: - Shared with MatchScoreboardTimeline

    /// A game's points and first server: a finished game, or the game in progress (number `games.count`).
    func game(number: Int) -> (points: [PointEvent], firstServer: Int?)? {
        if games.indices.contains(number) {
            return (games[number].points, games[number].firstServer)
        }
        return number == games.count ? (currentGamePoints, currentGameFirstServer) : nil
    }

    /// Who serves the next point once `played` points of the game have been played.
    func server(afterPoints played: Int, firstServer: Int?) -> Int? {
        firstServer.map { ServingLogic.serverForPoint(index: played, firstServer: $0) }
    }
}
