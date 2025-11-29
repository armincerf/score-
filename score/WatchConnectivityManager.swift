//
//  WatchConnectivityManager.swift
//  score (iOS)
//
//  Manages communication between iOS and watchOS
//  Handles video recording and highlight marking
//

import Foundation
import Combine
@preconcurrency import WatchConnectivity
@preconcurrency import AVFoundation
import AudioToolbox
import UIKit
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Sendable wrapper for WCSession message data (iOS side)
struct WatchMessageData: Sendable {
    let command: String?
    let scoreState: ScoreState?
    
    init(from message: [String: Any]) {
        self.command = message["command"] as? String
        self.scoreState = ScoreState(dictionary: message)
    }
}

/// Wrapper to make non-Sendable values sendable when you know it's safe
/// Used for WCSession reply handlers which are safe to call from any thread
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    @Published var scoreState = ScoreState()
    @Published var isWatchReachable = false
    @Published var isWatchAppInstalled = false

    // Video recording
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0

    // Signal for watch-initiated end match (triggers UI flow in GameView)
    @Published var shouldEndMatchFromWatch = false

    private var session: WCSession?
    var videoManager: VideoRecordingManager?
    private var durationTimer: Timer?

    // Score announcer for TTS
    let scoreAnnouncer = ScoreAnnouncer()

    // Highlight sound player
    private var highlightSoundPlayer: AVAudioPlayer?

    // Point timestamps for highlight reel generation
    private var pointTimestamps: [TimeInterval] = []  // Video timestamps of scored points
    private var currentVideoURL: URL?
    private var currentGameStartTime: TimeInterval = 0

    // Pending highlight waiting for player attribution
    private var pendingHighlightId: UUID?
    
    // Video export orientation (captured after first point for stable orientation)
    private var matchExportOrientation: MediaExportService.VideoOrientation?

    // Event sourcing dependencies
    private let eventStore: EventStore
    private let stateProjector: StateProjector
    let undoService: UndoService
    private let modelContext: ModelContext

    // Current match ID (nil if no active match)
    var currentMatchId: UUID?
    private var currentGameNumber: Int = 0

    // Simulator detection
    private var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // User preferences service
    private var preferencesService: UserPreferencesService {
        UserPreferencesService(modelContext: modelContext)
    }

    init(eventStore: EventStore, stateProjector: StateProjector, undoService: UndoService, modelContext: ModelContext) {
        self.eventStore = eventStore
        self.stateProjector = stateProjector
        self.undoService = undoService
        self.modelContext = modelContext

        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }

        // Load active match if exists
        loadActiveMatch()
    }

    // MARK: - State Management

    private func loadActiveMatch() {
        do {
            if let activeMatch = try eventStore.getActiveMatch() {
                currentMatchId = activeMatch.id
                print("[iOS] Loading active match: \(activeMatch.matchName)")

                // Rebuild state from events
                let events = try eventStore.getEvents(matchId: activeMatch.id)
                scoreState = try stateProjector.project(events: events, matchMetadata: activeMatch)

                // Calculate current game number
                currentGameNumber = scoreState.currentMatchGames.count

                // Restore video file path from MatchStartedEvent
                if let matchStartedEvent = events.first(where: { $0.eventType == EventType.matchStarted.rawValue }) {
                    let event = try JSONDecoder().decode(MatchStartedEvent.self, from: matchStartedEvent.eventData)
                    if let videoPath = event.videoFilePath {
                        currentVideoURL = URL(fileURLWithPath: videoPath)
                        print("[iOS] Restored video file path: \(videoPath)")

                        // Check if video file exists
                        if !FileManager.default.fileExists(atPath: videoPath) {
                            print("[iOS] ⚠️ Video file does not exist at path - recording may have been interrupted")
                        }
                    }
                }

                // Sync recording state
                isRecording = scoreState.isRecording

                // Recalculate recording duration if recording is active
                if scoreState.isRecording, let startTime = scoreState.recordingStartTime {
                    recordingDuration = Date().timeIntervalSince(startTime)

                    // Restart duration timer - capture startTime to avoid accessing MainActor property in timer
                    durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self else { return }
                            self.recordingDuration = Date().timeIntervalSince(startTime)
                        }
                    }

                    // Rebuild point timestamps for video generation
                    for game in scoreState.currentMatchGames {
                        for point in game.points {
                            if let videoTime = point.videoTimestamp {
                                pointTimestamps.append(videoTime)
                            }
                        }
                    }
                    for point in scoreState.currentGamePoints {
                        if let videoTime = point.videoTimestamp {
                            pointTimestamps.append(videoTime)
                        }
                    }

                    // Restore pending highlight if any
                    if let pending = scoreState.pendingHighlight {
                        pendingHighlightId = pending.id
                    }

                    // Set game start time (sum of all completed game durations)
                    currentGameStartTime = scoreState.currentMatchGames.reduce(0) { $0 + ($1.duration ?? 0) }
                }

                print("[iOS] Loaded match state: \(scoreState.playerOneGames)-\(scoreState.playerTwoGames), Recording: \(isRecording)")
            }
        } catch {
            print("[iOS] Error loading active match: \(error)")
        }
    }

    func refreshState() {
        guard let matchId = currentMatchId else { return }

        do {
            guard let match = try eventStore.getMatch(id: matchId) else { return }
            let events = try eventStore.getEvents(matchId: matchId)
            scoreState = try stateProjector.project(events: events, matchMetadata: match)
            currentGameNumber = scoreState.currentMatchGames.count
        } catch {
            print("[iOS] Error refreshing state: \(error)")
        }
    }

    // MARK: - Video Recording Setup

    func setupVideoRecording(completion: @escaping @Sendable () -> Void) {
        print("[iOS] 📹 setupVideoRecording called, videoManager exists: \(videoManager != nil)")
        if videoManager == nil {
            print("[iOS] 📹 Creating new VideoRecordingManager")
            videoManager = VideoRecordingManager()
        }
        
        // Apply user's camera settings from preferences
        let (deviceTypeStr, qualityStr) = preferencesService.getCameraSettings()
        let deviceType = CameraDeviceType.from(string: deviceTypeStr)
        let quality = VideoQualityPreset.from(string: qualityStr)
        videoManager?.configure(deviceType: deviceType, quality: quality)
        
        print("[iOS] 📹 Calling setupCaptureSession")
        videoManager?.setupCaptureSession(completion: completion)
    }

    // MARK: - Send to Watch

    private func sendHighlightConfirmation() {
        guard let session = session else { return }
        guard session.isPaired && session.isWatchAppInstalled else { return }
        
        // Calculate current highlight count
        let highlightCount = scoreState.highlightClips.count + (scoreState.pendingHighlight != nil ? 1 : 0)
        
        var message = scoreState.toDictionary()
        message["highlightConfirmed"] = true
        message["highlightCount"] = highlightCount
        
        // Use sendMessage for instant delivery (high priority)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                print("[iOS] Error sending highlight confirmation: \(error.localizedDescription)")
            }
            print("[iOS] ⭐ Highlight confirmation sent instantly to watch (count: \(highlightCount))")
        } else {
            // Fallback to context if not reachable
            do {
                try session.updateApplicationContext(message)
            } catch {
                print("[iOS] Error updating context: \(error.localizedDescription)")
            }
        }
    }

    func sendScore() {
        guard let session = session else { return }

        // Only try to send if watch is paired and app is installed
        guard session.isPaired && session.isWatchAppInstalled else {
            return
        }

        let message = scoreState.toDictionary()

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                print("[iOS] Error sending: \(error.localizedDescription)")
            }
        }

        do {
            try session.updateApplicationContext(message)
            print("[iOS] Updated context: P1=\(scoreState.playerOneScore) P2=\(scoreState.playerTwoScore)")
        } catch {
            // Silently ignore watch sync errors - app works standalone
        }
    }

    // MARK: - Recording Control

    func startRecording() {
        print("[iOS] 🔴 startRecording called")

        // Check if camera recording is enabled
        let cameraEnabled = preferencesService.isCameraEnabled()
        print("[iOS] 🔴 Camera recording enabled: \(cameraEnabled)")

        // Use the pre-created video URL (set in setMatchName)
        guard let fileURL = currentVideoURL else {
            print("[iOS] ⚠️ No video URL set - cannot start recording")
            return
        }

        print("[iOS] 🔴 Video URL: \(fileURL.lastPathComponent)")
        print("[iOS] 🔴 Simulator mode: \(isRunningOnSimulator)")

        print("[iOS] 🔴 Initializing recording state")
        pointTimestamps = []
        currentGameStartTime = 0  // First game starts at 0
        recordingDuration = 0  // Reset duration for new recording

        scoreState.isRecording = true
        scoreState.recordingStartTime = Date()
        isRecording = true

        print("[iOS] 🔴 Starting duration timer")
        // Start duration timer - capture startTime to avoid accessing MainActor property in timer
        let startTime = scoreState.recordingStartTime ?? Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }

        // Only setup video recording on real device and if camera is enabled
        guard cameraEnabled else {
            print("[iOS] ⏭️ Camera disabled - skipping video recording setup")
            return
        }
        if !isRunningOnSimulator {
            print("[iOS] 🔴 Setting up video recording on real device")
            setupVideoRecording { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    print("[iOS] 🔴 Capture session is ready, now starting recording to file: \(fileURL.path)")
                    self.videoManager?.startRecording(to: fileURL)
                    print("[iOS] 🔴 VideoManager startRecording called")
                }
            }
        } else {
            print("[iOS] ⚠️ Running on simulator - using mock video recording")
        }

        print("[iOS] 🔴 Sending score to watch")
        sendScore()
        print("[iOS] 🔴 Recording initialization complete (actual recording will start when session is ready)")
    }

    func stopRecording() -> URL? {
        durationTimer?.invalidate()
        durationTimer = nil

        var videoURL: URL? = nil

        // Check if camera is enabled
        let cameraEnabled = preferencesService.isCameraEnabled()

        if cameraEnabled {
            if !isRunningOnSimulator {
                videoManager?.stopRecording()
                videoURL = videoManager?.currentVideoURL
                // Stop the capture session to turn off camera/mic
                videoManager?.stopCaptureSession()
            } else {
                // Generate mock video on simulator
                let mockDuration = recordingDuration > 0 ? recordingDuration : 30.0
                print("[iOS] 🎬 Generating mock video (\(Int(mockDuration))s)...")
                videoURL = MockVideoGenerator.generateMockVideo(duration: mockDuration)
            }
        } else {
            print("[iOS] Camera disabled - no video to stop")
        }

        scoreState.isRecording = false
        isRecording = false
        // DON'T reset recordingDuration here - we need it for endMatch()

        sendScore()
        print("[iOS] ⬛ Recording stopped - Video: \(videoURL?.lastPathComponent ?? "none")")

        return videoURL
    }

    func getPointTimestamps() -> [TimeInterval] {
        return pointTimestamps
    }

    // MARK: - Score Actions (Phone is source of truth - instant updates)

    func incrementPlayer1() {
        scorePoint(forPlayer: 1)
    }

    func decrementPlayer1() {
        // Decrement is now handled by undo
        // This method is deprecated but kept for compatibility
        guard scoreState.playerOneScore > 0 else { return }
        scoreState.playerOneScore -= 1
        removeLastPointIfPlayer(1)
        sendScore()
    }

    func incrementPlayer2() {
        scorePoint(forPlayer: 2)
    }

    func decrementPlayer2() {
        // Decrement is now handled by undo
        // This method is deprecated but kept for compatibility
        guard scoreState.playerTwoScore > 0 else { return }
        scoreState.playerTwoScore -= 1
        removeLastPointIfPlayer(2)
        sendScore()
    }

    private func scorePoint(forPlayer player: Int) {
        guard let matchId = currentMatchId else {
            print("[iOS] No active match")
            return
        }

        do {
            // Check if point was won on serve
            let wasServing = ServingLogic.wasPointScoredOnServe(
                scoringPlayer: player,
                servingPlayer: scoreState.servingPlayer
            )

            // Create PointScoredEvent
            let event = PointScoredEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                player: player,
                videoTimestamp: recordingDuration,
                gameNumber: currentGameNumber
            )

            try eventStore.append(event: event)
            
            // Capture orientation after first point (phone is now in stable position)
            if matchExportOrientation == nil {
                matchExportOrientation = MediaExportService.VideoOrientation.current()
                print("[iOS] 📱 Export orientation captured: \(matchExportOrientation!)")
            }

            // Update state
            if player == 1 {
                scoreState.playerOneScore += 1
            } else {
                scoreState.playerTwoScore += 1
            }
            recordPoint(forPlayer: player, wasServing: wasServing)

            // Recalculate current server based on new score
            scoreState.servingPlayer = ServingLogic.calculateCurrentServer(
                firstServer: scoreState.currentGameFirstServer ?? 1,
                playerOneScore: scoreState.playerOneScore,
                playerTwoScore: scoreState.playerTwoScore
            )

            // Attribute any pending highlight to this player
            attributePendingHighlight(toPlayer: player, matchId: matchId)

            sendScore()

            // Announce the new score
            scoreAnnouncer.announceScore(
                playerOneScore: scoreState.playerOneScore,
                playerTwoScore: scoreState.playerTwoScore,
                playerOneName: scoreState.playerOneName,
                playerTwoName: scoreState.playerTwoName
            )
        } catch {
            print("[iOS] Error incrementing player \(player): \(error)")
        }
    }

    private func attributePendingHighlight(toPlayer player: Int, matchId: UUID) {
        guard let highlightId = pendingHighlightId,
              let pendingHighlight = scoreState.pendingHighlight else {
            return
        }

        do {
            // Create attribution event
            let attributionEvent = HighlightAttributedEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                highlightEventId: highlightId,
                player: player
            )

            try eventStore.append(event: attributionEvent)

            // Update the highlight clip with player info
            let attributedClip = HighlightClip(
                id: pendingHighlight.id,
                startTimestamp: pendingHighlight.startTimestamp,
                endTimestamp: pendingHighlight.endTimestamp,
                player: player,
                gameNumber: pendingHighlight.gameNumber
            )

            scoreState.highlightClips.append(attributedClip)
            scoreState.pendingHighlight = nil
            pendingHighlightId = nil

            let playerName = player == 1 ? scoreState.playerOneName : scoreState.playerTwoName
            print("[iOS] ⭐ Highlight attributed to \(playerName ?? "P\(player)")")
        } catch {
            print("[iOS] Error attributing highlight: \(error)")
        }
    }

    // MARK: - Point Recording

    private func recordPoint(forPlayer player: Int, wasServing: Bool = false) {
        guard scoreState.isRecording else { return }

        let videoTimestamp = recordingDuration

        // Add to video timestamps for highlight reel
        pointTimestamps.append(videoTimestamp)

        // Add to state for persistence
        let point = PointEvent(
            player: player,
            timestamp: Date(),
            isHighlight: false,
            videoTimestamp: videoTimestamp,
            wasServing: wasServing
        )
        scoreState.currentGamePoints.append(point)

        print("[iOS] Point recorded at \(String(format: "%.1f", videoTimestamp))s for P\(player)\(wasServing ? " (serving)" : "")")
    }

    private func removeLastPointIfPlayer(_ player: Int) {
        if let last = scoreState.currentGamePoints.last, last.player == player {
            scoreState.currentGamePoints.removeLast()
            if !pointTimestamps.isEmpty {
                pointTimestamps.removeLast()
            }
        }
    }

    // MARK: - Highlight Sound
    
    private func playHighlightSound() {
        // Play system sound (ping/tink)
        AudioServicesPlaySystemSound(1057)  // System sound: "Tink" - a light ping sound
        
        // Also trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        print("[iOS] 🔔 Highlight ping sound played")
    }

    // MARK: - Highlight Marking

    func markHighlight() {
        print("[iOS] markHighlight() called - isRecording=\(scoreState.isRecording), matchId=\(currentMatchId?.uuidString ?? "nil")")
        
        guard scoreState.isRecording else {
            print("[iOS] Not recording - highlight ignored")
            return
        }

        guard let matchId = currentMatchId else {
            print("[iOS] No active match")
            return
        }

        // Get the current video timestamp when highlight button is pressed
        let highlightTimestamp = recordingDuration

        // Find the timestamp of the last scored point (start of highlight clip)
        let lastPointTimestamp = pointTimestamps.last ?? 0

        do {
            // Create HighlightMarkedEvent with video timestamp
            let highlightEvent = HighlightMarkedEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                videoTimestamp: highlightTimestamp,
                player: nil,  // Player will be attributed when next score happens
                gameNumber: currentGameNumber
            )

            try eventStore.append(event: highlightEvent)

            // Create pending highlight clip
            let pendingClip = HighlightClip(
                id: highlightEvent.id,
                startTimestamp: lastPointTimestamp,
                endTimestamp: highlightTimestamp,
                player: nil,
                gameNumber: currentGameNumber
            )

            scoreState.pendingHighlight = pendingClip
            pendingHighlightId = highlightEvent.id

            // Send immediate confirmation to watch with updated highlight count
            sendHighlightConfirmation()

            print("[iOS] ⭐ HIGHLIGHT MARKED at \(String(format: "%.1f", highlightTimestamp))s (clip: \(String(format: "%.1f-%.1f", lastPointTimestamp, highlightTimestamp))s) - waiting for player attribution")
        } catch {
            print("[iOS] Error marking highlight: \(error)")
        }
    }

    // MARK: - Game/Match Control

    func reset() {
        scoreState = ScoreState()
        pointTimestamps = []
        pendingHighlightId = nil
        sendScore()
    }

    func endGame() {
        guard let matchId = currentMatchId else {
            print("[iOS] No active match")
            return
        }

        let winner = scoreState.playerOneScore > scoreState.playerTwoScore ? 1 : 2

        // Calculate game duration
        let gameDuration = recordingDuration - currentGameStartTime

        do {
            // Create GameEndedEvent
            let event = GameEndedEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                gameNumber: currentGameNumber,
                playerOneScore: scoreState.playerOneScore,
                playerTwoScore: scoreState.playerTwoScore,
                winner: winner,
                gameDuration: gameDuration
            )

            try eventStore.append(event: event)

            // Update state (dual-write for now)
            let game = GameResult(
                playerOneScore: scoreState.playerOneScore,
                playerTwoScore: scoreState.playerTwoScore,
                winner: winner,
                timestamp: Date(),
                points: scoreState.currentGamePoints,
                duration: gameDuration,
                firstServer: scoreState.currentGameFirstServer ?? 1
            )

            scoreState.currentMatchGames.append(game)

            if winner == 1 {
                scoreState.playerOneGames += 1
            } else {
                scoreState.playerTwoGames += 1
            }

            // Determine first server for next game (alternate from current game)
            if let firstServerThisGame = scoreState.currentGameFirstServer {
                scoreState.currentGameFirstServer = (firstServerThisGame == 1) ? 2 : 1
                scoreState.servingPlayer = scoreState.currentGameFirstServer!
            }

            // Reset for next game (keep video timestamps for highlight reel)
            scoreState.playerOneScore = 0
            scoreState.playerTwoScore = 0
            scoreState.currentGamePoints = []

            // Track start of next game
            currentGameStartTime = recordingDuration
            currentGameNumber += 1

            sendScore()

            print("[iOS] Game ended: \(game.playerOneScore)-\(game.playerTwoScore) (duration: \(String(format: "%.1f", gameDuration))s)")
            print("[iOS] Next game first server: Player \(scoreState.currentGameFirstServer ?? 1)")
        } catch {
            print("[iOS] Error ending game: \(error)")
        }
    }

    // MARK: - Video Export
    
    func exportMatchVideos(
        from fullVideoURL: URL?,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> (fullVideo: URL?, highlightReel: URL?) {
        guard let fullVideoURL = fullVideoURL else {
            print("[iOS] No video available")
            return (nil, nil)
        }
        
        // Wait a bit to ensure video file is fully written to disk
        try? await Task.sleep(for: .milliseconds(500))
        
        // Verify file exists and is accessible
        guard FileManager.default.fileExists(atPath: fullVideoURL.path) else {
            print("[iOS] ❌ Video file not found at: \(fullVideoURL.path)")
            return (nil, nil)
        }
        
        // Use captured orientation, or fallback to landscape
        let orientation = matchExportOrientation ?? .landscapeLeft
        print("[iOS] 🎬 Exporting videos with orientation: \(orientation)")
        
        // Export full video with correct orientation
        let exportedFullURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("full_\(Date().timeIntervalSince1970).mov")
        
        var exportedFullVideo: URL? = nil
        var exportedHighlightReel: URL? = nil
        
        do {
            let result = try await MediaExportService.exportFullVideo(
                from: fullVideoURL,
                to: exportedFullURL,
                orientation: orientation,
                progressHandler: { progress in
                    progressHandler(progress * 0.5)
                }
            )
            exportedFullVideo = result.outputURL
            print("[iOS] ✅ Full video exported: \(result.outputURL.lastPathComponent)")
        } catch {
            print("[iOS] ❌ Full video export failed: \(error.localizedDescription)")
            exportedFullVideo = fullVideoURL
        }
        
        // Export highlight reel if we have highlights
        let highlightClips = scoreState.highlightClips
        
        guard !highlightClips.isEmpty else {
            print("[iOS] No highlights marked - only saving full video")
            progressHandler(1.0)
            return (exportedFullVideo, nil)
        }
        
        print("[iOS] 🎬 Generating highlight reel with \(highlightClips.count) highlights")
        
        let highlightURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight_\(Date().timeIntervalSince1970).mov")
        
        let clipInfos = highlightClips.map { clip in
            MediaExportService.HighlightClipInfo(
                startTimestamp: clip.startTimestamp,
                endTimestamp: clip.endTimestamp,
                player: clip.player,
                gameNumber: clip.gameNumber
            )
        }
        
        for (index, clip) in highlightClips.enumerated() {
            let playerName = clip.player.map { $0 == 1 ? (scoreState.playerOneName ?? "P1") : (scoreState.playerTwoName ?? "P2") } ?? "?"
            print("[iOS]   Highlight \(index + 1) (\(playerName)): \(String(format: "%.1f-%.1f", clip.startTimestamp, clip.endTimestamp))s")
        }
        
        do {
            let result = try await MediaExportService.exportHighlightReel(
                from: fullVideoURL,
                to: highlightURL,
                clips: clipInfos,
                orientation: orientation,
                progressHandler: { progress in
                    progressHandler(0.5 + progress * 0.5)
                }
            )
            exportedHighlightReel = result.outputURL
            print("[iOS] ✅ Highlight reel saved: \(result.outputURL.lastPathComponent)")
        } catch {
            print("[iOS] ❌ Highlight export failed: \(error.localizedDescription)")
        }
        
        progressHandler(1.0)
        return (exportedFullVideo, exportedHighlightReel)
    }
    
    @available(*, deprecated, renamed: "exportMatchVideos")
    func generateHighlightReel(
        from fullVideoURL: URL?,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> (fullVideo: URL?, highlightReel: URL?) {
        await exportMatchVideos(from: fullVideoURL, progressHandler: progressHandler)
    }

    func setMatchName(_ name: String, player1: String, player2: String) {
        // First, reset any lingering manager state from previous match
        // This ensures clean slate even if resetMatchState wasn't called
        resetMatchScopedManagerState()

        do {
            // Create new match
            let matchId = UUID()
            _ = try eventStore.createMatch(
                id: matchId,
                matchName: name,
                playerOneName: player1,
                playerTwoName: player2,
                startTimestamp: Date()
            )

            currentMatchId = matchId
            currentGameNumber = 0

            // Determine initial server from match history (before resetting scoreState)
            let initialServer = ServingLogic.determineInitialServer(
                matchHistory: scoreState.matchHistory
            )

            // Only create video file URL if camera is enabled
            let cameraEnabled = preferencesService.isCameraEnabled()
            var fileURL: URL? = nil

            if cameraEnabled {
                // Pre-create video file URL (recording will start when GameView appears)
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "match_\(matchId.uuidString).mov"
                fileURL = tempDir.appendingPathComponent(fileName)
                currentVideoURL = fileURL
            } else {
                currentVideoURL = nil
                print("[iOS] Camera disabled - no video will be recorded")
            }

            // Create MatchStartedEvent with video file path and initial server (for replay consistency)
            let event = MatchStartedEvent(
                matchId: matchId,
                sequenceNumber: 0,
                matchName: name,
                playerOneName: player1,
                playerTwoName: player2,
                recordingStartTime: Date(),
                videoFilePath: fileURL?.path,
                initialServer: initialServer
            )

            try eventStore.append(event: event)

            // Use factory method to create clean state, preserving only match history
            scoreState = ScoreState.forNewMatch(
                preservingHistoryFrom: scoreState,
                matchName: name,
                playerOneName: player1,
                playerTwoName: player2,
                initialServer: initialServer,
                recordingStartTime: nil  // Recording starts in GameView.onAppear
            )

            if cameraEnabled {
                print("[iOS] Match started: \(name), video will be saved to: \(fileURL?.lastPathComponent ?? "unknown")")
            } else {
                print("[iOS] Match started: \(name), no video recording")
            }
            print("[iOS] Initial server: Player \(initialServer)")
        } catch {
            print("[iOS] Error starting match: \(error)")
        }

        sendScore()  // Sync names to watch immediately
    }

    func cancelMatch() {
        guard let matchId = currentMatchId else {
            print("[iOS] No active match to cancel")
            return
        }

        // Stop duration timer immediately
        durationTimer?.invalidate()
        durationTimer = nil

        // Stop recording and camera/mic if running (without processing video)
        if !isRunningOnSimulator {
            videoManager?.stopRecording()
            videoManager?.stopCaptureSession()
        }

        do {
            // Delete video files
            if let videoURL = currentVideoURL {
                try? FileManager.default.removeItem(at: videoURL)
                print("[iOS] Deleted video file: \(videoURL.lastPathComponent)")
            }

            // Delete match and all events from database
            try eventStore.deleteMatch(id: matchId)

            // Reset everything
            resetMatchState()

            print("[iOS] Match cancelled and deleted")
        } catch {
            print("[iOS] Error cancelling match: \(error)")
        }
    }

    func endMatch(fullVideoURL: URL?, highlightVideoURL: URL?) {
        guard let matchId = currentMatchId else {
            print("[iOS] No active match to end")
            return
        }

        // Auto-save current game if there are any points scored
        if scoreState.playerOneScore > 0 || scoreState.playerTwoScore > 0 {
            endGame()
        }

        let fullVideoURLString = fullVideoURL?.absoluteString
        let highlightVideoURLString = highlightVideoURL?.absoluteString
        let winner = scoreState.playerOneGames > scoreState.playerTwoGames ? 1 : 2

        // Announce match end with voice
        scoreAnnouncer.announceMatchEnd(
            playerOneName: scoreState.playerOneName,
            playerTwoName: scoreState.playerTwoName,
            playerOneGames: scoreState.playerOneGames,
            playerTwoGames: scoreState.playerTwoGames,
            winner: winner
        )

        do {
            // Create MatchEndedEvent
            let event = MatchEndedEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                playerOneGames: scoreState.playerOneGames,
                playerTwoGames: scoreState.playerTwoGames,
                winner: winner,
                matchDuration: recordingDuration,
                highlightVideoURL: highlightVideoURLString
            )

            try eventStore.append(event: event)

            // Update match metadata
            if let match = try eventStore.getMatch(id: matchId) {
                match.isActive = false
                match.endTimestamp = Date()
                match.playerOneGames = scoreState.playerOneGames
                match.playerTwoGames = scoreState.playerTwoGames
                match.winner = winner
                match.fullVideoURL = fullVideoURLString
                match.highlightVideoURL = highlightVideoURLString
                match.totalDuration = recordingDuration
                try eventStore.updateMatch(match)
            }

            // Store in-memory matchHistory for backwards compatibility (will be removed later)
            let matchResult = MatchResult(
                name: scoreState.currentMatchName,
                playerOneGames: scoreState.playerOneGames,
                playerTwoGames: scoreState.playerTwoGames,
                winner: winner,
                games: scoreState.currentMatchGames,
                timestamp: Date(),
                fullVideoURL: fullVideoURLString,
                highlightVideoURL: highlightVideoURLString,
                duration: recordingDuration
            )
            scoreState.matchHistory.append(matchResult)

            // Auto-generate AI summary in background
            Task {
                await generateAISummary(for: matchResult, allMatches: scoreState.matchHistory)
            }

            // Reset everything
            resetMatchState()

            sendScore()
            print("[iOS] Match ended - Full video: \(fullVideoURLString ?? "none"), Highlights: \(highlightVideoURLString ?? "none")")
        } catch {
            print("[iOS] Error ending match: \(error)")
        }
    }

    // MARK: - AI Summary Generation

    private func generateAISummary(for match: MatchResult, allMatches: [MatchResult]) async {
        // Only available on iOS 26+
        if #available(iOS 26.0, *) {
            print("[iOS] 🤖 Auto-generating AI summary...")
            let summaryService = MatchSummaryService()

            guard summaryService.isAvailable else {
                print("[iOS] 🤖 AI summary not available: \(summaryService.availabilityDescription)")
                return
            }

            if let summary = await summaryService.generateSummary(for: match, allMatches: allMatches) {
                print("[iOS] ✅ AI summary generated: \(summary.matchSummary.headline)")

                // Persist the summary to database
                do {
                    let codableSummary = MatchAnalysisCodable(from: summary)
                    let summaryData = try JSONEncoder().encode(codableSummary)

                    // Find the match in database and save the summary
                    if let matchName = match.name {
                        let descriptor = FetchDescriptor<StoredMatch>(
                            predicate: #Predicate { $0.matchName == matchName }
                        )

                        let matches = try modelContext.fetch(descriptor)
                        if let storedMatch = matches.first {
                            storedMatch.aiSummaryData = summaryData
                            try modelContext.save()
                            print("[iOS] 💾 AI summary saved to database for match: \(matchName)")
                        } else {
                            print("[iOS] ⚠️ Could not find match in database to save summary")
                        }
                    } else {
                        print("[iOS] ⚠️ Match has no name, cannot save AI summary")
                    }
                } catch {
                    print("[iOS] ❌ Failed to save AI summary: \(error.localizedDescription)")
                }
            } else if let error = summaryService.lastError {
                print("[iOS] ❌ AI summary generation failed: \(error.localizedDescription)")
            }
        } else {
            print("[iOS] 🤖 AI summary requires iOS 26+")
        }
    }

    func deleteMatchFromHistory(at index: Int) {
        guard index >= 0 && index < scoreState.matchHistory.count else { return }
        
        let match = scoreState.matchHistory[index]
        
        // Delete associated video files if they exist
        if let fullVideoURLString = match.fullVideoURL,
           let fullVideoURL = URL(string: fullVideoURLString) {
            try? FileManager.default.removeItem(at: fullVideoURL)
        }
        if let highlightVideoURLString = match.highlightVideoURL,
           let highlightVideoURL = URL(string: highlightVideoURLString) {
            try? FileManager.default.removeItem(at: highlightVideoURL)
        }
        
        scoreState.matchHistory.remove(at: index)
        sendScore()
        print("[iOS] Deleted match at index \(index)")
    }

    /// Resets all match-scoped manager state (IDs, timers, URLs, etc.)
    /// Called when ending a match or before starting a new one
    private func resetMatchScopedManagerState() {
        // Stop camera/mic if running
        if !isRunningOnSimulator {
            videoManager?.stopCaptureSession()
        }

        // Clear match/game identifiers
        currentMatchId = nil
        currentGameNumber = 0

        // Clear video/recording state
        currentVideoURL = nil
        currentGameStartTime = 0
        pointTimestamps = []
        pendingHighlightId = nil
        matchExportOrientation = nil

        // Reset recording UI state
        isRecording = false
        recordingDuration = 0
        durationTimer?.invalidate()
        durationTimer = nil

        // Reset watch signal
        shouldEndMatchFromWatch = false
    }

    /// Resets all state for a new match
    /// Uses ScoreState.forNewMatch to ensure nothing is missed
    private func resetMatchState() {
        // Reset manager-side state
        resetMatchScopedManagerState()

        // Reset ScoreState, preserving only match history
        scoreState = ScoreState(
            matchHistory: scoreState.matchHistory
        )
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let isReachable = session.isReachable
        let isPaired = session.isPaired
        let isWatchAppInstalled = session.isWatchAppInstalled
        let hasContext = !session.applicationContext.isEmpty
        
        Task { @MainActor in
            self.isWatchReachable = isReachable
            self.isWatchAppInstalled = isPaired && isWatchAppInstalled
            if hasContext {
                self.isWatchAppInstalled = true
            }
        }
        print("[iOS] Session activated: \(activationState.rawValue), Paired: \(isPaired), Watch app installed: \(isWatchAppInstalled), Reachable: \(isReachable)")
        if hasContext {
            print("[iOS] Watch app detected via application context")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        print("[iOS] Session inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = isReachable
        }
        print("[iOS] Reachability: \(isReachable)")
    }

    // Receive messages from watch
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let messageData = WatchMessageData(from: message)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let messageData = WatchMessageData(from: message)
        // Wrap replyHandler to make it Sendable - WCSession guarantees it's safe to call from any thread
        let sendableReply = UnsafeSendable(replyHandler)
        Task { @MainActor in
            self.handleMessageData(messageData)
            let scoreStateCopy = self.scoreState
            sendableReply.value(scoreStateCopy.toDictionary())
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let messageData = WatchMessageData(from: applicationContext)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
    }

    private func handleMessageData(_ messageData: WatchMessageData) {
        // Any message from watch means the watch app is installed and connected
        self.isWatchAppInstalled = true

        // Check for commands from watch
        if let command = messageData.command {
            switch command {
            case "incrementP1":
                self.incrementPlayer1()
                print("[iOS] Command: incrementP1")

            case "incrementP2":
                self.incrementPlayer2()
                print("[iOS] Command: incrementP2")

            case "highlight":
                self.playHighlightSound()
                self.markHighlight()
                print("[iOS] Command: highlight from watch")

            case "endGame":
                self.endGame()

            case "endMatch":
                // Watch requested match end - signal GameView to trigger the same flow as phone button
                self.shouldEndMatchFromWatch = true
                print("[iOS] Command: endMatch from watch - signaling GameView")

            case "requestSync":
                self.sendScore()
                print("[iOS] Command: requestSync")

            default:
                print("[iOS] Unknown command: \(command)")
            }
            return
        }

        // Parse as full state update (shouldn't happen often - watch sends commands)
        guard let newState = messageData.scoreState else {
            return
        }

        self.scoreState = newState
        print("[iOS] Received state update")
    }
}

