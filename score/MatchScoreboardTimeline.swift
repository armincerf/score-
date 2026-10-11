//
//  MatchScoreboardTimeline.swift
//  score
//
//  What the full match video's scoreboard shows, and when: the same broadcast board as the highlight reel, kept
//  up to date point by point over the whole recording. From 0-0 with game 1's first server, each point lights the
//  winner's row with the new score for `ReelScoreboardTimeline.celebrationDuration` (cut short when the next point
//  comes sooner), then shows the score with the next server; after a game's last point the lit final score gives
//  way to the games box updated, 0-0 and the next game's first server (nobody once the match is decided). Pure, so the rules are unit-tested; the
//  bitmaps are rendered lazily during the export (`ScoreboardOverlaySource`).
//

import CoreMedia
import Foundation
import os

nonisolated enum MatchScoreboardTimeline {
    /// The board's cues over the full video, in video time: contiguous from 0 to `videoDuration` (empty when the
    /// video has no length). `match` holds the names, the finished games and the game in progress; point times are
    /// wall-clock offsets, mapped into the concatenated video by `recording` (a point in a gap shows when the
    /// footage resumes). Points without a time are left out (logged once); a point whose video time is not after
    /// the board's previous change is shown at that change instead (a point cannot move the board back in time).
    /// Once a best-of-`bestOf` match is decided the board shows nobody to serve, unless the players kept playing.
    static func cues(
        match: ReelScoreboardTimeline, recording: RecordingTimeline, videoDuration: Double, bestOf: Int = 5
    ) -> [ReelScoreboardCue] {
        guard videoDuration > 0 else { return [] }
        var changes = Changes()
        var untimed = 0
        var lastPoint = 0.0  // video time of the latest point placed: a later point never shows before it
        var gamesWon = (one: 0, two: 0)
        let gameCount = match.games.count + 1  // the finished games, then the game in progress
        changes.set(
            at: 0, state: board(match, games: gamesWon, points: (0, 0), server: firstServer(match, game: 0)))

        for number in 0..<gameCount {
            guard let game = match.game(number: number) else { continue }
            let finished = number < match.games.count
            var score = (one: 0, two: 0)
            let timed = game.points.filter { $0.videoTimestamp != nil }
            untimed += game.points.count - timed.count
            for (index, point) in timed.enumerated() {
                guard let wall = point.videoTimestamp, point.player == 1 || point.player == 2 else { continue }
                if point.player == 1 { score.one += 1 } else { score.two += 1 }
                let played = score.one + score.two
                let isLastOfGame = finished && index == timed.count - 1
                let time = max(recording.videoTime(forWallOffset: wall), lastPoint)
                lastPoint = time
                let server = isLastOfGame ? nil : match.server(afterPoints: played, firstServer: game.firstServer)
                changes.set(
                    at: time,
                    state: board(match, games: gamesWon, points: score, server: server, wonBy: point.player))
                if !isLastOfGame {
                    changes.set(
                        at: time + ReelScoreboardTimeline.celebrationDuration,
                        state: board(match, games: gamesWon, points: score, server: server))
                }
            }
            guard finished else { continue }
            if match.games[number].winner == 1 { gamesWon.one += 1 } else { gamesWon.two += 1 }
            // The next game starts at 0-0 once the final point's celebration is over; a game without timed points
            // only moves the games box, at the board's latest change
            let next = timed.isEmpty ? changes.lastTime : lastPoint + ReelScoreboardTimeline.celebrationDuration
            let server = serverOfGame(after: number, match, gamesWon: gamesWon, bestOf: bestOf)
            changes.set(at: next, state: board(match, games: gamesWon, points: (0, 0), server: server))
        }
        if untimed > 0 {
            Log.video.warning("Match scoreboard: \(untimed) point(s) without a video time left out")
        }
        return changes.cues(until: videoDuration)
    }

    // MARK: - Private

    private static func board(
        _ match: ReelScoreboardTimeline, games: (one: Int, two: Int), points: (one: Int, two: Int), server: Int?,
        wonBy: Int? = nil
    ) -> ReelScoreboardState {
        ReelScoreboardState(
            playerOneName: match.playerOneName, playerTwoName: match.playerTwoName, playerOneGames: games.one,
            playerTwoGames: games.two, playerOnePoints: points.one, playerTwoPoints: points.two, server: server,
            pointWonBy: wonBy)
    }

    /// Who serves first in game `number`, or nil when there is no such game or it has no first server.
    private static func firstServer(_ match: ReelScoreboardTimeline, game number: Int) -> Int? {
        match.game(number: number)?.firstServer
    }

    /// Who serves first in the game after game `number`, once the games stand at `gamesWon`: nobody when those games
    /// decide the match and no later game has a point (the app moves the first server on after every game, the
    /// deciding one included, so the state always names one); a match ended early, or played on after it was
    /// decided, shows the next game's server.
    private static func serverOfGame(
        after number: Int, _ match: ReelScoreboardTimeline, gamesWon: (one: Int, two: Int), bestOf: Int
    ) -> Int? {
        let decided =
            ScoreAnnouncementUtils.checkMatchWon(
                playerOneGames: gamesWon.one, playerTwoGames: gamesWon.two, bestOf: bestOf) != nil
        let playedOn = !(match.game(number: number + 1)?.points.isEmpty ?? true)
        return decided && !playedOn ? nil : firstServer(match, game: number + 1)
    }

    /// The board's changes in time order. Setting a change drops any later one already set (a point that comes
    /// before the previous point's celebration ends cuts it short) and replaces one at the same time.
    private struct Changes {
        private(set) var items: [(time: Double, state: ReelScoreboardState)] = []

        var lastTime: Double { items.last?.time ?? 0 }

        mutating func set(at time: Double, state: ReelScoreboardState) {
            while let last = items.last, last.time >= time { items.removeLast() }
            if let last = items.last, last.state == state { return }
            items.append((time, state))
        }

        /// Contiguous cues from 0 to `end`: each change lasts until the next; changes at or after `end` are dropped.
        func cues(until end: Double) -> [ReelScoreboardCue] {
            let scale = ReelScoreboardTimeline.timescale
            let kept = items.filter { $0.time < end }
            return kept.enumerated().compactMap { index, item in
                let start = CMTime(seconds: item.time, preferredTimescale: scale)
                let next = index + 1 < kept.count ? kept[index + 1].time : end
                let stop = CMTime(seconds: next, preferredTimescale: scale)
                guard stop > start else { return nil }
                return ReelScoreboardCue(timeRange: CMTimeRange(start: start, end: stop), state: item.state)
            }
        }
    }
}
