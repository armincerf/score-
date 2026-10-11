//
//  HomeSections.swift
//  score
//
//  The home screen's sections: the empty state, the dashboard of cards (live match or head-to-head, recent
//  matches, Apple Watch status) and the floating New Match button. Each takes only the values it shows.
//

import SwiftUI
import UIKit

// MARK: - Inputs

/// The live match as the home screen shows it (a narrow copy of `ScoreState`).
nonisolated struct ActiveMatchSummary: Equatable, Sendable {
    let playerOneName: String
    let playerTwoName: String
    let playerOneGames: Int
    let playerTwoGames: Int
    let playerOneScore: Int
    let playerTwoScore: Int
    let startedAt: Date?

    init(_ state: ScoreState) {
        playerOneName = state.playerOneName ?? String(localized: "Player 1")
        playerTwoName = state.playerTwoName ?? String(localized: "Player 2")
        playerOneGames = state.playerOneGames
        playerTwoGames = state.playerTwoGames
        playerOneScore = state.playerOneScore
        playerTwoScore = state.playerTwoScore
        startedAt = state.recordingStartTime
    }

    var gameNumber: Int { playerOneGames + playerTwoGames + 1 }
}

/// Apple Watch connection as the home screen shows it.
nonisolated enum WatchStatus: Equatable, Sendable {
    case connected, notReachable, notInstalled

    init(isInstalled: Bool, isReachable: Bool) {
        if !isInstalled {
            self = .notInstalled
        } else {
            self = isReachable ? .connected : .notReachable
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .connected: "Connected"
        case .notReachable: "Not Reachable"
        case .notInstalled: "Not Installed"
        }
    }
}

/// How a recent match's date reads, as in Mail and Messages: the time today, "Yesterday", the weekday within the
/// last week, then day and month (with the year once it is not this year's).
nonisolated enum RecentDateStyle: Equatable, Sendable {
    case time, yesterday, weekday, dayMonth, dayMonthYear

    init(date: Date, now: Date, calendar: Calendar) {
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        switch days {
        case 0: self = .time
        case 1: self = .yesterday
        case 2...6: self = .weekday
        default:
            self = calendar.isDate(date, equalTo: now, toGranularity: .year) ? .dayMonth : .dayMonthYear
        }
    }
}

// MARK: - Layout

/// Empty state or dashboard, depending on whether there is anything to show.
struct HomeContent: View {
    let history: [MatchResult]
    let activeMatch: ActiveMatchSummary?
    let watchStatus: WatchStatus
    let onResume: () -> Void

    var body: some View {
        if history.isEmpty && activeMatch == nil {
            EmptyHome(watchStatus: watchStatus)
        } else {
            HomeDashboard(history: history, activeMatch: activeMatch, watchStatus: watchStatus, onResume: onResume)
        }
    }
}

/// No matches yet: an explanation above the floating New Match button, with the watch status as a footer.
struct EmptyHome: View {
    let watchStatus: WatchStatus

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No Matches Yet", systemImage: "figure.table.tennis")
            } description: {
                Text("Tap New Match to record your first game. Scores, highlights and video are kept here.")
            }
            WatchStatusCard(status: watchStatus)
        }
        .padding([.horizontal, .bottom])
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// Hero card (live match, otherwise head-to-head), recent matches and the watch status.
struct HomeDashboard: View {
    let history: [MatchResult]
    let activeMatch: ActiveMatchSummary?
    let watchStatus: WatchStatus
    let onResume: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let activeMatch {
                    ActiveMatchCard(match: activeMatch, onResume: onResume)
                } else if let record = HeadToHead.from(history: history) {
                    HeadToHeadCard(record: record)
                }
                if !history.isEmpty {
                    RecentMatchesCard(history: history)
                }
                WatchStatusCard(status: watchStatus)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// The screen's one primary action, floating in the bottom bar.
struct NewMatchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("New Match", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Cards

/// The live match: both players' games, the current game score and elapsed time. Tapping it resumes the match.
struct ActiveMatchCard: View {
    let match: ActiveMatchSummary
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Live", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Spacer()
                    if let start = match.startedAt {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    DisclosureChevron()
                }
                VersusScoreboard(
                    playerOneName: match.playerOneName, playerOneValue: match.playerOneGames,
                    playerTwoName: match.playerTwoName, playerTwoValue: match.playerTwoGames, unit: .games)
                Text("Game \(match.gameNumber): \(match.playerOneScore)–\(match.playerTwoScore)")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        Text("Game \(match.gameNumber), \(match.playerOneScore) to \(match.playerTwoScore)"))
            }
            .dashboardCard()
            .contentShape(.rect(cornerRadius: DashboardCard.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Resumes the match"))
    }
}

/// Wins of the most recent match's players against each other.
struct HeadToHeadCard: View {
    let record: HeadToHead

