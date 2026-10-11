//
//  StatsView.swift
//  score
//
//  The Stats page: a leaderboard of every player and the head-to-head of any two (the most recent match's pair
//  by default; no choice to make when only two people have played). Rows open a player's page
//  (PlayerStatsView.swift), a pair's head-to-head (HeadToHeadStatsView.swift) or a match (MatchDetailView).
//  The records are computed once per history change by `StatsModel` (pure rules: PlayerRecords.swift); the pages
//  behind the rows are `StatsRouteView`s, declared at the root of the home screen's stack.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Model and routes

/// The history and its records, recomputed only when the history changes, plus the head-to-head pair chosen on
/// the Stats page.
@Observable
final class StatsModel {
    private(set) var records = PlayerRecords(history: [])
    private(set) var isLoaded = false
    /// The head-to-head pair on the Stats page; nil without two players.
    private(set) var pair: PlayerPair?

    /// The head-to-head's first player; choosing the other player swaps the two.
    var playerOne: String {
        get { pair?.playerOne ?? "" }
        set { pair = pair?.choosing(playerOne: newValue) }
    }

    /// The head-to-head's second player; choosing the other player swaps the two.
    var playerTwo: String {
        get { pair?.playerTwo ?? "" }
        set { pair = pair?.choosing(playerTwo: newValue) }
    }

    func load(_ history: [MatchResult]) {
        records = PlayerRecords(history: history)
        isLoaded = true
        // Keep the chosen pair while both still have matches; otherwise the most recent match's players
        if let pair, records.player(pair.playerOne) != nil, records.player(pair.playerTwo) != nil { return }
        pair = records.latestPair.map { PlayerPair(playerOne: $0.playerOne, playerTwo: $0.playerTwo) }
    }
}

/// Two different players by identity (`MatchPlayers.key`).
nonisolated struct PlayerPair: Hashable, Sendable {
    let playerOne: String
    let playerTwo: String

    /// The pair with `id` as player one; choosing player two's identity swaps them.
    func choosing(playerOne id: String) -> PlayerPair {
        id == playerTwo
            ? PlayerPair(playerOne: id, playerTwo: playerOne) : PlayerPair(playerOne: id, playerTwo: playerTwo)
    }

    /// The pair with `id` as player two; choosing player one's identity swaps them.
    func choosing(playerTwo id: String) -> PlayerPair {
        id == playerOne
            ? PlayerPair(playerOne: playerTwo, playerTwo: id) : PlayerPair(playerOne: playerOne, playerTwo: id)
    }
}

/// The Stats page and the pages behind its rows, by identity so they always show the current records. Pushed onto
/// the home screen's path and resolved at its root (`StatsRouteView`): a value link on a page pushed by
/// `navigationDestination(isPresented:)` does not push.
nonisolated enum StatsRoute: Hashable, Sendable {
    case stats
    case player(String)
    case headToHead(String, String)
    case match(UUID)
}

// MARK: - Page

struct StatsView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    @State private var model = StatsModel()

    var body: some View {
        StatsContent(model: model)
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: connectivity.scoreState.matchHistory.map(\.id), initial: true) {
                model.load(connectivity.scoreState.matchHistory)
            }
    }
}

/// Nothing until the records are loaded, then the empty state or the leaderboard and head-to-head.
private struct StatsContent: View {
    let model: StatsModel

    var body: some View {
        if !model.isLoaded {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        } else if model.records.leaderboard.isEmpty {
            ContentUnavailableView {
                Label("No Stats Yet", systemImage: "chart.bar.xaxis")
            } description: {
                Text("Play a match to see stats.")
            }
            .background(Color(uiColor: .systemGroupedBackground))
        } else {
            List {
                LeaderboardSection(players: model.records.leaderboard)
                StatsHeadToHead(model: model)
            }
            .listStyle(.insetGrouped)
        }
    }
}

/// Every player, best first; a row opens the player's page.
private struct LeaderboardSection: View {
    let players: [PlayerRecord]

    var body: some View {
        Section {
            ForEach(players.enumerated(), id: \.element.id) { index, player in
                NavigationLink(value: StatsRoute.player(player.id)) {
                    LeaderboardRow(rank: index + 1, player: player)
                }
            }
        } header: {
            Text("Leaderboard")
        } footer: {
            Text("Ranked by win rate, then wins. Form shows the last five matches, the latest on the right.")
        }
    }
}

/// The chosen pair's record and matches, with the choice of players when there are more than two.
private struct StatsHeadToHead: View {
    @Bindable var model: StatsModel

    var body: some View {
        if let pair = model.pair, let record = model.records.headToHead(pair.playerOne, pair.playerTwo) {
            HeadToHeadSections(record: record, showsTitle: true) {
                // Nothing to choose when only two people have played
                if model.records.leaderboard.count > 2 {
                    PlayerChoice(title: "Player", selection: $model.playerOne, players: model.records.leaderboard)
                        .tint(.blue)
                    PlayerChoice(title: "Opponent", selection: $model.playerTwo, players: model.records.leaderboard)
                        .tint(.red)
                }
            }
            .id(pair)  // a new pair starts on All
        }
    }
}

/// A menu of every player, by name.
private struct PlayerChoice: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    let players: [PlayerRecord]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(players) { player in
                Text(player.name).tag(player.id)
            }
        }
        .pickerStyle(.menu)
    }
}

/// The page a `StatsRoute` opens, from the current history.
struct StatsRouteView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    let route: StatsRoute

    var body: some View {
        let history = connectivity.scoreState.matchHistory
        switch route {
        case .stats:
            StatsView()
        case .player(let id):
            let records = PlayerRecords(history: history)
            if let player = records.player(id) {
                PlayerStatsView(player: player, opponents: records.opponents(of: id), matches: records.matches(of: id))
            } else {
                ContentUnavailableView("No Matches", systemImage: "person.slash")
            }
        case let .headToHead(one, two):
            if let record = PlayerRecords(history: history).headToHead(one, two) {
                HeadToHeadStatsView(record: record)
            } else {
                ContentUnavailableView("No Matches", systemImage: "person.2.slash")
            }
        case .match(let id):
            if let index = history.firstIndex(where: { $0.id == id }) {
                // Numbered as the history screens number it: its position in the history, from 1
                MatchDetailView(match: history[index], matchNumber: index + 1, allMatches: history)
            } else {
                ContentUnavailableView("Match Deleted", systemImage: "trash")
            }
        }
    }
}

#Preview {
    let fixture = PreviewSupport.makeFixture()
    NavigationStack {
        StatsView()
    }
    .environment(fixture.connectivity)
    .modelContainer(fixture.container)
}
