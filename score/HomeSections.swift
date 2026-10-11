//
//  HomeSections.swift
//  score
//
//  The home screen's sections: the empty state, the dashboard of cards (active match or head-to-head, recent
//  matches, Apple Watch status) and the floating New Match button. Each takes only the values it shows.
//

import SwiftUI
import UIKit

// MARK: - Inputs

/// The active match as the home screen shows it (a narrow copy of `ScoreState` plus the manager flags it needs).
nonisolated struct ActiveMatchSummary: Equatable, Sendable {
    let playerOneName: String
    let playerTwoName: String
    let playerOneGames: Int
    let playerTwoGames: Int
    let playerOneScore: Int
    let playerTwoScore: Int
    let startedAt: Date?
    /// False once recording stopped but the match could not be saved (it can be opened and ended again).
    let isLive: Bool
    /// True once a game win decided the match; the game screen offers to end it.
    let isDecided: Bool

    init(_ state: ScoreState, isLive: Bool, isDecided: Bool) {
        playerOneName = state.playerOneName ?? String(localized: "Player 1")
        playerTwoName = state.playerTwoName ?? String(localized: "Player 2")
        playerOneGames = state.playerOneGames
        playerTwoGames = state.playerTwoGames
        playerOneScore = state.playerOneScore
        playerTwoScore = state.playerTwoScore
        startedAt = state.recordingStartTime
        self.isLive = isLive
        self.isDecided = isDecided
    }

    var gameNumber: Int { playerOneGames + playerTwoGames + 1 }
}

