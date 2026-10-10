//
//  ContentView.swift
//  scorewatch Watch App
//
//  3-screen horizontal swipe interface with full-screen tap targets
//

import SwiftUI

struct ContentView: View {
    @Environment(WatchSessionManager.self) private var session
    @State private var selection = 1  // Default to center (scoring) screen

    var body: some View {
        Group {
            if session.scoreState.isRecording {
                // Active match - show swipeable interface
                TabView(selection: $selection) {
                    // Screen 0 (Left): End Game Controls
                    EndGameView()
                        .tag(0)

                    // Screen 1 (Center/Default): Scoring
                    ScoreControlView()
                        .tag(1)

                    // Screen 2 (Right): Highlight & Details
                    HighlightDetailsView()
                        .tag(2)
                }
                .tabViewStyle(.page)
            } else {
                // No active match - show waiting screen
                WaitingView()
            }
        }
        // A command failed, or the phone did not confirm it within the timeout.
        .sensoryFeedback(.error, trigger: session.failedCommandCount)
    }
}

// MARK: - Waiting View

struct WaitingView: View {
    @Environment(WatchSessionManager.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone")
                .font(.system(size: 50))
                .foregroundColor(.blue)

            Text("Ready to Play")
                .font(.headline)

            Text("Start a match on your iPhone to begin")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(session.isConnected ? "Connected" : "Connecting...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .padding()
    }
}

// MARK: - Screen 0: End Game Controls (Swipe Left)

struct EndGameView: View {
    @Environment(WatchSessionManager.self) private var session
    @State private var endGameTrigger = 0
    @State private var endMatchTrigger = 0
    @State private var isConfirmingEndGame = false
    @State private var isConfirmingEndMatch = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Game Control")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            // End Game Button (asks first: a stray tap would end the game at the current score)
            Button(role: .destructive) {
                isConfirmingEndGame = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 40))
                    Text("End Game")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .buttonStyle(.glass)
            .tint(.orange)
            .sensoryFeedback(.success, trigger: endGameTrigger)
            .confirmationDialog("End this game?", isPresented: $isConfirmingEndGame, titleVisibility: .visible) {
                Button("End Game", role: .destructive) {
                    if session.endGame() {
                        endGameTrigger += 1
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Records the current score as final. Recording continues.")
            }

            // End Match Button (asks first; the phone then runs its own end-match flow)
            Button(role: .destructive) {
                isConfirmingEndMatch = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 40))
                    Text("End Match")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            .buttonStyle(.glass)
            .tint(.red)
            .sensoryFeedback(.success, trigger: endMatchTrigger)
            .confirmationDialog("End the match?", isPresented: $isConfirmingEndMatch, titleVisibility: .visible) {
                Button("End Match", role: .destructive) {
                    if session.endMatch() {
                        endMatchTrigger += 1
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops recording and saves the match on the phone.")
            }

            Spacer()

            Text("← Swipe to score")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

// MARK: - Screen 1: Scoring (Center/Default)

struct ScoreControlView: View {
    @Environment(WatchSessionManager.self) private var session
    @State private var scoreTrigger = 0

    private var playerOneLabel: String {
        session.scoreState.playerOneName ?? "P1"
    }

    private var playerTwoLabel: String {
        session.scoreState.playerTwoName ?? "P2"
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                VStack(spacing: 0) {
                    // Player 1 Button - TOP HALF
                    Button {
                        if session.incrementPlayer1() {
                            scoreTrigger += 1
                        }
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Text(playerOneLabel)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                if session.scoreState.servingPlayer == 1 {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundColor(.green)
                                }
                            }
                            Text("\(session.scoreState.playerOneScore)")
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.blue)
                        .awaitingPhone(session.pendingAction == .player1Score)
                    }
                    .buttonStyle(.plain)

                    // Divider with game score
                    HStack(spacing: 4) {
                        Text("\(session.scoreState.playerOneGames)")
                            .foregroundColor(.blue)
                        Text("-")
                            .foregroundColor(.gray)
                        Text("\(session.scoreState.playerTwoGames)")
                            .foregroundColor(.red)
                    }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        // Double Tap highlight waiting for the phone
                        if session.pendingAction == .highlight {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                                .symbolEffect(.pulse)
                                .padding(.leading, 8)
                                .accessibilityLabel("Sending highlight")
                        }
                    }
                    .overlay(alignment: .trailing) {
                        QueuedCommandsBadge(queued: session.queuedCommandCount)
                            .padding(.trailing, 8)
                    }
                    .background(Color.black)

                    // Player 2 Button - BOTTOM HALF
                    Button {
                        if session.incrementPlayer2() {
                            scoreTrigger += 1
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(session.scoreState.playerTwoScore)")
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            HStack(spacing: 4) {
                                if session.scoreState.servingPlayer == 2 {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundColor(.green)
                                }
                                Text(playerTwoLabel)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.red)
                        .awaitingPhone(session.pendingAction == .player2Score)
                    }
                    .buttonStyle(.plain)
                }

                // Invisible highlight gesture receiver
                // Receives Double Tap hand gesture without intercepting screen taps
                HighlightGestureReceiver {
                    markHighlight()
                }
            }
        }
        .ignoresSafeArea()
        .sensoryFeedback(.impact, trigger: scoreTrigger)
    }

