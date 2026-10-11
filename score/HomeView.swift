//
//  HomeView.swift
//  score
//
//  Home screen: a dashboard of the live match or head-to-head, recent matches and the watch status, with
//  New Match as the one floating action. Owns the presentation state; the sections are in HomeSections.swift.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    @Environment(\.modelContext) private var modelContext
    @State private var showingNameSheet = false
    @State private var showingGame = false
    @State private var showingActiveMatchAlert = false
    @State private var showingSettings = false
    @State private var player1Name = ""
    @State private var player2Name = ""
    @State private var isFinishingMatch = false
    @State private var showingSaveFailedAlert = false

    private var preferencesService: UserPreferencesService {
        UserPreferencesService(modelContext: modelContext)
    }

    var body: some View {
        NavigationStack {
            HomeContent(
                history: connectivity.scoreState.matchHistory,
                activeMatch: connectivity.isRecording ? ActiveMatchSummary(connectivity.scoreState) : nil,
                watchStatus: WatchStatus(
                    isInstalled: connectivity.isWatchAppInstalled, isReachable: connectivity.isWatchReachable),
                onResume: { showingGame = true }
            )
            .navigationTitle("Table Tennis")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                NewMatchButton(action: handleStartNewGame)
            }
            .navigationDestination(isPresented: $showingGame) {
                GameView()
            }
            .onAppear {
                #if DEBUG
                    if DebugSeed.showsNewMatchSheet, !showingNameSheet {  // screenshot hook, see DebugSeed
                        prepareMatchName()
                        showingNameSheet = true
                    }
                #endif
            }
            .sheet(isPresented: $showingNameSheet) {
                MatchNameSheet(player1Name: $player1Name, player2Name: $player2Name, onStart: startMatch)
            }
            .sheet(isPresented: $showingSettings) {
                CameraSettingsView()
            }
            .sheet(isPresented: $isFinishingMatch) {
                ExportProgressView()
            }
            .alert("Could not save the match", isPresented: $showingSaveFailedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The match is still active. Open it to try again, or delete it.")
            }
            .showsGameOnWatchEndRequest($showingGame)
            .alert("Active Match in Progress", isPresented: $showingActiveMatchAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Save & Start New") {
                    Task {
                        await saveAndStartNew()
                    }
                }
                Button("Delete & Start New", role: .destructive) {
                    Task {
                        await deleteAndStartNew()
                    }
                }
            } message: {
                Text("You have an active match. Do you want to save it before starting a new one?")
            }
        }
    }

    private func handleStartNewGame() {
        if connectivity.isRecording {
            // Show alert if there's an active match
            showingActiveMatchAlert = true
        } else {
            // No active match, proceed normally
            prepareMatchName()
            showingNameSheet = true
        }
    }

    private func deleteAndStartNew() async {
        await connectivity.cancelMatch()
        prepareMatchName()
        showingNameSheet = true
    }

    private func saveAndStartNew() async {
        // Stop recording, export and save the current match before offering a new one
        isFinishingMatch = true
        let saved = await connectivity.finishActiveMatch()
        isFinishingMatch = false
        guard saved else {
            showingSaveFailedAlert = true
            return
        }

        // Now start new match
        prepareMatchName()
        showingNameSheet = true
    }

    private func prepareMatchName() {
        // Get most recent player names from preferences
        let (recent1, recent2) = preferencesService.getMostRecentPlayerNames()
        player1Name = recent1
        player2Name = recent2
    }

    private func startMatch() {
        // Save player names to preferences for next time
        preferencesService.updatePlayerNames(player1: player1Name, player2: player2Name)

        // Create match name with timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let timestamp = dateFormatter.string(from: Date())

        let matchName = "\(player1Name) vs \(player2Name) - \(timestamp)"
        connectivity.setMatchName(matchName, player1: player1Name, player2: player2Name)

        showingNameSheet = false
        showingGame = true
    }
}

// MARK: - Watch end-match requests

/// Shows the game screen when the watch asks to end the match while it is not showing, so it can end it there.
/// A modifier of its own so the request counter is not a dependency of the whole home screen.
private struct ShowsGameOnWatchEndRequest: ViewModifier {
    @Environment(WatchConnectivityManager.self) private var connectivity
    @Binding var showingGame: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: connectivity.endMatchRequestCount, initial: true) { _, count in
                if count > 0, connectivity.isRecording, !showingGame {
                    showingGame = true
                }
            }
    }
}

extension View {
    fileprivate func showsGameOnWatchEndRequest(_ showingGame: Binding<Bool>) -> some View {
        modifier(ShowsGameOnWatchEndRequest(showingGame: showingGame))
    }
}

#Preview {
    let fixture = PreviewSupport.makeFixture()
    HomeView()
        .environment(fixture.connectivity)
        .modelContainer(fixture.container)
}
