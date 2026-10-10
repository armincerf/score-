//
//  GameView.swift
//  score
//
//  Main game view with camera preview and scoring
//

import AVFoundation
import SwiftData
import SwiftUI
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
    @State private var isExportingVideo = false
    @State private var exportProgress: Double = 0.0
    @State private var showExportProgress = false
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
                Log.ui.debug("🎮 Already recording, skipping startRecording()")
                // If already recording, capture session should already exist
                captureSession = connectivity.videoManager?.captureSession
            }

            // Update undo availability
            Log.ui.debug("🎮 Updating undo availability")
            updateUndoAvailability()
            Log.ui.debug("🎮 onAppear completed")
        }
        .onChange(of: connectivity.videoManager?.captureSession) { _, newSession in
            Log.ui.debug("🎮 Capture session changed: \(newSession != nil)")
            captureSession = newSession
        }
        .onChange(of: connectivity.scoreState.playerOneScore) {
            updateUndoAvailability()
        }
        .onChange(of: connectivity.scoreState.playerTwoScore) {
            updateUndoAvailability()
        }
        .onChange(of: connectivity.shouldEndMatchFromWatch) { _, shouldEnd in
            if shouldEnd {
                // Watch requested end match - trigger the same flow as phone button
                Task {
                    await endMatchAndSave()
                }
                // Reset the signal
                connectivity.shouldEndMatchFromWatch = false
            }
        }
        .alert("End Game", isPresented: $showingEndGameAlert) {
            Button("Cancel", role: .cancel) {}
            Button("End Game", role: .destructive) {
                connectivity.endGame()
            }
        } message: {
            Text("Record the final score for this game? Recording will continue for the next game.")
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
            VStack(spacing: 24) {
                Text("Generating Highlight Video")
                    .font(.headline)

                ProgressView(value: exportProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)

                Text("\(Int(exportProgress * 100))%")
                    .font(.title)
                    .monospacedDigit()

                if exportProgress > 0 {
                    let estimatedTotal = 180.0  // Rough estimate: 3 minutes for typical match
                    let elapsed = estimatedTotal * exportProgress
                    let remaining = estimatedTotal - elapsed
                    Text("About \(Int(remaining))s remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(40)
            .presentationDetents([.height(280)])
            .interactiveDismissDisabled()
        }
    }

    private func markHighlight() {
        connectivity.playHighlightSound()
        connectivity.markHighlight()
    }

    private func undoLastAction() {
        guard let matchId = connectivity.currentMatchId else { return }

        do {
            if try connectivity.undoService.undoLastPoint(in: matchId) != nil {
                // Refresh state after undo
                connectivity.refreshState()
                updateUndoAvailability()
            }
        } catch {
            Log.ui.error("Error undoing: \(error)")
        }
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
        isExportingVideo = true
        showExportProgress = true
        exportProgress = 0.0

        // Stop recording and wait for the finished video file
        let videoURL = await connectivity.stopRecording()

        // Export both full video and highlight reel with correct orientation
        let (fullVideo, highlightReel) = await connectivity.exportMatchVideos(
            from: videoURL,
            progressHandler: { progress in
                exportProgress = progress
            }
        )

        // End match with both videos
        connectivity.endMatch(fullVideoURL: fullVideo, highlightVideoURL: highlightReel)

        isExportingVideo = false
        showExportProgress = false

        // Return to home
        dismiss()
    }
}

// MARK: - Subviews

/// Match name, REC indicator with elapsed time, and highlight count.
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
                if cameraEnabled {
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
                    HStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.subheadline)
                        Text("Video disabled in settings")
                            .font(.subheadline)
                    }
                    .foregroundColor(.gray)
                }

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
                    tint: .blue,
                    serveIndicatorLeading: false,
                    onIncrement: connectivity.incrementPlayer1,
                    onDecrement: connectivity.decrementPlayer1
                )
                PlayerScoreColumn(
                    name: connectivity.scoreState.playerTwoName ?? "Player 2",
                    score: connectivity.scoreState.playerTwoScore,
                    isServing: connectivity.scoreState.servingPlayer == 2,
                    tint: .red,
                    serveIndicatorLeading: true,
                    onIncrement: connectivity.incrementPlayer2,
                    onDecrement: connectivity.decrementPlayer2
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

        // Update frame and orientation during rotation animation
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.previewLayer?.frame = CGRect(origin: .zero, size: size)
            self.updatePreviewOrientation()
        })
    }

    private func setupPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        updatePreviewSession()
        updatePreviewOrientation()

        Log.video.info("📹 Created preview layer")
    }

    private func updatePreviewSession() {
        previewLayer?.session = captureSession
    }

    private func updatePreviewOrientation() {
        guard let connection = previewLayer?.connection else { return }

        // Use window scene for accurate orientation (works better than UIDevice orientation)
        let orientation: UIInterfaceOrientation
        if let windowScene = view.window?.windowScene {
            orientation = windowScene.effectiveGeometry.interfaceOrientation
        } else {
            // Fallback to device orientation
            let deviceOrientation = UIDevice.current.orientation
            switch deviceOrientation {
            case .portrait: orientation = .portrait
            case .portraitUpsideDown: orientation = .portraitUpsideDown
            case .landscapeLeft: orientation = .landscapeRight
            case .landscapeRight: orientation = .landscapeLeft
            default: orientation = .portrait
            }
        }

        let rotationAngle: CGFloat
        switch orientation {
        case .portrait:
            rotationAngle = 90
        case .portraitUpsideDown:
            rotationAngle = 270
        case .landscapeLeft:
            rotationAngle = 180
        case .landscapeRight:
            rotationAngle = 0
        default:
            rotationAngle = 90
        }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
            Log.video.debug("📱 Orientation updated to angle: \(rotationAngle) (interface: \(orientation.rawValue))")
        }
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
