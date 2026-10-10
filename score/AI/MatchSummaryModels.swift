//
//  MatchSummaryModels.swift
//  score
//
//  Generable types for AI-powered match summaries using Foundation Models framework, the
//  Codable cache, and the pure pieces that turn match history into a prompt: player-name
//  resolution, head-to-head matching (either side order) and prompt-safe names.
//

import Foundation
import FoundationModels

// MARK: - Match Summary Output

@Generable(description: "A summary of a table tennis match between two players")
struct MatchSummary {
    @Guide(description: "A catchy headline for the match result in 5-10 words")
    var headline: String

    @Guide(description: "A 2-3 sentence narrative summary of how the match unfolded")
    var narrative: String

    @Guide(description: "Key performance insights about the winner")
    var winnerInsights: String

    @Guide(description: "Notable moments or turning points in the match")
    var keyMoments: String

    @Guide(description: "Fun or interesting observation about the match")
    var funFact: String
}

// MARK: - Head-to-Head Analysis

@Generable(description: "Analysis of the rivalry between two players based on their match history")
struct RivalryAnalysis {
    @Guide(description: "Description of the overall rivalry and who dominates")
    var rivalryOverview: String

    @Guide(description: "Trend observation about recent matches")
    var recentTrend: String

    @Guide(description: "Prediction or commentary for future matches")
    var lookAhead: String
}

// MARK: - Complete AI Summary

@Generable(description: "Complete AI-generated analysis of a match including rivalry context")
struct MatchAnalysis {
    @Guide(description: "Summary of the current match")
    var matchSummary: MatchSummary

    @Guide(description: "Analysis of the head-to-head rivalry if players have history")
    var rivalryAnalysis: RivalryAnalysis?
}

// MARK: - Codable Wrappers for Persistence

// Codable version for database storage (StoredMatch.aiSummaryData)
struct MatchAnalysisCodable: Codable {
    let headline: String
    let narrative: String
    let winnerInsights: String
    let keyMoments: String
    let funFact: String
    let rivalryOverview: String?
    let recentTrend: String?
    let lookAhead: String?

    init(from analysis: MatchAnalysis) {
        self.headline = analysis.matchSummary.headline
        self.narrative = analysis.matchSummary.narrative
        self.winnerInsights = analysis.matchSummary.winnerInsights
        self.keyMoments = analysis.matchSummary.keyMoments
        self.funFact = analysis.matchSummary.funFact
        self.rivalryOverview = analysis.rivalryAnalysis?.rivalryOverview
        self.recentTrend = analysis.rivalryAnalysis?.recentTrend
        self.lookAhead = analysis.rivalryAnalysis?.lookAhead
    }

    func toMatchAnalysis() -> MatchAnalysis {
        let rivalry = rivalryOverview.map { overview in
            RivalryAnalysis(
                rivalryOverview: overview,
                recentTrend: recentTrend ?? "",
                lookAhead: lookAhead ?? ""
            )
        }

        return MatchAnalysis(
            matchSummary: MatchSummary(
                headline: headline,
                narrative: narrative,
                winnerInsights: winnerInsights,
                keyMoments: keyMoments,
                funFact: funFact
            ),
            rivalryAnalysis: rivalry
        )
    }
}

// MARK: - Player Names

