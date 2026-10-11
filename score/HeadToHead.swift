//
//  HeadToHead.swift
//  score
//
//  Head-to-head record of two players across every match between them: wins each way, matches without a
//  winner, games and points won each way, and the meetings themselves (newest first, filterable by winner).
//  `from(history:)` is the home card's record (the most recent match's pair); `between(_:_:in:)` any pair.
//  Players are recognised the way the AI summary's previous meetings are (`MatchPlayers.names`/`key`, the
//  `previousMeetings` extension in AI/MatchSummaryModels.swift); see `PlayedMatch` in PlayerRecords.swift.
//

import Foundation

nonisolated struct HeadToHead: Equatable, Sendable {
    /// Player one's identity (`MatchPlayers.key`).
    let playerOneID: String
    /// Player two's identity (`MatchPlayers.key`).
    let playerTwoID: String
    /// Player one as most recently spelled in the history, trimmed.
    let playerOneName: String
    /// Player two as most recently spelled in the history, trimmed.
    let playerTwoName: String
    let playerOneWins: Int
    let playerTwoWins: Int
    /// Matches between the two that ended without a winner (`MatchResult.noWinner`).
    let draws: Int
    /// Every match between the two, in either order: wins + draws.
    let matchesPlayed: Int
    /// Games won across the meetings.
    let playerOneGames: Int
    let playerTwoGames: Int
    /// Points won across the meetings (the recorded games' scores).
    let playerOnePoints: Int
    let playerTwoPoints: Int
    /// The matches between them, newest first, seen from this record's sides.
    let meetings: [HeadToHeadMeeting]

    /// The record for the players of the last match in `history` (oldest first). Names are compared trimmed and
    /// case-insensitively, in either order; a match whose names are missing (and not in its "A vs B - date" match
    /// name either) belongs to no pair. Nil for an empty history or when the last match has no usable names.
    static func from(history: [MatchResult]) -> HeadToHead? {
        guard let latest = history.last, let names = MatchPlayers.names(of: latest) else { return nil }
        return between(names.playerOne, names.playerTwo, in: history)
    }

    /// The record of `playerOne` against `playerTwo` over `history` (oldest first), with `playerOne` as side one.
    /// Nil when either name is blank or both name the same player; a pair that never met has an empty record.
    static func between(_ playerOne: String, _ playerTwo: String, in history: [MatchResult]) -> HeadToHead? {
        between(MatchPlayers.key(playerOne), MatchPlayers.key(playerTwo), in: PlayedMatch.all(in: history))
    }

    /// `between` over already resolved matches, by identity. Names are the most recent spelling in `played`,
    /// falling back to the identity itself (already trimmed) when the player is not in it.
    static func between(_ one: String, _ two: String, in played: [PlayedMatch]) -> HeadToHead? {
        guard !one.isEmpty, !two.isEmpty, one != two else { return nil }
        var tally = Tally()
        var meetings: [HeadToHeadMeeting] = []
        for match in played.reversed() {
            guard let side = match.side(of: one), match.side(of: two) == 3 - side else { continue }
            let meeting = HeadToHeadMeeting(match, seenFrom: side)
            tally.add(
                meeting, points: side == 1 ? (match.one.points, match.two.points) : (match.two.points, match.one.points)
            )
            meetings.append(meeting)
        }
        return HeadToHead(
            playerOneID: one, playerTwoID: two,
            playerOneName: PlayedMatch.latestName(of: one, in: played) ?? one,
            playerTwoName: PlayedMatch.latestName(of: two, in: played) ?? two,
            playerOneWins: tally.oneWins, playerTwoWins: tally.twoWins, draws: tally.draws,
            matchesPlayed: meetings.count, playerOneGames: tally.oneGames, playerTwoGames: tally.twoGames,
            playerOnePoints: tally.onePoints, playerTwoPoints: tally.twoPoints, meetings: meetings)
    }

    /// The meetings the filter keeps, newest first: all of them, or only those one player won.
    func meetings(_ filter: HeadToHeadFilter) -> [HeadToHeadMeeting] {
        switch filter {
        case .all: meetings
        case .playerOneWon: meetings.filter { $0.winner == 1 }
        case .playerTwoWon: meetings.filter { $0.winner == 2 }
        }
    }

    /// Running totals while the meetings are collected.
    private struct Tally {
        var oneWins = 0
        var twoWins = 0
        var draws = 0
        var oneGames = 0
        var twoGames = 0
        var onePoints = 0
        var twoPoints = 0

        mutating func add(_ meeting: HeadToHeadMeeting, points: (one: Int, two: Int)) {
            switch meeting.winner {
            case 1: oneWins += 1
            case 2: twoWins += 1
            default: draws += 1
            }
            oneGames += meeting.playerOneGames
            twoGames += meeting.playerTwoGames
            onePoints += points.one
            twoPoints += points.two
        }
    }
}

/// Which meetings a head-to-head list shows: "the matches where Y beat Z" is one tap.
nonisolated enum HeadToHeadFilter: Hashable, Sendable, CaseIterable {
    case all, playerOneWon, playerTwoWon
}

/// One match between a head-to-head's players, seen from the record's sides (side 1 is its player one).
nonisolated struct HeadToHeadMeeting: Equatable, Sendable, Identifiable {
    /// The match's id (`MatchResult.id`).
    let id: UUID
    /// Position in the history (oldest first): `MatchDetailView`'s match number is this + 1.
    let historyIndex: Int
    let timestamp: Date
    let playerOneGames: Int
    let playerTwoGames: Int
    /// 1 or 2 from the record's sides, or `MatchResult.noWinner`.
    let winner: Int
    let highlightCount: Int

    init(_ match: PlayedMatch, seenFrom side: Int) {
        id = match.matchID
        historyIndex = match.historyIndex
        timestamp = match.timestamp
        highlightCount = match.highlightCount
        let swapped = side == 2
        playerOneGames = swapped ? match.two.games : match.one.games
        playerTwoGames = swapped ? match.one.games : match.two.games
        switch match.winner {
        case 1: winner = swapped ? 2 : 1
        case 2: winner = swapped ? 1 : 2
        default: winner = MatchResult.noWinner
        }
    }
}