// MARK: - Video Recording Manager

@MainActor
class VideoRecordingManager: NSObject, ObservableObject {
    @Published var error: String?
    @Published var captureSession: AVCaptureSession?

    private var videoOutput: AVCaptureMovieFileOutput?
    var currentVideoURL: URL?
    
    // Store camera settings for recording
    private var cameraDeviceType: CameraDeviceType = .wide
    private var videoQualityPreset: VideoQualityPreset = .hd720p

    nonisolated deinit {
        // Note: deinit is nonisolated in Swift 6, cannot access MainActor-isolated properties directly
        // The capture session will be cleaned up by the system
        print("[Video] 🧹 VideoRecordingManager deallocated")
    }
    
    func configure(deviceType: CameraDeviceType, quality: VideoQualityPreset) {
        self.cameraDeviceType = deviceType
        self.videoQualityPreset = quality
        print("[Video] 🎥 Configured with deviceType: \(deviceType.displayName), quality: \(quality.displayName)")
    }

    func setupCaptureSession(completion: @escaping @Sendable () -> Void) {
        print("[Video] 🎥 setupCaptureSession called")

        // Check authorization
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("[Video] 🎥 Camera authorization status: \(authStatus.rawValue)")

        switch authStatus {
        case .authorized:
            print("[Video] 🎥 Camera authorized, configuring capture session")
            configureCaptureSession(completion: completion)
        case .notDetermined:
            print("[Video] 🎥 Camera permission not determined, requesting access")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("[Video] 🎥 Camera permission granted: \(granted)")
                if granted {
                    Task { @MainActor in
                        self?.configureCaptureSession(completion: completion)
                    }
                } else {
                    print("[Video] ❌ Camera permission denied by user")
                }
            }
        default:
            print("[Video] ❌ Camera access denied (status: \(authStatus.rawValue))")
            Task { @MainActor in
                self.error = "Camera access denied"
            }
        }
    }

    private func configureCaptureSession(completion: @escaping @Sendable () -> Void) {
        print("[Video] 🎥 configureCaptureSession START")

        let session = AVCaptureSession()
        print("[Video] 🎥 Created AVCaptureSession")

        // Apply user's quality preference
        if session.canSetSessionPreset(videoQualityPreset.avPreset) {
            session.sessionPreset = videoQualityPreset.avPreset
            print("[Video] 🎥 Set session preset to \(videoQualityPreset.displayName)")
        } else {
            session.sessionPreset = .hd1280x720
            print("[Video] 🎥 Preset \(videoQualityPreset.displayName) not supported, falling back to HD 720p")
        }

        // Video input - use user's preferred camera lens
        print("[Video] 🎥 Getting video device (preferred: \(cameraDeviceType.displayName))...")
        let videoDevice = getPreferredCameraDevice()
        guard let device = videoDevice else {
            print("[Video] ❌ Failed to get video device")
            DispatchQueue.main.async {
                self.error = "Failed to access camera device"
            }
            return
        }
        print("[Video] 🎥 Got video device: \(device.localizedName)")

        print("[Video] 🎥 Creating video input...")
        guard let videoInput = try? AVCaptureDeviceInput(device: device) else {
            print("[Video] ❌ Failed to create video input")
            DispatchQueue.main.async {
                self.error = "Failed to create video input"
            }
            return
        }
        print("[Video] 🎥 Created video input")

        print("[Video] 🎥 Checking if can add video input to session...")
        guard session.canAddInput(videoInput) else {
            print("[Video] ❌ Cannot add video input to session")
            DispatchQueue.main.async {
                self.error = "Cannot add video input to session"
            }
            return
        }
        print("[Video] 🎥 Adding video input to session...")
        session.addInput(videoInput)
        print("[Video] ✅ Video input added successfully")

        // Audio input (optional - silently fail if not available)
        print("[Video] 🎥 Attempting to add audio input...")
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            print("[Video] 🎥 Got audio device: \(audioDevice.localizedName)")
            if let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
                print("[Video] 🎥 Created audio input")
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    print("[Video] ✅ Audio input added successfully")
                } else {
                    print("[Video] ⚠️ Cannot add audio input to session")
                }
            } else {
                print("[Video] ⚠️ Failed to create audio input")
            }
        } else {
            print("[Video] ⚠️ No audio device available - recording video only")
        }

        // Movie output
        print("[Video] 🎥 Creating movie output...")
        let movieOutput = AVCaptureMovieFileOutput()
        print("[Video] 🎥 Checking if can add movie output...")
        if session.canAddOutput(movieOutput) {
            print("[Video] 🎥 Adding movie output to session...")
            session.addOutput(movieOutput)
            self.videoOutput = movieOutput
            print("[Video] ✅ Movie output added successfully")
        } else {
            print("[Video] ❌ Cannot add movie output to session")
        }

        // Set capture session on main thread so SwiftUI can react
        DispatchQueue.main.async {
            self.captureSession = session
            print("[Video] 🎥 Capture session assigned to @Published property")
        }

        print("[Video] 🎥 Capture session configured, starting session on background thread...")

        DispatchQueue.global(qos: .userInitiated).async {
            print("[Video] 🎥 Calling session.startRunning()...")
            session.startRunning()
            print("[Video] ✅ Session is running: \(session.isRunning)")

            // Wait a moment for the session to stabilize, then call completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("[Video] ✅ Session ready, calling completion handler")
                completion()
            }
        }

        print("[Video] 🎥 configureCaptureSession END (session starting asynchronously)")
    }

    func startRecording(to fileURL: URL) {
        print("[Video] 📹 startRecording(to:) called with URL: \(fileURL.path)")

        guard let output = videoOutput else {
            print("[Video] ❌ videoOutput is nil, cannot start recording")
            return
        }

        guard !output.isRecording else {
            print("[Video] ⚠️ Already recording, ignoring startRecording call")
            return
        }

        // Set video orientation for recording
        if let connection = output.connection(with: .video) {
            let deviceOrientation = UIDevice.current.orientation
            let rotationAngle: CGFloat

            switch deviceOrientation {
            case .portrait:
                rotationAngle = 90
            case .portraitUpsideDown:
                rotationAngle = 270
            case .landscapeLeft:
                rotationAngle = 0
            case .landscapeRight:
                rotationAngle = 180
            default:
                rotationAngle = 90
            }

            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                print("[Video] 📱 Recording orientation set to angle: \(rotationAngle)")
            }
        }

        print("[Video] 📹 Calling AVCaptureMovieFileOutput.startRecording...")
        output.startRecording(to: fileURL, recordingDelegate: self)
        currentVideoURL = fileURL

        print("[Video] ✅ Started recording to: \(fileURL.lastPathComponent)")
    }

    func stopRecording() {
        guard let output = videoOutput, output.isRecording else { return }
        output.stopRecording()
        print("[Video] Stopped recording")
    }

    func stopCaptureSession() {
        guard let session = captureSession else { return }

        Task.detached {
            if session.isRunning {
                session.stopRunning()
                print("[Video] 📹 Capture session stopped - camera/mic released")
            }
        }

        // Clear the session reference (already on MainActor)
        self.captureSession = nil
        self.videoOutput = nil
        print("[Video] 📹 Capture session cleaned up")
    }
    
    // MARK: - Camera Device Selection
    
    private func getPreferredCameraDevice() -> AVCaptureDevice? {
        // Try to get the user's preferred camera device type
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [cameraDeviceType.avDeviceType],
            mediaType: .video,
            position: .back
        )
        
        if let preferredDevice = discoverySession.devices.first {
            print("[Video] 🎥 Using preferred camera: \(cameraDeviceType.displayName)")
            return preferredDevice
        }
        
        // Fall back to wide angle camera if preferred isn't available
        print("[Video] 🎥 Preferred camera \(cameraDeviceType.displayName) not available, falling back to wide angle")
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}

extension VideoRecordingManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("[Video] ✅ DELEGATE: Recording started successfully to: \(fileURL.lastPathComponent)")
        print("[Video] ✅ DELEGATE: Connections count: \(connections.count)")
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("[Video] ❌ DELEGATE: Recording error: \(error.localizedDescription)")
            print("[Video] ❌ DELEGATE: Error code: \((error as NSError).code)")
            return
        }
        print("[Video] ✅ DELEGATE: Recording finished successfully: \(outputFileURL.path)")
    }
}