nonisolated enum MatchPlayers {
    /// Longest player name, in characters, that is put into a prompt.
    static let maxPromptNameLength = 40

    /// Display names of a match's players: the stored `playerOneName`/`playerTwoName`, falling back
    /// to parsing the "A vs B - <date>" match name only for a name that is missing. Nil when a name
    /// cannot be found either way. Names are returned as typed (not sanitised).
    static func names(of match: MatchResult) -> (playerOne: String, playerTwo: String)? {
        let parsed = match.name.flatMap(parse(matchName:))
        guard let playerOne = nonBlank(match.playerOneName) ?? parsed?.playerOne,
            let playerTwo = nonBlank(match.playerTwoName) ?? parsed?.playerTwo
        else { return nil }
        return (playerOne, playerTwo)
    }

    /// Splits "A vs B - <date>" (or a bare "A vs B") into its two trimmed player names.
    static func parse(matchName: String) -> (playerOne: String, playerTwo: String)? {
        guard let separator = matchName.range(of: " vs ") else { return nil }
        var second = matchName[separator.upperBound...]
        if let dateSeparator = second.range(of: " - ", options: .backwards) {
            second = second[..<dateSeparator.lowerBound]
        }
        let playerOne = matchName[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let playerTwo = second.trimmingCharacters(in: .whitespaces)
        guard !playerOne.isEmpty, !playerTwo.isEmpty else { return nil }
        return (playerOne, playerTwo)
    }

    /// Identity used to recognise the same player across matches: trimmed and case-insensitive.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A user-entered name made safe to interpolate into a prompt: whitespace (including newlines)
    /// collapses to single spaces, control and bidi-override characters are removed, and the result
    /// is capped at `maxPromptNameLength` characters. Only for prompts; display names stay as typed.
    static func sanitizedForPrompt(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control && !scalar.properties.isBidiControl {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxPromptNameLength)).trimmingCharacters(in: .whitespaces)
    }

    private static func nonBlank(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}

// MARK: - Head-to-Head History

/// A previous meeting seen from the current match's sides: side 1 is the current match's player one,
/// whichever side that player was on at the time.
nonisolated struct PreviousMeeting: Equatable, Sendable {
    let timestamp: Date
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int  // 1, 2 or MatchResult.noWinner, relative to the current match's sides
}

nonisolated enum HeadToHead {
    /// Earlier matches between the same two players (the trimmed, case-insensitive name pair, in
    /// either order), newest first, with swapped-side meetings flipped onto `match`'s sides.
    /// `match` itself (by id) and matches that finished after it are excluded.
    static func previousMeetings(for match: MatchResult, in history: [MatchResult]) -> [PreviousMeeting] {
        guard let names = MatchPlayers.names(of: match) else { return [] }
        let one = MatchPlayers.key(names.playerOne)
        let two = MatchPlayers.key(names.playerTwo)

        return
            history
            .filter { $0.id != match.id && $0.timestamp < match.timestamp }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { previous in
                guard let previousNames = MatchPlayers.names(of: previous) else { return nil }
                let previousOne = MatchPlayers.key(previousNames.playerOne)
                let previousTwo = MatchPlayers.key(previousNames.playerTwo)
                if previousOne == one && previousTwo == two {
                    return meeting(previous, swapped: false)
                }
                if previousOne == two && previousTwo == one {
                    return meeting(previous, swapped: true)
                }
                return nil
            }
    }

    /// `match` as a meeting; `swapped` flips its sides (games and winner).
    static func meeting(_ match: MatchResult, swapped: Bool) -> PreviousMeeting {
        guard swapped else {
            return PreviousMeeting(
                timestamp: match.timestamp, playerOneGames: match.playerOneGames,
                playerTwoGames: match.playerTwoGames, winner: match.winner)
        }
        let winner: Int
        switch match.winner {
        case 1: winner = 2
        case 2: winner = 1
        default: winner = MatchResult.noWinner
        }
        return PreviousMeeting(
            timestamp: match.timestamp, playerOneGames: match.playerTwoGames,
            playerTwoGames: match.playerOneGames, winner: winner)
    }
}

/// Win tally over a set of meetings.
nonisolated struct HeadToHeadRecord: Equatable, Sendable {
    private(set) var playerOneWins = 0
    private(set) var playerTwoWins = 0
    private(set) var withoutWinner = 0

    init(meetings: [PreviousMeeting]) {
        for meeting in meetings {
            switch meeting.winner {
            case 1: playerOneWins += 1
            case 2: playerTwoWins += 1
            default: withoutWinner += 1
            }
        }
    }
}

// MARK: - Match Context for Prompting

nonisolated struct MatchContext: Sendable {
    /// How many previous meetings the prompt lists; the head-to-head record covers all of them.
    static let listedMeetings = 5

    /// Prompt-safe names (see `MatchPlayers.sanitizedForPrompt`).
    let playerOneName: String
    let playerTwoName: String
    let winner: Int
    let playerOneGames: Int
    let playerTwoGames: Int
    let games: [GameResult]
    let duration: TimeInterval?
    /// Every previous meeting, most recent first, on this match's sides.
    let previousMatches: [PreviousMeeting]

    init(
        playerOneName: String, playerTwoName: String, winner: Int, playerOneGames: Int, playerTwoGames: Int,
        games: [GameResult], duration: TimeInterval?, previousMatches: [PreviousMeeting]
    ) {
        let one = MatchPlayers.sanitizedForPrompt(playerOneName)
        let two = MatchPlayers.sanitizedForPrompt(playerTwoName)
        self.playerOneName = one.isEmpty ? "Player 1" : one
        self.playerTwoName = two.isEmpty ? "Player 2" : two
        self.winner = winner
        self.playerOneGames = playerOneGames
        self.playerTwoGames = playerTwoGames
        self.games = games
        self.duration = duration
        self.previousMatches = previousMatches
    }

    /// Context for `match`, with its head-to-head history drawn from `history`; nil without player names.
    init?(match: MatchResult, history: [MatchResult]) {
        guard let names = MatchPlayers.names(of: match) else { return nil }
        self.init(
            playerOneName: names.playerOne, playerTwoName: names.playerTwo, winner: match.winner,
            playerOneGames: match.playerOneGames, playerTwoGames: match.playerTwoGames, games: match.games,
            duration: match.duration, previousMatches: HeadToHead.previousMeetings(for: match, in: history))
    }

    var winnerName: String {
        winner == 1 ? playerOneName : playerTwoName
    }

    var loserName: String {
        winner == 1 ? playerTwoName : playerOneName
    }

    var winnerGames: Int {
        winner == 1 ? playerOneGames : playerTwoGames
    }

    var loserGames: Int {
        winner == 1 ? playerTwoGames : playerOneGames
    }

    func buildPrompt() -> String {
        let result = winner == 1 || winner == 2 ? winnerName : "none (the match ended without a winner)"
        var prompt = """
            Generate a match summary for this table tennis match:

            Players: \(playerOneName) vs \(playerTwoName)
            Final Score: \(playerOneName) \(playerOneGames) - \(playerTwoGames) \(playerTwoName)
            Winner: \(result)

            Game-by-game breakdown:
            """

        for (index, game) in games.enumerated() {
            let gameWinner = game.winner == 1 ? playerOneName : playerTwoName
            prompt += "\nGame \(index + 1): \(game.playerOneScore)-\(game.playerTwoScore) (\(gameWinner) wins)"
            if let gameDuration = game.duration {
                prompt += " - Duration: \(formatDuration(gameDuration))"
            }
        }

        if let matchDuration = duration {
            prompt += "\n\nTotal match duration: \(formatDuration(matchDuration))"
        }

        if previousMatches.isEmpty {
            prompt += "\n\nThis is the first recorded match between these players."
        } else {
            prompt += historySection()
        }

        return prompt
    }

    private func historySection() -> String {
        var section = "\n\nPrevious matches between these players (most recent first):"
        for meeting in previousMatches.prefix(Self.listedMeetings) {
            let outcome: String
            switch meeting.winner {
            case 1: outcome = "Winner: \(playerOneName)"
            case 2: outcome = "Winner: \(playerTwoName)"
            default: outcome = "No winner"
            }
            section +=
                "\n- \(playerOneName) \(meeting.playerOneGames)-\(meeting.playerTwoGames) \(playerTwoName) (\(outcome))"
        }
        let unlisted = previousMatches.count - Self.listedMeetings
        if unlisted > 0 {
            section += "\n(\(unlisted) earlier \(unlisted == 1 ? "match" : "matches") not listed)"
        }

        let record = HeadToHeadRecord(meetings: previousMatches)
        section +=
            "\n\nHead-to-head record before this match: "
            + "\(playerOneName) \(record.playerOneWins) - \(record.playerTwoWins) \(playerTwoName)"
        if record.withoutWinner > 0 {
            section += " (\(record.withoutWinner) without a winner)"
        }
        return section
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