    private func markHighlight() {
        if session.markHighlight() {
            scoreTrigger += 1
        }
    }
}

// MARK: - Screen 2: Highlight & Details (Swipe Right)

struct HighlightDetailsView: View {
    @Environment(WatchSessionManager.self) private var session
    @State private var highlightTrigger = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Match Details")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            // Mark Highlight Button
            Button {
                if session.markHighlight() {
                    highlightTrigger += 1
                }
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.yellow)
                    Text("Mark Highlight")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .awaitingPhone(session.pendingAction == .highlight)
            }
            .buttonStyle(.glassProminent)
            .tint(.yellow)
            .sensoryFeedback(.success, trigger: highlightTrigger)

            // Game Score Display
            VStack(spacing: 8) {
                Text("Games")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    VStack {
                        Text("\(session.scoreState.playerOneGames)")
                            .font(.title)
                            .bold()
                            .foregroundColor(.blue)
                        Text(session.scoreState.playerOneName ?? "P1")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text("-")
                        .foregroundStyle(.secondary)

                    VStack {
                        Text("\(session.scoreState.playerTwoGames)")
                            .font(.title)
                            .bold()
                            .foregroundColor(.red)
                        Text(session.scoreState.playerTwoName ?? "P2")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.2))
            .cornerRadius(12)

            // Highlight count
            if session.scoreState.totalHighlightsInMatch > 0 {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                    Text(
                        "\(session.scoreState.totalHighlightsInMatch) highlight\(session.scoreState.totalHighlightsInMatch == 1 ? "" : "s")"
                    )
                    .font(.caption)
                }
            }

            Spacer()

            Text("Swipe left to score →")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

// MARK: - Command Status

/// Dims a control and shows a spinner while its command waits for the phone's confirmation.
struct AwaitingPhoneModifier: ViewModifier {
    let isPending: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isPending ? 0.5 : 1)
            .overlay {
                if isPending {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("Sending to iPhone")
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isPending)
    }
}

extension View {
    func awaitingPhone(_ isPending: Bool) -> some View {
        modifier(AwaitingPhoneModifier(isPending: isPending))
    }
}

/// Taps queued for the phone while it is unreachable; they are delivered in order once it is back.
struct QueuedCommandsBadge: View {
    let queued: Int

    var body: some View {
        if queued > 0 {
            Label("\(queued)", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
                .accessibilityLabel("\(queued) queued for iPhone")
        }
    }
}

// MARK: - Highlight Gesture Receiver

/// Invisible view that receives the Double Tap hand gesture
/// Uses .handGestureShortcut(.primaryAction) - available watchOS 11+
struct HighlightGestureReceiver: View {
    let action: () -> Void

    var body: some View {
        // Invisible button that only responds to hand gesture, not screen taps
        Button(action: action) {
            Color.clear
        }
        .buttonStyle(HighlightButtonStyle())
        .handGestureShortcut(.primaryAction)  // THIS IS THE KEY!
        .allowsHitTesting(false)  // Don't intercept screen taps
    }
}

/// Custom button style that doesn't show any visual feedback
struct HighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(WatchSessionManager())
}
