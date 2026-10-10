//
//  GameView.swift
//  score
//
//  Main game view with camera preview and scoring
//

import AVFoundation
import SwiftData
import SwiftUI
import UIKit
import os

struct GameView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showingEndGameAlert = false
    @State private var showingEndMatchAlert = false
    @State private var showingCancelAlert = false
    @State private var canUndo = false
    @State private var captureSession: AVCaptureSession?
    @State private var showExportProgress = false
    @State private var handledEndMatchRequest = 0
    @State private var cameraEnabled = true

    private var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    private var preferencesService: UserPreferencesService {
        UserPreferencesService(modelContext: modelContext)
    }

    var body: some View {
        ZStack {
            // Camera preview background (or dark background on simulator)
            if isRunningOnSimulator {
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        VStack {
                            Image(systemName: "video.slash")
                                .font(.system(size: 60))
                                .foregroundColor(.gray.opacity(0.3))
                            Text("Simulator Mode")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.5))
                        }
                    )
            } else {
                if let session = captureSession {
                    CameraPreviewView(captureSession: session)
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.3))
                } else {
                    Color.black
                        .ignoresSafeArea()
                        .overlay(
                            ProgressView()
                                .tint(.white)
                        )
                }
            }

            VStack(spacing: 0) {
                // Simulator info banner
                if isRunningOnSimulator {
                    HStack(spacing: 8) {
                        Image(systemName: "film")
                            .foregroundColor(.blue)
                        Text("Simulator: Using mock video")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.2))
                }

                RecordingStatusBar(cameraEnabled: cameraEnabled)

                Spacer()

                ScoringPanel(
                    canUndo: canUndo,
                    onMarkHighlight: markHighlight,
                    onUndo: undoLastAction,
                    onEndGame: { showingEndGameAlert = true },
                    onEndMatch: { showingEndMatchAlert = true }
                )
                .padding()
                .glassEffect(in: .rect(cornerRadius: 24))
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    showingCancelAlert = true
                }
                .foregroundColor(.white)
            }
        }
        .onAppear {
            // The phone sits on a stand during a match; never let it auto-lock mid-recording
            UIApplication.shared.isIdleTimerDisabled = true
            Log.ui.debug("🎮 onAppear called")
            Log.ui.debug("🎮 isRecording: \(connectivity.isRecording)")

            // Load camera enabled state
            cameraEnabled = preferencesService.isCameraEnabled()
            Log.ui.debug("🎮 Camera enabled: \(cameraEnabled)")

            // Auto-start recording when game starts (if not already recording)
            if !connectivity.isRecording {
                Log.ui.debug("🎮 Not recording, calling startRecording()")
                connectivity.startRecording()
                Log.ui.debug("🎮 startRecording() completed")
            } else {
                // Relaunch or return after an interruption: make sure the camera is capturing again
                connectivity.resumeVideoRecordingIfNeeded()
                captureSession = connectivity.videoManager?.captureSession
            }

            // Update undo availability
            Log.ui.debug("🎮 Updating undo availability")
            updateUndoAvailability()
            Log.ui.debug("🎮 onAppear completed")
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: connectivity.videoManager?.captureSession) { _, newSession in
            Log.ui.debug("🎮 Capture session changed: \(newSession != nil)")
            captureSession = newSession
        }
        .onChange(of: connectivity.scoreState.currentGamePoints.count) {
            updateUndoAvailability()
        }
        .onChange(of: connectivity.scoreState.totalHighlightsInMatch) {
            updateUndoAvailability()
        }
        .onChange(of: connectivity.endMatchRequestCount, initial: true) { _, count in
            // Watch requested end match: same flow as the phone button, once per request
            guard count > handledEndMatchRequest else { return }
            handledEndMatchRequest = count
            Task { await endMatchAndSave() }
        }
        .alert("End Game", isPresented: $showingEndGameAlert) {
            Button("Cancel", role: .cancel) {}
            if connectivity.scoreState.playerOneScore != connectivity.scoreState.playerTwoScore {
                Button("End Game", role: .destructive) {
                    connectivity.endGame(force: true)
                }
            }
        } message: {
            Text(endGameMessage)
        }
        .alert("Match Won", isPresented: matchWonBinding, presenting: connectivity.matchWonBy) { _ in
            Button("End Match & Save") {
                Task { await endMatchAndSave() }
            }
            Button("Keep Playing", role: .cancel) {
                connectivity.matchWonBy = nil
            }
        } message: { winner in
            Text(
                "\(connectivity.name(for: winner)) wins \(connectivity.scoreState.playerOneGames)-\(connectivity.scoreState.playerTwoGames). End the match and save the video?"
            )
        }
        .alert("End Match", isPresented: $showingEndMatchAlert) {
            Button("Cancel", role: .cancel) {}
            Button("End Match", role: .destructive) {
                Task {
                    await endMatchAndSave()
                }
            }
        } message: {
            Text("Stop recording and save the match with highlights?")
        }
        .alert("Cancel Match", isPresented: $showingCancelAlert) {
            Button("Keep Playing", role: .cancel) {}
            Button("Delete Match", role: .destructive) {
                Task { await cancelMatch() }
            }
        } message: {
            Text("This will delete all recordings and data for this match. This cannot be undone.")
        }
        .sheet(isPresented: $showExportProgress) {
            ExportProgressView()
        }
    }

    private func markHighlight() {
        connectivity.playHighlightSound()
        connectivity.markHighlight()
    }

    private var endGameMessage: String {
        let p1 = connectivity.scoreState.playerOneScore
        let p2 = connectivity.scoreState.playerTwoScore
        if ScoreAnnouncementUtils.checkGameWon(playerOneScore: p1, playerTwoScore: p2) != nil {
            return "Record \(p1)-\(p2) for this game? Recording continues for the next game."
        }
        if p1 == p2 {
            return "The score is tied \(p1)-\(p2). Score the deciding point before ending the game."
        }
        return "The game is not finished (\(p1)-\(p2)). End it now and award it to the leader?"
    }

    private var matchWonBinding: Binding<Bool> {
        Binding(
            get: { connectivity.matchWonBy != nil },
            set: { if !$0 { connectivity.matchWonBy = nil } }
        )
    }

    private func undoLastAction() {
        connectivity.undoLastAction()
        updateUndoAvailability()
    }

    private func updateUndoAvailability() {
        guard let matchId = connectivity.currentMatchId else {
            canUndo = false
            return
        }

        do {
            canUndo = try connectivity.undoService.canUndo(in: matchId)
        } catch {
            canUndo = false
        }
    }

    private func cancelMatch() async {
        // Delete match and all associated data (handles cleanup internally)
        await connectivity.cancelMatch()

        // Return to home
        dismiss()
    }

    private func endMatchAndSave() async {
        guard !connectivity.isExporting else { return }
        showExportProgress = true
        await connectivity.finishActiveMatch()
        showExportProgress = false
        dismiss()
    }
}

