//
//  HeadToHead.swift
//  score
//
//  Head-to-head record of the two players of the most recent finished match, across every match between them.
//  Players are recognised the way the AI summary's previous meetings are (`MatchPlayers.names`/`key`, the
//  `previousMeetings` extension in AI/MatchSummaryModels.swift).
//

import Foundation

nonisolated struct HeadToHead: Equatable, Sendable {
    /// Player one of the most recent match, trimmed.
    let playerOneName: String
    /// Player two of the most recent match, trimmed.
    let playerTwoName: String
    let playerOneWins: Int
    let playerTwoWins: Int
    /// Matches between the two that ended without a winner (`MatchResult.noWinner`).
    let draws: Int
    /// Every match between the two, in either order: wins + draws.
    let matchesPlayed: Int

    /// The record for the players of the last match in `history` (oldest first). Names are compared trimmed and
    /// case-insensitively, in either order; a match whose names are missing (and not in its "A vs B - date" match
    /// name either) belongs to no pair. Nil for an empty history or when the last match has no usable names.
    static func from(history: [MatchResult]) -> HeadToHead? {
        guard let latest = history.last, let names = MatchPlayers.names(of: latest) else { return nil }
        let one = MatchPlayers.key(names.playerOne)
        let two = MatchPlayers.key(names.playerTwo)
        var oneWins = 0
        var twoWins = 0
        var draws = 0
        var played = 0

        for match in history {
            guard let matchNames = MatchPlayers.names(of: match) else { continue }
            let first = MatchPlayers.key(matchNames.playerOne)
            let second = MatchPlayers.key(matchNames.playerTwo)
            let sameOrder = first == one && second == two
            guard sameOrder || (first == two && second == one) else { continue }
            played += 1
            switch match.winner {
            case 1: if sameOrder { oneWins += 1 } else { twoWins += 1 }
            case 2: if sameOrder { twoWins += 1 } else { oneWins += 1 }
            default: draws += 1
            }
        }

        return HeadToHead(
            playerOneName: names.playerOne.trimmingCharacters(in: .whitespacesAndNewlines),
            playerTwoName: names.playerTwo.trimmingCharacters(in: .whitespacesAndNewlines),
            playerOneWins: oneWins,
            playerTwoWins: twoWins,
            draws: draws,
            matchesPlayed: played
        )
    }
}
