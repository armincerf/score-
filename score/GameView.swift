//
//  GameView.swift
//  score
//
//  Main game view with camera preview and scoring
//

import SwiftUI
import SwiftData
import AVFoundation
import AudioToolbox

struct GameView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
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

                // Top bar - recording indicator and stats
                VStack(spacing: 4) {
                    // Match name
                    if let matchName = connectivity.scoreState.currentMatchName {
                        Text(matchName)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                    }

                    HStack {
                        // Recording indicator or disabled message
                        if cameraEnabled {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 12, height: 12)
                                Text("REC")
                                    .font(.subheadline)
                                    .bold()
                                Text(formatDuration(connectivity.recordingDuration))
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

                        // Highlight count
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

                Spacer()

                // Scoring area
                VStack(spacing: 16) {
                    // Games score
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

                    // Current game points
                    HStack(spacing: 32) {
                        // Player 1
                        VStack(spacing: 12) {
                            Text(connectivity.scoreState.playerOneName ?? "Player 1")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            HStack(spacing: 8) {
                                Text("\(connectivity.scoreState.playerOneScore)")
                                    .font(.system(size: 72, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.blue)
                                if connectivity.scoreState.servingPlayer == 1 {
                                    Image(systemName: "circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            HStack(spacing: 12) {
                                Button {
                                    connectivity.incrementPlayer1()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)

                                Button {
                                    connectivity.decrementPlayer1()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title)
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                            }
                        }

                        // Player 2
                        VStack(spacing: 12) {
                            Text(connectivity.scoreState.playerTwoName ?? "Player 2")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            HStack(spacing: 8) {
                                if connectivity.scoreState.servingPlayer == 2 {
                                    Image(systemName: "circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                Text("\(connectivity.scoreState.playerTwoScore)")
                                    .font(.system(size: 72, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.red)
                            }
                            HStack(spacing: 12) {
                                Button {
                                    connectivity.incrementPlayer2()
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)

                                Button {
                                    connectivity.decrementPlayer2()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                    }

                    // Manual highlight button
                    Button {
                        // Play sound and haptic feedback
                        AudioServicesPlaySystemSound(1057)
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)

                        connectivity.markHighlight()
                    } label: {
                        Label("Mark Highlight", systemImage: "star.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.yellow)
                    .padding(.top, 8)

                    // Undo button
                    Button {
                        undoLastAction()
                    } label: {
                        Label("Undo Last Point", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .disabled(!canUndo)
                    .opacity(canUndo ? 1.0 : 0.5)

                    // Game controls
                    HStack(spacing: 16) {
                        Button("End Game") {
                            showingEndGameAlert = true
                        }
                        .buttonStyle(GlassProminentButtonStyle())
                        .padding(8)
                        .tint(.orange)

                        Button("End Match") {
                            showingEndMatchAlert = true
                        }
                        .buttonStyle(GlassProminentButtonStyle())
                        .padding(8)
                        .tint(.purple)
                    }
                    .padding(.top, 8)
                }
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
            print("[GameView] 🎮 onAppear called")
            print("[GameView] 🎮 isRecording: \(connectivity.isRecording)")

            // Load camera enabled state
            cameraEnabled = preferencesService.isCameraEnabled()
            print("[GameView] 🎮 Camera enabled: \(cameraEnabled)")

            // Auto-start recording when game starts (if not already recording)
            if !connectivity.isRecording {
                print("[GameView] 🎮 Not recording, calling startRecording()")
                connectivity.startRecording()
                print("[GameView] 🎮 startRecording() completed")
            } else {
                print("[GameView] 🎮 Already recording, skipping startRecording()")
                // If already recording, capture session should already exist
                captureSession = connectivity.videoManager?.captureSession
            }

            // Update undo availability
            print("[GameView] 🎮 Updating undo availability")
            updateUndoAvailability()
            print("[GameView] 🎮 onAppear completed")
        }
        .onChange(of: connectivity.videoManager?.captureSession) { _, newSession in
            print("[GameView] 🎮 Capture session changed: \(newSession != nil)")
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
            Button("Cancel", role: .cancel) { }
            Button("End Game", role: .destructive) {
                connectivity.endGame()
            }
        } message: {
            Text("Record the final score for this game? Recording will continue for the next game.")
        }
        .alert("End Match", isPresented: $showingEndMatchAlert) {
            Button("Cancel", role: .cancel) { }
            Button("End Match", role: .destructive) {
                Task {
                    await endMatchAndSave()
                }
            }
        } message: {
            Text("Stop recording and save the match with highlights?")
        }
        .alert("Cancel Match", isPresented: $showingCancelAlert) {
            Button("Keep Playing", role: .cancel) { }
            Button("Delete Match", role: .destructive) {
                cancelMatch()
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
                    let estimatedTotal = 180.0 // Rough estimate: 3 minutes for typical match
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func undoLastAction() {
        guard let matchId = connectivity.currentMatchId else { return }

        do {
            if let _ = try connectivity.undoService.undoLastPoint(in: matchId) {
                // Refresh state after undo
                connectivity.refreshState()
                updateUndoAvailability()
            }
        } catch {
            print("[GameView] Error undoing: \(error)")
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

    private func cancelMatch() {
        // Delete match and all associated data (handles cleanup internally)
        connectivity.cancelMatch()

        // Return to home
        dismiss()
    }

    private func endMatchAndSave() async {
        isExportingVideo = true
        showExportProgress = true
        exportProgress = 0.0

        // Stop recording and get video URL
        let videoURL = connectivity.stopRecording()

        // Export both full video and highlight reel with correct orientation
        let (fullVideo, highlightReel) = await connectivity.exportMatchVideos(
            from: videoURL,
            progressHandler: { progress in
                self.exportProgress = progress
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
            guard let self = self else { return }
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
        
        print("[CameraPreview] 📹 Created preview layer")
    }
    
    private func updatePreviewSession() {
        previewLayer?.session = captureSession
    }
    
    private func updatePreviewOrientation() {
        guard let connection = previewLayer?.connection else { return }
        
        // Use window scene for accurate orientation (works better than UIDevice orientation)
        let orientation: UIInterfaceOrientation
        if let windowScene = view.window?.windowScene {
            orientation = windowScene.interfaceOrientation
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
            print("[CameraPreview] 📱 Orientation updated to angle: \(rotationAngle) (interface: \(orientation.rawValue))")
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

    return NavigationStack {
        GameView()
            .environmentObject(connectivity)
            .modelContainer(container)
    }
}