// MARK: - Subviews

/// Match name, capture status (REC with elapsed time, or why nothing is being recorded), highlight count.
private struct RecordingStatusBar: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    let cameraEnabled: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let matchName = connectivity.scoreState.currentMatchName {
                Text(matchName)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }

            HStack {
                captureStatus

                Spacer()

                if connectivity.scoreState.totalHighlightsInMatch > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                        Text("\(connectivity.scoreState.totalHighlightsInMatch)")
                            .bold()
                    }
                    .foregroundColor(.yellow)
                }
            }
        }
        .padding()
        .glassEffect(in: .rect(cornerRadius: 0))
    }

    @ViewBuilder private var captureStatus: some View {
        let state = connectivity.videoManager?.state
        if !cameraEnabled {
            statusLabel("video.slash", "Video disabled in settings", .gray)
        } else if state?.isRecording == true {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                Text("REC")
                    .font(.subheadline)
                    .bold()
                Text(
                    Duration.seconds(connectivity.recordingDuration),
                    format: .time(pattern: .minuteSecond(padMinuteToLength: 2))
                )
                .font(.subheadline)
                .monospacedDigit()
            }
            .foregroundColor(.white)
        } else {
            statusLabel("exclamationmark.triangle.fill", state?.userMessage ?? "Starting camera…", .orange)
        }
    }

    private func statusLabel(_ systemImage: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(color)
    }
}