/// Apple Watch as the home screen shows it. `notPaired` phones get no watch card at all.
nonisolated enum WatchStatus: Equatable, Sendable {
    case notPaired, notInstalled, installed, connected

    init(isPaired: Bool, isInstalled: Bool, isReachable: Bool) {
        if !isPaired {
            self = .notPaired
        } else if !isInstalled {
            self = .notInstalled
        } else {
            self = isReachable ? .connected : .installed
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .connected: "Connected"
        case .installed: "Installed"
        case .notInstalled: "Not Installed"
        case .notPaired: "No Watch"
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
/// Centred when it fits, scrolling (at accessibility text sizes) when it does not.
struct EmptyHome: View {
    let watchStatus: WatchStatus
    @State private var containerHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label("No Matches Yet", systemImage: "figure.table.tennis")
                } description: {
                    Text("Tap New Match to score your first match. Results, highlights and video are kept here.")
                }
                if watchStatus != .notPaired {
                    WatchStatusCard(status: watchStatus)
                }
            }
            .padding([.horizontal, .bottom])
            .frame(maxWidth: .infinity, minHeight: containerHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            containerHeight = $0
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// Hero card (active match, otherwise head-to-head), recent matches and the watch status.
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
                if watchStatus != .notPaired {
                    WatchStatusCard(status: watchStatus)
                }
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

/// The active match: both players' games, the current game score and elapsed time. Tapping it opens the match.
struct ActiveMatchCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let match: ActiveMatchSummary
    let onResume: () -> Void

    var body: some View {
        // At accessibility text sizes the elapsed time goes under the badge instead of squeezing beside it
        let headerLayout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        Button(action: onResume) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    headerLayout {
                        ActiveMatchBadge(isLive: match.isLive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let start = match.startedAt {
                            // The timer icon tells the elapsed time apart from a clock time
                            Label {
                                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: "timer")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Elapsed"))
                            .accessibilityValue(Text(timerInterval: start...Date.distantFuture, countsDown: false))
                        }
                    }
                    DisclosureChevron()
                }
                VersusScoreboard(
                    playerOneName: match.playerOneName, playerOneValue: match.playerOneGames,
                    playerTwoName: match.playerTwoName, playerTwoValue: match.playerTwoGames, unit: .games)
                ActiveMatchFooter(match: match)
            }
            .dashboardCard()
            .contentShape(.rect(cornerRadius: DashboardCard.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(match.isLive ? "Resumes the match" : "Opens the match so it can be ended again"))
    }
}

/// "Live" while recording; "Not Saved" after a failed save, when the match is still open.
struct ActiveMatchBadge: View {
    let isLive: Bool

    var body: some View {
        if isLive {
            Label("Live", systemImage: "record.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        } else {
            Label("Not Saved", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }
}

/// The current game's score, or that the match is already decided and waiting to be ended.
struct ActiveMatchFooter: View {
    let match: ActiveMatchSummary

    var body: some View {
        VStack {
            if match.isDecided {
                Text("Match decided, tap to end it")
            } else {
                Text("Game \(match.gameNumber): \(match.playerOneScore)–\(match.playerTwoScore)")
                    .monospacedDigit()
                    .accessibilityLabel(
                        Text("Game \(match.gameNumber), \(match.playerOneScore) to \(match.playerTwoScore)"))
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
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
                .accessibilityAddTraits(.isHeader)
            VersusScoreboard(
                playerOneName: record.playerOneName, playerOneValue: record.playerOneWins,
                playerTwoName: record.playerTwoName, playerTwoValue: record.playerTwoWins, unit: .wins)
            HeadToHeadCaption(matches: record.matchesPlayed, undecided: record.draws)
        }
        .dashboardCard()
    }
}

struct HeadToHeadCaption: View {
    let matches: Int
    let undecided: Int

    var body: some View {
        VStack {
            if undecided > 0 {
                // Non-breaking spaces keep the separator off the start of a wrapped line
                Text("^[\(matches) match](inflect: true) played\u{00A0}·\u{00A0}\(undecided) undecided")
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
    @Environment(\.scenePhase) private var scenePhase
    /// The whole history, oldest first: rows open `MatchDetailView` with it, as `MatchHistoryView` does.
    let history: [MatchResult]
    /// "Today" for the rows' dates; refreshed when the screen appears, comes back to the foreground or changes
    /// content, so a row saved last night does not keep reading as today.
    @State private var now = Date.now

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
                    .accessibilityAddTraits(.isHeader)
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
                            winner: match.winner, date: match.timestamp, highlightCount: match.highlightCount,
                            now: now)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .dashboardCard(bottomPadding: 4)  // the last row's own padding completes the inset
        .onAppear { now = .now }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { now = .now }
        }
        .onChange(of: history.count) { now = .now }
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
                    """
                    Install the watch app from the Watch app on your iPhone to score points, mark highlights and \
                    end games from your wrist.
                    """
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
    @Environment(\.calendar) private var calendar
    let playerOneName: String
    let playerTwoName: String
    let playerOneGames: Int
    let playerTwoGames: Int
    let winner: Int
    let date: Date
    let highlightCount: Int
    let now: Date

    /// The date as Mail and Messages show it (see `RecentDateStyle`); shared by the visible and spoken text.
    private var dateText: Text {
        switch RecentDateStyle(date: date, now: now, calendar: calendar) {
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

    /// One spoken summary with the games in the same order as the sentence, e.g. "Lucio beat Alex 3 to 1".
    private var spokenResult: Text {
        switch winner {
        case 1: Text("\(playerOneName) beat \(playerTwoName) \(playerOneGames) to \(playerTwoGames)")
        case 2: Text("\(playerTwoName) beat \(playerOneName) \(playerTwoGames) to \(playerOneGames)")
        default: Text("\(playerOneName) and \(playerTwoName), no winner, \(playerOneGames) to \(playerTwoGames)")
        }
    }

    private var spokenSummary: Text {
        highlightCount > 0
            ? Text("\(spokenResult), \(dateText), ^[\(highlightCount) highlight](inflect: true)")
            : Text("\(spokenResult), \(dateText)")
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
            }
            DisclosureChevron()
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }
}

/// "Alex vs Lucio" with the winner in bold.
struct MatchPlayersText: View {
    let playerOneName: String
    let playerTwoName: String
    let winner: Int

    var body: some View {
        switch winner {
        case 1: Text("**\(playerOneName)** vs \(playerTwoName)")
        case 2: Text("\(playerOneName) vs **\(playerTwoName)**")
        default: Text("\(playerOneName) vs \(playerTwoName)")
        }
    }
}

/// Two players with a large number each: side by side (player one leading in blue, player two trailing in red),
/// or one line per player at accessibility text sizes so long names never break mid-word.
struct VersusScoreboard: View {
    enum Unit {
        case games, wins
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let playerOneName: String
    let playerOneValue: Int
    let playerTwoName: String
    let playerTwoValue: Int
    let unit: Unit

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                ScoreLine(name: playerOneName, value: playerOneValue, tint: .blue, unit: unit)
                ScoreLine(name: playerTwoName, value: playerTwoValue, tint: .red, unit: unit)
            }
        } else {
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
}

extension VerticalAlignment {
    // nonisolated: a pure layout helper the layout engine may call off the main actor
    nonisolated private enum ScoreNumber: AlignmentID {
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
                .alignmentGuide(.scoreNumber) { $0[VerticalAlignment.center] }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScoreSpeech.label(name: name, value: value, unit: unit))
    }
}

/// Name leading, number trailing: the accessibility-size form of `ScoreColumn`.
struct ScoreLine: View {
    let name: String
    let value: Int
    let tint: Color
    let unit: VersusScoreboard.Unit

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value, format: .number)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ScoreSpeech.label(name: name, value: value, unit: unit))
    }
}

enum ScoreSpeech {
    static func label(name: String, value: Int, unit: VersusScoreboard.Unit) -> Text {
        unit == .games
            ? Text("\(name), ^[\(value) game](inflect: true)")
            : Text("\(name), ^[\(value) win](inflect: true)")
    }
}

/// Trailing chevron that marks a card row as tappable, like a List disclosure indicator.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")  // flips in right-to-left layouts
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
