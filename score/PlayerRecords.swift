//
//  PlayerRecords.swift
//  score
//
//  Every player's record over the finished matches, for the Stats pages: a leaderboard, each player's record
//  per opponent and their matches, and head-to-head between any two players (`HeadToHead`, HeadToHead.swift).
//  Pure and value-typed. Players are recognised as everywhere else (`MatchPlayers.names(of:)`/`key`: trimmed,
//  case-insensitive, names recovered from the "A vs B - date" match name when missing); a match without two
//  usable names, or with the same player on both sides, counts for nobody. A player is shown as most recently
//  spelled.
//

import Foundation

/// How a match ended for one player. A match without a winner (`MatchResult.noWinner`) is a draw.
nonisolated enum MatchOutcome: Equatable, Sendable {
    case win, loss, draw
}

/// The run of identical results a player is on, e.g. three wins in a row (shown "W3").
nonisolated struct PlayerStreak: Equatable, Sendable {
    let outcome: MatchOutcome
    let count: Int
}

/// One player's overall record.
nonisolated struct PlayerRecord: Equatable, Sendable, Identifiable {
    /// Identity (`MatchPlayers.key`).
    let id: String
    /// The most recent spelling, trimmed.
    let name: String
    let wins: Int
    let losses: Int
    let draws: Int
    let gamesWon: Int
    let gamesLost: Int
    let pointsWon: Int
    let pointsLost: Int
    /// The last five results, oldest first (the newest is last).
    let form: [MatchOutcome]
    /// The current run of identical results; nil only for a player without matches.
    let streak: PlayerStreak?

    var matchesPlayed: Int { wins + losses + draws }

    /// Wins over matches played (a draw counts as played, not won); 0 without matches.
    var winRate: Double {
        matchesPlayed == 0 ? 0 : Double(wins) / Double(matchesPlayed)
    }
}

/// A player's record against one opponent.
nonisolated struct OpponentRecord: Equatable, Sendable, Identifiable {
    /// The opponent's identity (`MatchPlayers.key`).
    let id: String
    let name: String
    let wins: Int
    let losses: Int
    let draws: Int

    var matchesPlayed: Int { wins + losses + draws }
    var winRate: Double { matchesPlayed == 0 ? 0 : Double(wins) / Double(matchesPlayed) }
}

/// One of a player's matches, from their side.
nonisolated struct PlayerMatch: Equatable, Sendable, Identifiable {
    /// The match's id (`MatchResult.id`).
    let id: UUID
    /// Position in the history (oldest first): `MatchDetailView`'s match number is this + 1.
    let historyIndex: Int
    let timestamp: Date
    let opponentID: String
    let opponentName: String
    let gamesWon: Int
    let gamesLost: Int
    let outcome: MatchOutcome
    let highlightCount: Int
}

/// A finished match with both players resolved; the unit every record is computed from.
nonisolated struct PlayedMatch: Equatable, Sendable {
    /// One player's side of the match.
    struct Side: Equatable, Sendable {
        let id: String
        let name: String
        let games: Int
        /// Points won across the recorded games.
        let points: Int
    }

    let matchID: UUID
    let historyIndex: Int
    let timestamp: Date
    let one: Side
    let two: Side
    /// 1, 2 or `MatchResult.noWinner`.
    let winner: Int
    let highlightCount: Int

    /// The matches of `history` (oldest first) that have two different players, in the same order.
    static func all(in history: [MatchResult]) -> [PlayedMatch] {
        history.enumerated().compactMap { index, match in
            guard let names = MatchPlayers.names(of: match) else { return nil }
            let one = MatchPlayers.key(names.playerOne)
            let two = MatchPlayers.key(names.playerTwo)
            guard !one.isEmpty, !two.isEmpty, one != two else { return nil }
            let trim = { (name: String) in name.trimmingCharacters(in: .whitespacesAndNewlines) }
            return PlayedMatch(
                matchID: match.id, historyIndex: index, timestamp: match.timestamp,
                one: Side(
                    id: one, name: trim(names.playerOne), games: match.playerOneGames,
                    points: match.games.reduce(0) { $0 + $1.playerOneScore }),
                two: Side(
                    id: two, name: trim(names.playerTwo), games: match.playerTwoGames,
                    points: match.games.reduce(0) { $0 + $1.playerTwoScore }),
                winner: match.hasWinner ? match.winner : MatchResult.noWinner,
                highlightCount: match.highlightCount)
        }
    }

    /// The most recent spelling of the player `id` in `played` (oldest first).
    static func latestName(of id: String, in played: [PlayedMatch]) -> String? {
        for match in played.reversed() {
            if match.one.id == id { return match.one.name }
            if match.two.id == id { return match.two.name }
        }
        return nil
    }

    /// 1 or 2 for the side `id` played on, nil when they did not play.
    func side(of id: String) -> Int? {
        if one.id == id { return 1 }
        if two.id == id { return 2 }
        return nil
    }

    /// How the match ended for side 1 or 2.
    func outcome(forSide side: Int) -> MatchOutcome {
        switch winner {
        case side: .win
        case 1, 2: .loss
        default: .draw
        }
    }

    /// Side 1 or 2 as `(self, opponent)`.
    func sides(from side: Int) -> (player: Side, opponent: Side) {
        side == 1 ? (one, two) : (two, one)
    }
}

