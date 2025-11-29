//
//  HomeView.swift
//  score
//
//  Home screen with Start New Game and Match History options
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    @Environment(\.modelContext) private var modelContext
    @State private var showingNameSheet = false
    @State private var showingGame = false
    @State private var showingActiveMatchAlert = false
    @State private var showingSettings = false
    @State private var player1Name = ""
    @State private var player2Name = ""

    private var preferencesService: UserPreferencesService {
        UserPreferencesService(modelContext: modelContext)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Watch app not installed banner
                if !connectivity.isWatchAppInstalled {
                    HStack(spacing: 12) {
                        Image(systemName: "applewatch")
                            .foregroundColor(.blue)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Apple Watch Recommended")
                                .font(.subheadline)
                                .bold()
                            Text("Score matches from your wrist with the companion Watch app")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 8) {
                        Text("Table Tennis")
                            .font(.largeTitle)
                            .bold()

                        if connectivity.isWatchAppInstalled {
                            HStack(spacing: 6) {
                                Image(systemName: connectivity.isWatchReachable ? "applewatch" : "applewatch.slash")
                                    .foregroundColor(connectivity.isWatchReachable ? .green : .gray)
                                    .font(.caption)
                                Text(connectivity.isWatchReachable ? "Watch Connected" : "Watch Not Connected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 40)

                    Spacer()

                // Main actions
                GlassEffectContainer(spacing: 16) {
                    // Resume match button if there's an active recording
                    if connectivity.isRecording {
                        Button {
                            showingGame = true
                        } label: {
                            HStack {
                                Image(systemName: "play.fill")
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Resume Match")
                                        .font(.headline)
                                    Text("\(connectivity.scoreState.playerOneGames)-\(connectivity.scoreState.playerTwoGames)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding()
                            .glassEffect(.regular.tint(.orange).interactive())
                        }
                        .buttonStyle(.plain)
                    }

                    // Start New Game
                    Button {
                        handleStartNewGame()
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                            Text("Start New Game")
                                .font(.title3)
                                .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .glassEffect(.regular.tint(.green).interactive())
                    }
                    .buttonStyle(.plain)

                    // Match History
                    NavigationLink(destination: MatchHistoryView()) {
                        HStack {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.title2)
                            Text("Match History")
                                .font(.title3)
                                .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .glassEffect(.regular.tint(.blue).interactive())
                    }
                    .buttonStyle(.plain)

                    // Camera Settings
                    Button {
                        showingSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "camera.circle.fill")
                                .font(.title2)
                            Text("Camera Settings")
                                .font(.title3)
                                .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .glassEffect(.regular.tint(.purple).interactive())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)

                    Spacer()

                    // Stats summary
                    if !connectivity.scoreState.matchHistory.isEmpty {
                        VStack(spacing: 8) {
                            Text("Total Matches")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(connectivity.scoreState.matchHistory.count)")
                                .font(.title)
                                .bold()
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingNameSheet) {
                MatchNameSheet(
                    player1Name: $player1Name,
                    player2Name: $player2Name,
                    onStart: startMatch
                )
                .presentationDetents([.fraction(0.95)])
                .presentationDragIndicator(.visible)
            }
            .navigationDestination(isPresented: $showingGame) {
                GameView()
            }
            .sheet(isPresented: $showingSettings) {
                CameraSettingsView()
            }
            .alert("Active Match in Progress", isPresented: $showingActiveMatchAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Save & Start New") {
                    Task {
                        await saveAndStartNew()
                    }
                }
                Button("Delete & Start New", role: .destructive) {
                    deleteAndStartNew()
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

    private func deleteActiveMatch() {
        connectivity.cancelMatch()
    }

    private func deleteAndStartNew() {
        deleteActiveMatch()
        prepareMatchName()
        showingNameSheet = true
    }

    private func saveAndStartNew() async {
        // Stop recording and save current match
        let videoURL = connectivity.stopRecording()
        let (fullVideo, highlightReel) = await connectivity.exportMatchVideos(from: videoURL)
        connectivity.endMatch(fullVideoURL: fullVideo, highlightVideoURL: highlightReel)

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

// MARK: - Match Name Sheet

struct MatchNameSheet: View {
    @Binding var player1Name: String
    @Binding var player2Name: String
    let onStart: () -> Void
    @Environment(\.dismiss) var dismiss
    @FocusState private var focusedField: Field?

    enum Field {
        case player1, player2
    }

    private var canStart: Bool {
        !player1Name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !player2Name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)

                    Text("Who's Playing?")
                        .font(.title2)
                        .bold()

                    Text("Enter the players' names for this match")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 32)

                VStack(spacing: 20) {
                    // Player 1
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text("Player 1")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                        }

                        TextField("Enter name", text: $player1Name)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                            .focused($focusedField, equals: .player1)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .player2
                            }
                    }

                    // VS divider
                    HStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 1)
                        Text("VS")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 1)
                    }

                    // Player 2
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                            Text("Player 2")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                        }

                        TextField("Enter name", text: $player2Name)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                            .focused($focusedField, equals: .player2)
                            .submitLabel(.done)
                            .onSubmit {
                                if canStart {
                                    onStart()
                                }
                            }
                    }
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    onStart()
                } label: {
                    HStack {
                        Image(systemName: "play.circle.fill")
                        Text("Start Match")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canStart ? Color.green : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!canStart)
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Auto-focus first field if empty
                if player1Name.isEmpty {
                    focusedField = .player1
                }
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self)
    let context = container.mainContext
    let eventStore = EventStore(modelContext: context)
    let stateProjector = StateProjector()
    let undoService = UndoService(eventStore: eventStore, stateProjector: stateProjector)
    let connectivity = WatchConnectivityManager(
        eventStore: eventStore,
        stateProjector: stateProjector,
        undoService: undoService,
        modelContext: context
    )

    return HomeView()
        .environmentObject(connectivity)
        .modelContainer(container)
}