    var body: some View {
        VStack(spacing: 12) {
            Text("Head to Head")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            VersusScoreboard(
                playerOneName: record.playerOneName, playerOneValue: record.playerOneWins,
                playerTwoName: record.playerTwoName, playerTwoValue: record.playerTwoWins, unit: .wins)
            HeadToHeadCaption(matches: record.matchesPlayed, draws: record.draws)
        }
        .dashboardCard()
    }
}

struct HeadToHeadCaption: View {
    let matches: Int
    let draws: Int

    var body: some View {
        VStack {
            if draws > 0 {
                Text("^[\(matches) match](inflect: true) played · ^[\(draws) draw](inflect: true)")
            } else {
                Text("^[\(matches) match](inflect: true) played")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}

/// The three most recent finished matches, newest first, with a link to the full history.
struct RecentMatchesCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The whole history, oldest first: rows open `MatchDetailView` with it, as `MatchHistoryView` does.
    let history: [MatchResult]

    var body: some View {
        // At accessibility text sizes the link sits under the title instead of fighting it for the width
        let headerLayout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: 0) {
            headerLayout {
                Text("Recent")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NavigationLink("All Matches") {
                    MatchHistoryView()
                }
                .font(.subheadline)
            }
            .padding(.bottom, 12)
            ForEach(history.enumerated().suffix(3).reversed(), id: \.element.id) { index, match in
                VStack(spacing: 0) {
                    Divider()
                    NavigationLink {
                        MatchDetailView(match: match, matchNumber: index + 1, allMatches: history)
                    } label: {
                        RecentMatchRow(
                            playerOneName: match.playerOneName ?? String(localized: "Player 1"),
                            playerTwoName: match.playerTwoName ?? String(localized: "Player 2"),
                            playerOneGames: match.playerOneGames, playerTwoGames: match.playerTwoGames,
                            winner: match.winner, date: match.timestamp, highlightCount: match.highlightCount)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .dashboardCard(bottomPadding: 4)  // the last row's own padding completes the inset
    }
}

/// Apple Watch connection, with what the watch app does while it is not installed.
struct WatchStatusCard: View {
    let status: WatchStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(status.title)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Apple Watch", systemImage: "applewatch")
            }
            .dashboardCard()
            if status == .notInstalled {
                Text(
                    "Install Score on your Apple Watch to score points, mark highlights and end games from your wrist."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Pieces

/// One finished match: players (winner in bold), date and highlights, and the games coloured by the winner.
struct RecentMatchRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let playerOneName: String
    let playerTwoName: String
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int
    let date: Date
    let highlightCount: Int

    /// The date as Mail and Messages show it (see `RecentDateStyle`); shared by the visible and spoken text.
    private var dateText: Text {
        switch RecentDateStyle(date: date, now: .now, calendar: .current) {
        case .time: Text(date, format: .dateTime.hour().minute())
        case .yesterday: Text("Yesterday")
        case .weekday: Text(date, format: .dateTime.weekday(.wide))
        case .dayMonth: Text(date, format: .dateTime.day().month(.abbreviated))
        case .dayMonthYear: Text(date, format: .dateTime.day().month(.abbreviated).year())
        }
    }

    private var winnerColor: Color {
        switch winner {
        case 1: .blue
        case 2: .red
        default: .secondary
        }
    }

    var body: some View {
        // At accessibility text sizes the games move under the names, so neither has to wrap or truncate
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        HStack(spacing: 12) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    MatchPlayersText(playerOneName: playerOneName, playerTwoName: playerTwoName, winner: winner)
                        .font(.body)
                    VStack {
                        if highlightCount > 0 {
                            // Non-breaking spaces keep the separator and the count with the star when the line wraps
                            Text(
                                "\(dateText)\u{00A0}·\u{00A0}\(Text(Image(systemName: "star.fill")).foregroundStyle(.yellow))\u{00A0}\(highlightCount)"
                            )
                            .accessibilityLabel(Text("\(dateText), ^[\(highlightCount) highlight](inflect: true)"))
                        } else {
                            dateText
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(playerOneGames)–\(playerTwoGames)")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(winnerColor)
                    .accessibilityLabel(Text("\(playerOneGames) to \(playerTwoGames)"))
            }
            DisclosureChevron()
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// "Alex vs Lucio" with the winner in bold (and spoken as the winner).
struct MatchPlayersText: View {
    let playerOneName: String
    let playerTwoName: String
    let winner: Int

    var body: some View {
        VStack(alignment: .leading) {
            switch winner {
            case 1:
                Text("**\(playerOneName)** vs \(playerTwoName)")
                    .accessibilityLabel(Text("\(playerOneName) beat \(playerTwoName)"))
            case 2:
                Text("\(playerOneName) vs **\(playerTwoName)**")
                    .accessibilityLabel(Text("\(playerTwoName) beat \(playerOneName)"))
            default:
                Text("\(playerOneName) vs \(playerTwoName)")
                    .accessibilityLabel(Text("\(playerOneName) vs \(playerTwoName), no winner"))
            }
        }
    }
}

/// Two players side by side with a large number each: player one leading in blue, player two trailing in red.
struct VersusScoreboard: View {
    enum Unit {
        case games, wins
    }

    let playerOneName: String
    let playerOneValue: Int
    let playerTwoName: String
    let playerTwoValue: Int
    let unit: Unit

    var body: some View {
        // Aligned on the numbers, so they stay level when one name wraps and "vs" sits between them
        HStack(alignment: .scoreNumber, spacing: 8) {
            ScoreColumn(name: playerOneName, value: playerOneValue, tint: .blue, unit: unit)
            Text("vs")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            ScoreColumn(name: playerTwoName, value: playerTwoValue, tint: .red, unit: unit)
        }
    }
}

extension VerticalAlignment {
    private enum ScoreNumber: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    /// The vertical centre of a `ScoreColumn`'s number.
    fileprivate static let scoreNumber = VerticalAlignment(ScoreNumber.self)
}

struct ScoreColumn: View {
    let name: String
    let value: Int
    let tint: Color
    let unit: VersusScoreboard.Unit

    var body: some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(value, format: .number)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(value)))
                .alignmentGuide(.scoreNumber) { $0[VerticalAlignment.center] }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            unit == .games
                ? Text("\(name), ^[\(value) game](inflect: true)")
                : Text("\(name), ^[\(value) win](inflect: true)"))
    }
}

/// Trailing chevron that marks a card row as tappable, like a List disclosure indicator.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Grouped-background card shape shared by every dashboard section.
enum DashboardCard {
    static let cornerRadius: CGFloat = 20
}

extension View {
    /// Pads the content and puts it on a rounded secondary grouped background.
    func dashboardCard(bottomPadding: CGFloat = 16) -> some View {
        padding([.top, .horizontal], 16)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: DashboardCard.cornerRadius, style: .continuous))
    }
}