/// Games score, both players' points with +/- buttons, highlight/undo and game controls.
private struct ScoringPanel: View {
    @Environment(WatchConnectivityManager.self) private var connectivity
    let canUndo: Bool
    let onMarkHighlight: () -> Void
    let onUndo: () -> Void
    let onEndGame: () -> Void
    let onEndMatch: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Text("Games")
                    .foregroundColor(.white)
                Text("\(connectivity.scoreState.playerOneGames)")
                    .font(.title2)
                    .bold()
                    .foregroundColor(.blue)
                Text("-")
                    .foregroundColor(.white)
                Text("\(connectivity.scoreState.playerTwoGames)")
                    .font(.title2)
                    .bold()
                    .foregroundColor(.red)
            }

            HStack(spacing: 32) {
                PlayerScoreColumn(
                    name: connectivity.scoreState.playerOneName ?? "Player 1",
                    score: connectivity.scoreState.playerOneScore,
                    isServing: connectivity.scoreState.servingPlayer == 1,
                    canDecrement: connectivity.lastPointPlayer == 1,
                    tint: .blue,
                    serveIndicatorLeading: false,
                    onIncrement: connectivity.incrementPlayer1,
                    onDecrement: { connectivity.undoPoint(forPlayer: 1) }
                )
                PlayerScoreColumn(
                    name: connectivity.scoreState.playerTwoName ?? "Player 2",
                    score: connectivity.scoreState.playerTwoScore,
                    isServing: connectivity.scoreState.servingPlayer == 2,
                    canDecrement: connectivity.lastPointPlayer == 2,
                    tint: .red,
                    serveIndicatorLeading: true,
                    onIncrement: connectivity.incrementPlayer2,
                    onDecrement: { connectivity.undoPoint(forPlayer: 2) }
                )
            }

            Button(action: onMarkHighlight) {
                Label("Mark Highlight", systemImage: "star.fill")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .tint(.yellow)
            .padding(.top, 8)

            Button(action: onUndo) {
                Label("Undo Last Point", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .disabled(!canUndo)
            .opacity(canUndo ? 1.0 : 0.5)

            HStack(spacing: 16) {
                Button("End Game", action: onEndGame)
                    .buttonStyle(.glassProminent)
                    .padding(8)
                    .tint(.orange)

                Button("End Match", action: onEndMatch)
                    .buttonStyle(.glassProminent)
                    .padding(8)
                    .tint(.purple)
            }
            .padding(.top, 8)
        }
    }
}

/// One player's name, current points, serve indicator and +/- buttons.
private struct PlayerScoreColumn: View {
    let name: String
    let score: Int
    let isServing: Bool
    let canDecrement: Bool
    let tint: Color
    let serveIndicatorLeading: Bool
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(name)
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 8) {
                if serveIndicatorLeading { serveIndicator }
                Text("\(score)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(tint)
                if !serveIndicatorLeading { serveIndicator }
            }
            HStack(spacing: 12) {
                Button(action: onIncrement) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)

                Button(action: onDecrement) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .disabled(!canDecrement)
            }
        }
    }

    @ViewBuilder private var serveIndicator: some View {
        if isServing {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        }
    }
}

// Camera Preview View - Uses UIViewController for proper orientation handling
struct CameraPreviewView: UIViewControllerRepresentable {
    let captureSession: AVCaptureSession

    func makeUIViewController(context: Context) -> CameraPreviewViewController {
        let controller = CameraPreviewViewController()
        controller.captureSession = captureSession
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraPreviewViewController, context: Context) {
        uiViewController.captureSession = captureSession
    }
}

// UIViewController that properly handles orientation changes for camera preview
class CameraPreviewViewController: UIViewController {
    var captureSession: AVCaptureSession? {
        didSet {
            updatePreviewSession()
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreviewLayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Update preview layer frame to match view bounds
        previewLayer?.frame = view.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // Keep the layer filling the view during rotation; the rotation coordinator handles the angle
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.previewLayer?.frame = CGRect(origin: .zero, size: size)
        })
    }

    private func setupPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        updatePreviewSession()

        Log.video.info("📹 Created preview layer")
    }

    private func updatePreviewSession() {
        previewLayer?.session = captureSession
        rotationObservation = nil
        rotationCoordinator = nil
        guard let layer = previewLayer,
            let device = captureSession?.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first
        else { return }
        // Follows the device's physical orientation (works when the phone lies flat on a stand)
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) {
            [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                self?.applyPreviewRotation(angle)
            }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        Log.video.debug("📱 Preview rotation angle: \(angle)")
    }
}

#Preview {
    let fixture = PreviewSupport.makeFixture()
    NavigationStack {
        GameView()
    }
    .environment(fixture.connectivity)
    .modelContainer(fixture.container)
}
