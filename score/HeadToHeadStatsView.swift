//
//  HeadToHeadStatsView.swift
//  score
//
//  Two players' record against each other as list sections: wins each way with a proportional bar, matches
//  without a winner, games and points won each way, then their matches newest first with a filter by winner
//  ("All / A won / B won", the one-tap answer to "the matches where B beat A"). Shown on the Stats page for the
//  chosen pair and as a page of its own from a player's opponents. Player one is blue, player two red, as on
//  the home screen.
//

import SwiftUI

/// A pair's head-to-head as a page (from a player's opponent row).
struct HeadToHeadStatsView: View {
    let record: HeadToHead

    var body: some View {
        List {
            HeadToHeadSections(record: record, showsTitle: false) {}
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("\(record.playerOneName) vs \(record.playerTwoName)"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The comparison section (after `choice`, the rows choosing the players, if any) and the filtered matches section.
struct HeadToHeadSections<Choice: View>: View {
    let record: HeadToHead
    /// Titles the comparison "Head to Head" (on the Stats page; a pair's own page has the names as its title).
    let showsTitle: Bool
    @ViewBuilder let choice: Choice
    @State private var filter = HeadToHeadFilter.all

    var body: some View {
        Section {
            choice
            HeadToHeadComparison(record: record)
        } header: {
            if showsTitle {
                Text("Head to Head")
            }
        }
        Section {
            let meetings = record.meetings(filter)
            if meetings.isEmpty {
                NoMeetingsRow(record: record, filter: filter)
            }
            ForEach(meetings) { meeting in
                NavigationLink(value: StatsRoute.match(meeting.id)) {
                    MeetingRow(
                        playerOneName: record.playerOneName, playerTwoName: record.playerTwoName,
                        playerOneGames: meeting.playerOneGames, playerTwoGames: meeting.playerTwoGames,
                        winner: meeting.winner, date: meeting.timestamp, highlightCount: meeting.highlightCount)
                }
            }
        } header: {
            MeetingFilterPicker(
                filter: $filter, playerOneName: record.playerOneName, playerTwoName: record.playerTwoName)
        }
    }
}

// MARK: - Comparison

/// Wins as the home card shows them, a bar of the share of matches each way, then games and points.
struct HeadToHeadComparison: View {
    let record: HeadToHead

    var body: some View {
        VStack(spacing: 12) {
            VersusScoreboard(
                playerOneName: record.playerOneName, playerOneValue: record.playerOneWins,
                playerTwoName: record.playerTwoName, playerTwoValue: record.playerTwoWins, unit: .wins)
            ShareBar(playerOne: record.playerOneWins, neither: record.draws, playerTwo: record.playerTwoWins)
            HeadToHeadCaption(matches: record.matchesPlayed, undecided: record.draws)
            if record.matchesPlayed > 0 {
                Divider()
                ComparisonRow(
                    title: "Games won", playerOne: record.playerOneGames, playerTwo: record.playerTwoGames)
                if record.playerOnePoints + record.playerTwoPoints > 0 {
                    ComparisonRow(
                        title: "Points won", playerOne: record.playerOnePoints, playerTwo: record.playerTwoPoints)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// A rounded bar split in proportion: player one (blue) leading, neither (grey) and player two (red) trailing.
/// Grey all along when everything is zero. Decorative: the numbers beside it carry the meaning.
struct ShareBar: View {
    let playerOne: Int
    var neither = 0
    let playerTwo: Int

    var body: some View {
        let total = playerOne + neither + playerTwo
        GeometryReader { proxy in
            let segments = [playerOne, neither, playerTwo].count { $0 > 0 }
            let gaps = CGFloat(max(segments - 1, 0)) * 2
            let unit = total > 0 ? (proxy.size.width - gaps) / CGFloat(total) : 0
            HStack(spacing: 2) {
                if total == 0 {
                    Capsule().fill(.quaternary)
                }
                if playerOne > 0 {
                    Capsule().fill(.blue).frame(width: unit * CGFloat(playerOne))
                }
                if neither > 0 {
                    Capsule().fill(.gray.opacity(0.5)).frame(width: unit * CGFloat(neither))
                }
                if playerTwo > 0 {
                    Capsule().fill(.red).frame(width: unit * CGFloat(playerTwo))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// "12  Games won  9" with a thin share bar under it.
struct ComparisonRow: View {
    let title: LocalizedStringKey
    let playerOne: Int
    let playerTwo: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(playerOne, format: .number)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
                Text(playerTwo, format: .number)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.body.weight(.semibold))
            .monospacedDigit()
            ShareBar(playerOne: playerOne, playerTwo: playerTwo)
                .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\(playerOne) to \(playerTwo)"))
    }
}

// MARK: - Matches

/// "All / A won / B won" as a segmented control (a menu at accessibility text sizes, where segments would clip).
struct MeetingFilterPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var filter: HeadToHeadFilter
    let playerOneName: String
    let playerTwoName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matches")
            if dynamicTypeSize.isAccessibilitySize {
                options.pickerStyle(.menu)
            } else {
                options.pickerStyle(.segmented)
            }
        }
        .textCase(nil)
    }

    private var options: some View {
        Picker("Show", selection: $filter) {
            Text("All").tag(HeadToHeadFilter.all)
            Text("\(playerOneName) won").tag(HeadToHeadFilter.playerOneWon)
            Text("\(playerTwoName) won").tag(HeadToHeadFilter.playerTwoWon)
        }
    }
}

/// Why the matches list is empty: the pair never met, or the chosen player never beat the other.
struct NoMeetingsRow: View {
    let record: HeadToHead
    let filter: HeadToHeadFilter

    var body: some View {
        VStack {
            switch filter {
            case .all: Text("\(record.playerOneName) and \(record.playerTwoName) have not played each other yet.")
            case .playerOneWon: Text("\(record.playerOneName) has not beaten \(record.playerTwoName) yet.")
            case .playerTwoWon: Text("\(record.playerTwoName) has not beaten \(record.playerOneName) yet.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// One match between the pair: players (winner in bold), date and highlights, and the games coloured by the winner.
struct MeetingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let playerOneName: String
    let playerTwoName: String
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int
    let date: Date
    let highlightCount: Int

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                MatchPlayersText(playerOneName: playerOneName, playerTwoName: playerTwoName, winner: winner)
                    .lineLimit(2)
                MatchDateText(date: date, highlightCount: highlightCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GamesScoreText(playerOneGames: playerOneGames, playerTwoGames: playerTwoGames, winner: winner)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    /// One sentence with the games in the order it names the players, e.g. "Lucio beat Alex 3 to 2, 9 October 2026".
    private var spokenSummary: Text {
        let date = Text(date, format: .dateTime.day().month(.wide).year())
        let result =
            switch winner {
            case 1: Text("\(playerOneName) beat \(playerTwoName) \(playerOneGames) to \(playerTwoGames)")
            case 2: Text("\(playerTwoName) beat \(playerOneName) \(playerTwoGames) to \(playerOneGames)")
            default: Text("\(playerOneName) and \(playerTwoName), no winner, \(playerOneGames) to \(playerTwoGames)")
            }
        return highlightCount > 0
            ? Text("\(result), \(date), ^[\(highlightCount) highlight](inflect: true)") : Text("\(result), \(date)")
    }
}

/// The match date (with the year), and the highlight count when there are any.
struct MatchDateText: View {
    let date: Date
    let highlightCount: Int

    var body: some View {
        VStack {
            if highlightCount > 0 {
                // Non-breaking spaces keep the separator and the count with the star when the line wraps
                Text(
                    "\(date, format: .dateTime.day().month(.abbreviated).year())\u{00A0}·\u{00A0}\(Text(Image(systemName: "star.fill")).foregroundStyle(.yellow))\u{00A0}\(highlightCount)"
                )
                .accessibilityLabel(
                    Text(
                        "\(date, format: .dateTime.day().month(.wide).year()), ^[\(highlightCount) highlight](inflect: true)"
                    ))
            } else {
                Text(date, format: .dateTime.day().month(.abbreviated).year())
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// "3–1" in the winner's colour (player one blue, player two red, grey without a winner).
struct GamesScoreText: View {
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int

    var body: some View {
        Text("\(playerOneGames)–\(playerTwoGames)")
            .font(.title3.weight(.semibold))
            .fontDesign(.rounded)
            .monospacedDigit()
            .foregroundStyle(winner == 1 ? Color.blue : winner == 2 ? Color.red : Color.secondary)
            .accessibilityLabel(Text("\(playerOneGames) to \(playerTwoGames)"))
    }
}