/// Every player's record over a history; the Stats pages' model.
nonisolated struct PlayerRecords: Equatable, Sendable {
    /// How many results `PlayerRecord.form` keeps.
    static let formLength = 5

    /// Every resolved match, oldest first.
    let played: [PlayedMatch]
    /// Every player, best first: win rate, then wins, then fewer losses, then name. One match is enough to appear.
    let leaderboard: [PlayerRecord]

    /// Each player's most recent spelling, by identity.
    private let names: [String: String]

    init(history: [MatchResult]) {
        let played = PlayedMatch.all(in: history)
        var ids: [String] = []
        var names: [String: String] = [:]
        for match in played {
            for side in [match.one, match.two] {
                if names[side.id] == nil { ids.append(side.id) }
                names[side.id] = side.name
            }
        }
        self.played = played
        self.names = names
        leaderboard = ids.map { Self.record(of: $0, named: names[$0] ?? $0, in: played) }.sorted(by: Self.ranksAbove)
    }

    /// The two players of the most recent resolved match, as (player one, player two) identities.
    var latestPair: (playerOne: String, playerTwo: String)? {
        played.last.map { ($0.one.id, $0.two.id) }
    }

    func player(_ id: String) -> PlayerRecord? {
        leaderboard.first { $0.id == id }
    }

    /// `HeadToHead` of two players by identity, `playerOne` as side one; nil for a blank or identical pair.
    func headToHead(_ playerOne: String, _ playerTwo: String) -> HeadToHead? {
        HeadToHead.between(playerOne, playerTwo, in: played)
    }

    /// The player's matches, newest first.
    func matches(of id: String) -> [PlayerMatch] {
        played.reversed().compactMap { match in
            guard let side = match.side(of: id) else { return nil }
            let (player, opponent) = match.sides(from: side)
            return PlayerMatch(
                id: match.matchID, historyIndex: match.historyIndex, timestamp: match.timestamp,
                opponentID: opponent.id, opponentName: name(of: opponent.id), gamesWon: player.games,
                gamesLost: opponent.games, outcome: match.outcome(forSide: side), highlightCount: match.highlightCount)
        }
    }

    /// The player's record against each opponent: most matches played first, then by name.
    func opponents(of id: String) -> [OpponentRecord] {
        var order: [String] = []
        var tallies: [String: (wins: Int, losses: Int, draws: Int)] = [:]
        for match in matches(of: id) {
            if tallies[match.opponentID] == nil { order.append(match.opponentID) }
            var tally = tallies[match.opponentID] ?? (0, 0, 0)
            switch match.outcome {
            case .win: tally.wins += 1
            case .loss: tally.losses += 1
            case .draw: tally.draws += 1
            }
            tallies[match.opponentID] = tally
        }
        return order.compactMap { opponent in
            guard let tally = tallies[opponent] else { return nil }
            return OpponentRecord(
                id: opponent, name: name(of: opponent), wins: tally.wins, losses: tally.losses,
                draws: tally.draws)
        }
        .sorted {
            $0.matchesPlayed != $1.matchesPlayed
                ? $0.matchesPlayed > $1.matchesPlayed
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Building

    /// The player's most recent spelling.
    func name(of id: String) -> String {
        names[id] ?? id
    }

    private static func record(of id: String, named name: String, in played: [PlayedMatch]) -> PlayerRecord {
        var outcomes: [MatchOutcome] = []
        var games = (won: 0, lost: 0)
        var points = (won: 0, lost: 0)
        for match in played {
            guard let side = match.side(of: id) else { continue }
            let (player, opponent) = match.sides(from: side)
            outcomes.append(match.outcome(forSide: side))
            games.won += player.games
            games.lost += opponent.games
            points.won += player.points
            points.lost += opponent.points
        }
        return PlayerRecord(
            id: id, name: name, wins: outcomes.count { $0 == .win },
            losses: outcomes.count { $0 == .loss }, draws: outcomes.count { $0 == .draw }, gamesWon: games.won,
            gamesLost: games.lost, pointsWon: points.won, pointsLost: points.lost,
            form: Array(outcomes.suffix(formLength)), streak: streak(of: outcomes))
    }

    /// The run of identical results at the end of `outcomes` (oldest first).
    static func streak(of outcomes: [MatchOutcome]) -> PlayerStreak? {
        guard let last = outcomes.last else { return nil }
        let count = outcomes.reversed().prefix { $0 == last }.count
        return PlayerStreak(outcome: last, count: count)
    }

    /// Leaderboard order: higher win rate, more wins, fewer losses, then name (and identity, so it is total).
    static func ranksAbove(_ lhs: PlayerRecord, _ rhs: PlayerRecord) -> Bool {
        if lhs.winRate != rhs.winRate { return lhs.winRate > rhs.winRate }
        if lhs.wins != rhs.wins { return lhs.wins > rhs.wins }
        if lhs.losses != rhs.losses { return lhs.losses < rhs.losses }
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id < rhs.id
    }
}
