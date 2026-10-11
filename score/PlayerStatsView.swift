//
//  PlayerStatsView.swift
//  score
//
//  One player's page: their overall record (win rate, wins and losses, games, points, streak and form), their
//  record against each opponent (a row opens that pair's head-to-head) and their matches, newest first. Also the
//  pieces the leaderboard shares with it: the row, the "W–L(–D)" record and the form marks.
//

import SwiftUI

struct PlayerStatsView: View {
    let player: PlayerRecord
    let opponents: [OpponentRecord]
    let matches: [PlayerMatch]

    var body: some View {
        List {
            PlayerSummarySection(player: player)
            Section("Opponents") {
                ForEach(opponents) { opponent in
                    NavigationLink(value: StatsRoute.headToHead(player.id, opponent.id)) {
                        OpponentRow(opponent: opponent)
                    }
                }
            }
            Section("Matches") {
                ForEach(matches) { match in
                    NavigationLink(value: StatsRoute.match(match.id)) {
                        PlayerMatchRow(match: match)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(player.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Win rate, record and form at a glance, then the totals.
private struct PlayerSummarySection: View {
    let player: PlayerRecord

    var body: some View {
        Section {
            PlayerHeadline(player: player)
            LabeledContent("Matches", value: player.matchesPlayed, format: .number)
            LabeledContent("Won", value: player.wins, format: .number)
            LabeledContent("Lost", value: player.losses, format: .number)
            if player.draws > 0 {
                LabeledContent("Undecided", value: player.draws, format: .number)
            }
            LabeledContent("Games") {
                Text("\(player.gamesWon)–\(player.gamesLost)")
                    .accessibilityLabel(Text("\(player.gamesWon) won, \(player.gamesLost) lost"))
            }
            if player.pointsWon + player.pointsLost > 0 {
                LabeledContent("Points") {
                    Text("\(player.pointsWon)–\(player.pointsLost)")
                        .accessibilityLabel(Text("\(player.pointsWon) won, \(player.pointsLost) lost"))
                }
            }
            if let streak = player.streak {
                LabeledContent("Current Streak") {
                    StreakText(streak: streak)
                }
            }
        }
        .monospacedDigit()
    }
}

/// The win rate large, with the record and form beside it.
private struct PlayerHeadline: View {
    let player: PlayerRecord

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(player.winRate, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text("Win Rate")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                RecordText(wins: player.wins, losses: player.losses, draws: player.draws)
                    .font(.title3.weight(.semibold))
                FormMarks(form: player.form)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "3 wins", "2 losses" or "1 undecided" in a row.
struct StreakText: View {
    let streak: PlayerStreak

    var body: some View {
        switch streak.outcome {
        case .win: Text("^[\(streak.count) win](inflect: true)")
        case .loss: Text("^[\(streak.count) loss](inflect: true)")
        case .draw: Text("\(streak.count) undecided")
        }
    }
}

// MARK: - Rows

/// Rank, name, record, win rate and form.
struct LeaderboardRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let rank: Int
    let player: PlayerRecord

    var body: some View {
        // At accessibility text sizes the win rate and form go under the name instead of squeezing it
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(rank, format: .number)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .leading)
                .accessibilityLabel(Text("Rank \(rank)"))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    RecordText(wins: player.wins, losses: player.losses, draws: player.draws)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    Text(player.winRate, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .accessibilityLabel(
                            Text("Win rate \(player.winRate, format: .percent.precision(.fractionLength(0)))"))
                    FormMarks(form: player.form)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An opponent's name with the player's record and win rate against them.
private struct OpponentRow: View {
    let opponent: OpponentRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(opponent.name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                RecordText(wins: opponent.wins, losses: opponent.losses, draws: opponent.draws)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(opponent.winRate, format: .percent.precision(.fractionLength(0)))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel(
                    Text("Win rate \(opponent.winRate, format: .percent.precision(.fractionLength(0)))"))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One of the player's matches: the opponent, date, result badge and games from the player's side.
private struct PlayerMatchRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let match: PlayerMatch

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("vs \(match.opponentName)")
                    .lineLimit(2)
                MatchDateText(date: match.timestamp, highlightCount: match.highlightCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                OutcomeBadge(outcome: match.outcome)
                Text("\(match.gamesWon)–\(match.gamesLost)")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(match.gamesWon) to \(match.gamesLost)"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pieces

/// "Won", "Lost" or "No winner" on a tinted capsule.
struct OutcomeBadge: View {
    let outcome: MatchOutcome

    var body: some View {
        Text(outcome.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(outcome.tint)
            .background(outcome.tint.opacity(0.15), in: .capsule)
    }
}

/// Wins–losses, with the undecided matches as a third number when there are any; spoken in full.
struct RecordText: View {
    let wins: Int
    let losses: Int
    let draws: Int

    var body: some View {
        VStack {
            if draws > 0 {
                Text("\(wins)–\(losses)–\(draws)")
                    .accessibilityLabel(
                        Text(
                            "^[\(wins) win](inflect: true), ^[\(losses) loss](inflect: true), \(draws) undecided"))
            } else {
                Text("\(wins)–\(losses)")
                    .accessibilityLabel(Text("^[\(wins) win](inflect: true), ^[\(losses) loss](inflect: true)"))
            }
        }
        .monospacedDigit()
    }
}

/// The last five results as marks, oldest first: a tick for a win, a cross for a loss, a dash for no winner,
/// coloured too but readable without colour.
struct FormMarks: View {
    let form: [MatchOutcome]

    var body: some View {
        // One Text, so the marks scale with Dynamic Type and read as one element
        let marks = form.reduce(nil as Text?) { text, outcome in
            let mark = Text(Image(systemName: outcome.symbol)).foregroundStyle(outcome.tint)
            return text.map { Text("\($0)\u{2009}\(mark)") } ?? mark
        }
        (marks ?? Text(verbatim: ""))
            .font(.caption)
            .accessibilityLabel(
                Text("Last \(form.count): \(form.map { String(localized: $0.title) }.formatted(.list(type: .and)))"))
    }
}

extension MatchOutcome {
    var title: LocalizedStringResource {
        switch self {
        case .win: "Won"
        case .loss: "Lost"
        case .draw: "No winner"
        }
    }

    var symbol: String {
        switch self {
        case .win: "checkmark.circle.fill"
        case .loss: "xmark.circle.fill"
        case .draw: "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .win: .green
        case .loss: .red
        case .draw: .gray
        }
    }
}
