//
//  WatchConnectivityManager.swift
//  score (iOS)
//
//  Manages communication between iOS and watchOS
//  Handles video recording and highlight marking
//
// File length is known debt (see AGENTS.md "Known debt"); split planned.
// swiftlint:disable file_length

@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Observation
import SwiftData
import UIKit
@preconcurrency import WatchConnectivity

#if canImport(FoundationModels)
    import FoundationModels
    import os
#endif

/// Sendable wrapper for WCSession message data (iOS side)
nonisolated struct WatchMessageData: Sendable {
    let command: String?
    let scoreState: ScoreState?

    init(from message: [String: Any]) {
        self.command = message["command"] as? String
        self.scoreState = ScoreState(dictionary: message)
    }
}

/// Wrapper to make non-Sendable values sendable when you know it's safe
/// Used for WCSession reply handlers which are safe to call from any thread
nonisolated struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Phone-side hub: owns match lifecycle, scoring, recording and the WCSession transport.
/// TODO(debt): split the match lifecycle (start/score/end/persist) out into its own type so
/// this class is only the watch transport. Tracked in AGENTS.md "Known debt".
@MainActor
@Observable
// swiftlint:disable:next type_body_length
class WatchConnectivityManager: NSObject {
    var scoreState = ScoreState()
    var isWatchReachable = false
    var isWatchAppInstalled = false

    // Video recording
    var isRecording = false
    var recordingDuration: TimeInterval = 0

    /// Incremented for every "end match" request from the watch; GameView acts on increases.
    var endMatchRequestCount = 0
    /// Set when a game win decides the match (best of `bestOf`); the UI offers to end the match.
    var matchWonBy: Int?
    /// True while finishActiveMatch() is stopping, exporting and persisting.
    var isExporting = false
    var exportProgress: Double = 0

    /// Matches are played as best of five.
    static let bestOf = 5

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
            guard let activeMatch = try eventStore.getActiveMatch() else { return }
            currentMatchId = activeMatch.id
            Log.match.info("Loading active match: \(activeMatch.matchName)")

            let events = try eventStore.getEvents(matchId: activeMatch.id)
            scoreState = try stateProjector.project(events: events, matchMetadata: activeMatch)
            syncCaches(with: scoreState)

            // Restore the video file path from the MatchStartedEvent
            if let started = events.first(where: { $0.eventType == EventType.matchStarted.rawValue }),
                let event = try? JSONDecoder().decode(MatchStartedEvent.self, from: started.eventData),
                let videoPath = event.videoFilePath
            {
                currentVideoURL = URL(fileURLWithPath: videoPath)
                if !FileManager.default.fileExists(atPath: videoPath) {
                    Log.match.warning("⚠️ Video file missing at \(videoPath) - recording may have been interrupted")
                }
            }

            isRecording = scoreState.isRecording
            if scoreState.isRecording, let startTime = scoreState.recordingStartTime {
                recordingDuration = Date().timeIntervalSince(startTime)
                startDurationTimer(from: startTime)
            }

            Log.match.info(
                "Loaded match state: \(self.scoreState.playerOneGames)-\(self.scoreState.playerTwoGames), Recording: \(self.isRecording)"
            )
        } catch {
            Log.match.error("Error loading active match: \(error)")
        }
    }

    func refreshState() {
        guard let matchId = currentMatchId else { return }

        do {
            guard let match = try eventStore.getMatch(id: matchId) else { return }
            let events = try eventStore.getEvents(matchId: matchId)
            scoreState = try stateProjector.project(events: events, matchMetadata: match)
            syncCaches(with: scoreState)
        } catch {
            Log.match.error("Error refreshing state: \(error)")
        }
    }

    /// Re-derives the manager-side caches from a freshly projected state (after undo or relaunch).
    private func syncCaches(with state: ScoreState) {
        currentGameNumber = state.currentMatchGames.count
        pointTimestamps =
            state.currentMatchGames.flatMap { $0.points.compactMap(\.videoTimestamp) }
            + state.currentGamePoints.compactMap(\.videoTimestamp)
        pendingHighlightId = state.pendingHighlight?.id
        currentGameStartTime = state.currentMatchGames.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    private func startDurationTimer(from startTime: Date) {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    // MARK: - Video Recording Setup

    func setupVideoRecording(completion: @escaping @Sendable () -> Void) {
        Log.match.debug("📹 setupVideoRecording called, videoManager exists: \(self.videoManager != nil)")
        if videoManager == nil {
            Log.match.debug("📹 Creating new VideoRecordingManager")
            videoManager = VideoRecordingManager()
        }

        // Apply user's camera settings from preferences
        let (deviceTypeStr, qualityStr) = preferencesService.getCameraSettings()
        let deviceType = CameraDeviceType.from(string: deviceTypeStr)
        let quality = VideoQualityPreset.from(string: qualityStr)
        videoManager?.configure(deviceType: deviceType, quality: quality)

        Log.match.debug("📹 Calling setupCaptureSession")
        videoManager?.setupCaptureSession(completion: completion)
    }

    // MARK: - Send to Watch

    private func sendHighlightConfirmation() {
        guard let session else { return }
        guard session.isPaired && session.isWatchAppInstalled else { return }

        // Calculate current highlight count
        let highlightCount = scoreState.highlightClips.count + (scoreState.pendingHighlight != nil ? 1 : 0)

        var message = scoreState.toDictionary()
        message["highlightConfirmed"] = true
        message["highlightCount"] = highlightCount

        // Use sendMessage for instant delivery (high priority)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                Log.match.error("Error sending highlight confirmation: \(error.localizedDescription)")
            }
            Log.match.debug("⭐ Highlight confirmation sent instantly to watch (count: \(highlightCount))")
        } else {
            // Fallback to context if not reachable
            do {
                try session.updateApplicationContext(message)
            } catch {
                Log.match.error("Error updating context: \(error.localizedDescription)")
            }
        }
    }

    func sendScore() {
        guard let session else { return }

        // Only try to send if watch is paired and app is installed
        guard session.isPaired && session.isWatchAppInstalled else {
            return
        }

        let message = scoreState.toDictionary()

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                Log.match.error("Error sending: \(error.localizedDescription)")
            }
        }

        do {
            try session.updateApplicationContext(message)
            Log.match.info("Updated context: P1=\(self.scoreState.playerOneScore) P2=\(self.scoreState.playerTwoScore)")
        } catch {
            // Silently ignore watch sync errors - app works standalone
        }
    }

    // MARK: - Recording Control

    /// Marks the match as live (watch scoring, point timestamps, highlights) and, when the camera is
    /// enabled, starts video capture. The match is live even without a camera.
    func startRecording() {
        guard currentMatchId != nil else {
            Log.match.error("⚠️ startRecording called without an active match")
            return
        }
        let cameraEnabled = preferencesService.isCameraEnabled()
        Log.match.debug("🔴 startRecording (camera enabled: \(cameraEnabled), simulator: \(self.isRunningOnSimulator))")

        pointTimestamps = []
        currentGameStartTime = 0  // First game starts at 0
        recordingDuration = 0

        let startTime = Date()
        scoreState.isRecording = true
        scoreState.recordingStartTime = startTime
        isRecording = true
        startDurationTimer(from: startTime)

        if cameraEnabled, let fileURL = currentVideoURL, !isRunningOnSimulator {
            Log.match.debug("🔴 Setting up video recording to \(fileURL.lastPathComponent)")
            setupVideoRecording { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.videoManager?.startRecording(to: fileURL)
                }
            }
        } else if cameraEnabled {
            Log.match.warning("⚠️ Simulator or no video URL - a mock video is generated at match end")
        } else {
            Log.match.debug("⏭️ Camera disabled - scoring only")
        }

        sendScore()
    }

    /// Stops recording and returns the finished movie file once AVFoundation has finalized it.
    func stopRecording() async -> URL? {
        durationTimer?.invalidate()
        durationTimer = nil

        var videoURL: URL?

        if preferencesService.isCameraEnabled() {
            if !isRunningOnSimulator {
                // Waits for the file to be fully written before the capture session is torn down
                videoURL = await videoManager?.stopRecording()
                videoManager?.stopCaptureSession()
            } else {
                // Generate mock video on simulator
                let mockDuration = recordingDuration > 0 ? recordingDuration : 30.0
                Log.match.debug("🎬 Generating mock video (\(Int(mockDuration))s)...")
                videoURL = await MockVideoGenerator.generateMockVideo(duration: mockDuration)
            }
        } else {
            Log.match.debug("Camera disabled - no video to stop")
        }

        scoreState.isRecording = false
        isRecording = false
        // DON'T reset recordingDuration here - we need it for endMatch()

        sendScore()
        Log.match.info("⬛ Recording stopped - Video: \(videoURL?.lastPathComponent ?? "none")")

        return videoURL
    }

    func getPointTimestamps() -> [TimeInterval] {
        return pointTimestamps
    }

    // MARK: - Score Actions (Phone is source of truth - instant updates)

    func incrementPlayer1() {
        scorePoint(forPlayer: 1)
    }

    func incrementPlayer2() {
        scorePoint(forPlayer: 2)
    }

    /// Player who scored the most recent live point of the current game, if any.
    var lastPointPlayer: Int? {
        scoreState.currentGamePoints.last?.player
    }

    /// Removes the last point if `player` scored it, through the event log so undo and relaunch agree.
    func undoPoint(forPlayer player: Int) {
        guard lastPointPlayer == player else { return }
        undoLastAction()
    }

    /// Undoes the most recent point or highlight mark in the current game.
    func undoLastAction() {
        guard let matchId = currentMatchId else { return }
        do {
            if try undoService.undoLastAction(in: matchId) != nil {
                matchWonBy = nil
                refreshState()
                sendScore()
            }
        } catch {
            Log.match.error("Error undoing: \(error)")
        }
    }

    private func scorePoint(forPlayer player: Int) {
        guard let matchId = currentMatchId else {
            Log.match.debug("No active match")
            return
        }

        do {
            // Check if point was won on serve
            let wasServing = ServingLogic.wasPointScoredOnServe(
                scoringPlayer: player,
                servingPlayer: scoreState.servingPlayer
            )

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
                let orientation = MediaExportService.VideoOrientation.current()
                matchExportOrientation = orientation
                Log.match.debug("📱 Export orientation captured: \(orientation)")
            }

            if player == 1 {
                scoreState.playerOneScore += 1
            } else {
                scoreState.playerTwoScore += 1
            }
            recordPoint(forPlayer: player, wasServing: wasServing)

            scoreState.servingPlayer = ServingLogic.calculateCurrentServer(
                firstServer: scoreState.currentGameFirstServer ?? 1,
                playerOneScore: scoreState.playerOneScore,
                playerTwoScore: scoreState.playerTwoScore
            )

            // Attribute any pending highlight to this player
            attributePendingHighlight(toPlayer: player, matchId: matchId)

            // First to 11, win by 2: the game ends itself
            if let gameWinner = ScoreAnnouncementUtils.checkGameWon(
                playerOneScore: scoreState.playerOneScore, playerTwoScore: scoreState.playerTwoScore)
            {
                finalizeGame(winner: gameWinner)
                return
            }

            sendScore()
            scoreAnnouncer.announceScore(
                playerOneScore: scoreState.playerOneScore,
                playerTwoScore: scoreState.playerTwoScore,
                playerOneName: scoreState.playerOneName,
                playerTwoName: scoreState.playerTwoName
            )
        } catch {
            Log.match.error("Error incrementing player \(player): \(error)")
        }
    }

    private func attributePendingHighlight(toPlayer player: Int, matchId: UUID) {
        guard let highlightId = pendingHighlightId,
            let pendingHighlight = scoreState.pendingHighlight
        else {
            return
        }

        do {
            let attributionEvent = HighlightAttributedEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                highlightEventId: highlightId,
                player: player
            )
            try eventStore.append(event: attributionEvent)

            scoreState.highlightClips.append(
                HighlightClip(
                    id: pendingHighlight.id,
                    startTimestamp: pendingHighlight.startTimestamp,
                    endTimestamp: pendingHighlight.endTimestamp,
                    player: player,
                    gameNumber: pendingHighlight.gameNumber
                )
            )
            scoreState.pendingHighlight = nil
            pendingHighlightId = nil
            Log.match.info("⭐ Highlight attributed to \(self.name(for: player))")
        } catch {
            Log.match.error("Error attributing highlight: \(error)")
        }
    }

    /// Display name for player 1 or 2.
    func name(for player: Int) -> String {
        player == 1 ? (scoreState.playerOneName ?? "Player 1") : (scoreState.playerTwoName ?? "Player 2")
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

        Log.match.debug(
            "Point recorded at \(String(format: "%.1f", videoTimestamp))s for P\(player)\(wasServing ? " (serving)" : "")"
        )
    }

    // MARK: - Highlight Sound

    func playHighlightSound() {
        // Play system sound (ping/tink)
        AudioServicesPlaySystemSound(1057)  // System sound: "Tink" - a light ping sound

        // Also trigger haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        Log.match.debug("🔔 Highlight ping sound played")
    }

    // MARK: - Highlight Marking

    func markHighlight() {
        Log.match.debug(
            "markHighlight() called - isRecording=\(self.scoreState.isRecording), matchId=\(self.currentMatchId?.uuidString ?? "nil")"
        )

        guard scoreState.isRecording else {
            Log.match.debug("Not recording - highlight ignored")
            return
        }

        guard let matchId = currentMatchId else {
            Log.match.debug("No active match")
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

            if let pending = scoreState.pendingHighlight {
                // Second mark before the next point: same rally, extend the pending clip (first id wins)
                scoreState.pendingHighlight = HighlightClip(
                    id: pending.id,
                    startTimestamp: pending.startTimestamp,
                    endTimestamp: max(pending.endTimestamp, highlightTimestamp),
                    player: nil,
                    gameNumber: pending.gameNumber
                )
            } else {
                scoreState.pendingHighlight = pendingClip
                pendingHighlightId = highlightEvent.id
            }

            // Send immediate confirmation to watch with updated highlight count
            sendHighlightConfirmation()

            Log.match.info(
                "⭐ HIGHLIGHT MARKED at \(String(format: "%.1f", highlightTimestamp))s (clip: \(String(format: "%.1f-%.1f", lastPointTimestamp, highlightTimestamp))s) - waiting for player attribution"
            )
        } catch {
            Log.match.error("Error marking highlight: \(error)")
        }
    }

    // MARK: - Game/Match Control

    func reset() {
        scoreState = ScoreState()
        pointTimestamps = []
        pendingHighlightId = nil
        sendScore()
    }

    /// Ends the current game. Without `force` the game must be won (11+, two clear); with `force`
    /// (an explicit user decision) an unfinished game is awarded to the leader. Ties are never ended.
    @discardableResult
    func endGame(force: Bool = false) -> Bool {
        guard currentMatchId != nil else {
            Log.match.debug("No active match")
            return false
        }
        let p1 = scoreState.playerOneScore
        let p2 = scoreState.playerTwoScore
        let winner: Int
        if let won = ScoreAnnouncementUtils.checkGameWon(playerOneScore: p1, playerTwoScore: p2) {
            winner = won
        } else if force, p1 != p2 {
            winner = p1 > p2 ? 1 : 2
        } else {
            Log.match.warning("End game ignored: \(p1)-\(p2) is not a finished game")
            sendScore()  // resync the watch so it does not wait on a dropped command
            return false
        }
        finalizeGame(winner: winner)
        return true
    }

    private func finalizeGame(winner: Int) {
        guard let matchId = currentMatchId else { return }
        let gameDuration = recordingDuration - currentGameStartTime

        do {
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

            // First server alternates between games
            if let firstServerThisGame = scoreState.currentGameFirstServer {
                let nextServer = firstServerThisGame == 1 ? 2 : 1
                scoreState.currentGameFirstServer = nextServer
                scoreState.servingPlayer = nextServer
            }

            scoreState.playerOneScore = 0
            scoreState.playerTwoScore = 0
            scoreState.currentGamePoints = []
            currentGameStartTime = recordingDuration
            currentGameNumber += 1

            let matchWinner = ScoreAnnouncementUtils.checkMatchWon(
                playerOneGames: scoreState.playerOneGames,
                playerTwoGames: scoreState.playerTwoGames,
                bestOf: Self.bestOf
            )
            matchWonBy = matchWinner
            if let matchWinner {
                scoreAnnouncer.announce(
                    "Game and match to \(name(for: matchWinner)), \(scoreState.playerOneGames) games to \(scoreState.playerTwoGames)"
                )
            } else {
                scoreAnnouncer.announce("Game to \(name(for: winner)), \(game.playerOneScore) \(game.playerTwoScore)")
            }

            sendScore()
            Log.match.info(
                "Game ended: \(game.playerOneScore)-\(game.playerTwoScore) (duration: \(String(format: "%.1f", gameDuration))s), games \(self.scoreState.playerOneGames)-\(self.scoreState.playerTwoGames)"
            )
        } catch {
            Log.match.error("Error ending game: \(error)")
        }
    }

    // MARK: - Video Export

    func exportMatchVideos(
        from fullVideoURL: URL?,
        progressHandler: @escaping MediaExportService.ProgressHandler = { _ in }
    ) async -> (fullVideo: URL?, highlightReel: URL?) {
        guard let fullVideoURL else {
            Log.match.debug("No video available")
            return (nil, nil)
        }
        guard FileManager.default.fileExists(atPath: fullVideoURL.path) else {
            Log.match.error("❌ Video file not found at: \(fullVideoURL.path)")
            return (nil, nil)
        }

        // Use captured orientation, or fall back to landscape
        let orientation = matchExportOrientation ?? .landscapeLeft
        Log.match.info("🎬 Exporting videos with orientation: \(orientation)")

        let exportedFullURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("full_\(Date().timeIntervalSince1970).mov")
        var exportedFullVideo: URL?
        do {
            let result = try await MediaExportService.exportFullVideo(
                from: fullVideoURL,
                to: exportedFullURL,
                orientation: orientation,
                progressHandler: { progress in progressHandler(progress * 0.5) }
            )
            exportedFullVideo = result.outputURL
            Log.match.info("✅ Full video exported: \(result.outputURL.lastPathComponent)")
        } catch {
            Log.match.error("❌ Full video export failed: \(error.localizedDescription)")
            exportedFullVideo = fullVideoURL
        }

        let highlightReel = await exportHighlightReel(
            from: fullVideoURL,
            orientation: orientation,
            progressHandler: { progress in progressHandler(0.5 + progress * 0.5) }
        )
        progressHandler(1.0)
        return (exportedFullVideo, highlightReel)
    }

    /// Cuts the marked highlight clips out of the full recording.
    /// Returns nil when there are no clips or the export fails.
    private func exportHighlightReel(
        from fullVideoURL: URL,
        orientation: MediaExportService.VideoOrientation,
        progressHandler: @escaping MediaExportService.ProgressHandler
    ) async -> URL? {
        // A highlight marked after the final point is still pending; it belongs in the reel too
        let highlightClips = scoreState.highlightClips + (scoreState.pendingHighlight.map { [$0] } ?? [])
        guard !highlightClips.isEmpty else {
            Log.match.debug("No highlights marked - only saving full video")
            return nil
        }
        Log.match.info("🎬 Generating highlight reel with \(highlightClips.count) highlights")

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

        do {
            let result = try await MediaExportService.exportHighlightReel(
                from: fullVideoURL,
                to: highlightURL,
                clips: clipInfos,
                orientation: orientation,
                progressHandler: progressHandler
            )
            Log.match.info("✅ Highlight reel saved: \(result.outputURL.lastPathComponent)")
            return result.outputURL
        } catch {
            Log.match.error("❌ Highlight export failed: \(error.localizedDescription)")
            return nil
        }
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
            var fileURL: URL?

            if cameraEnabled {
                // Pre-create video file URL (recording will start when GameView appears)
                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "match_\(matchId.uuidString).mov"
                fileURL = tempDir.appendingPathComponent(fileName)
                currentVideoURL = fileURL
            } else {
                currentVideoURL = nil
                Log.match.debug("Camera disabled - no video will be recorded")
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
                Log.match.info(
                    "Match started: \(name), video will be saved to: \(fileURL?.lastPathComponent ?? "unknown")")
            } else {
                Log.match.info("Match started: \(name), no video recording")
            }
            Log.match.debug("Initial server: Player \(initialServer)")
        } catch {
            Log.match.error("Error starting match: \(error)")
        }

        sendScore()  // Sync names to watch immediately
    }

    func cancelMatch() async {
        guard let matchId = currentMatchId else {
            Log.match.debug("No active match to cancel")
            return
        }

        // Stop duration timer immediately
        durationTimer?.invalidate()
        durationTimer = nil

        // Stop recording and camera/mic if running (without processing video).
        // Await finalization so the file delete below is not raced by AVFoundation.
        if !isRunningOnSimulator {
            _ = await videoManager?.stopRecording()
            videoManager?.stopCaptureSession()
        }

        do {
            // Delete video files
            if let videoURL = currentVideoURL {
                try? FileManager.default.removeItem(at: videoURL)
                Log.match.info("Deleted video file: \(videoURL.lastPathComponent)")
            }

            // Delete match and all events from database
            try eventStore.deleteMatch(id: matchId)

            // Reset everything and tell the watch the match is gone
            resetMatchState()
            sendScore()

            Log.match.debug("Match cancelled and deleted")
        } catch {
            Log.match.error("Error cancelling match: \(error)")
        }
    }

    /// Stops recording, exports the videos and finalizes the active match. Concurrent calls are ignored.
    func finishActiveMatch() async {
        guard !isExporting, let matchId = currentMatchId else { return }
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        let videoURL = await stopRecording()
        let (fullVideo, highlightReel) = await exportMatchVideos(from: videoURL) { [weak self] progress in
            self?.exportProgress = progress
        }
        endMatch(matchId: matchId, fullVideoURL: fullVideo, highlightVideoURL: highlightReel)
    }

    /// Called when the watch asks to end the match; GameView runs the same flow as the phone button.
    func requestEndMatchFromWatch() {
        guard currentMatchId != nil else { return }
        endMatchRequestCount += 1
        Log.match.debug("Command: endMatch from watch (request #\(self.endMatchRequestCount))")
    }

    func endMatch(fullVideoURL: URL?, highlightVideoURL: URL?) {
        endMatch(matchId: currentMatchId, fullVideoURL: fullVideoURL, highlightVideoURL: highlightVideoURL)
    }

    /// Finalizes `matchId`. A finished game that was not yet recorded is saved; an unfinished game is
    /// discarded, never awarded. The match winner is by games; a tie has no winner.
    func endMatch(matchId: UUID?, fullVideoURL: URL?, highlightVideoURL: URL?) {
        guard let matchId, matchId == currentMatchId else {
            Log.match.warning("No active match to end (requested \(matchId?.uuidString ?? "nil"))")
            return
        }

        let p1 = scoreState.playerOneScore
        let p2 = scoreState.playerTwoScore
        if ScoreAnnouncementUtils.checkGameWon(playerOneScore: p1, playerTwoScore: p2) != nil {
            endGame()
        } else if p1 > 0 || p2 > 0 {
            Log.match.info("Discarding unfinished game \(p1)-\(p2)")
        }

        let games1 = scoreState.playerOneGames
        let games2 = scoreState.playerTwoGames
        let winner: Int
        if let decided = ScoreAnnouncementUtils.checkMatchWon(
            playerOneGames: games1, playerTwoGames: games2, bestOf: Self.bestOf)
        {
            winner = decided
        } else if games1 != games2 {
            winner = games1 > games2 ? 1 : 2  // ended early: leader on games
        } else {
            winner = MatchResult.noWinner
        }

        scoreAnnouncer.announceMatchEnd(
            playerOneName: scoreState.playerOneName,
            playerTwoName: scoreState.playerTwoName,
            playerOneGames: games1,
            playerTwoGames: games2,
            winner: winner
        )

        do {
            let matchResult = try persistMatchEnd(
                matchId: matchId,
                winner: winner,
                fullVideoURL: fullVideoURL,
                highlightVideoURL: highlightVideoURL
            )
            scoreState.matchHistory.append(matchResult)

            // Auto-generate AI summary in background (only for decided matches)
            if matchResult.hasWinner {
                let historySnapshot = scoreState.matchHistory
                Task {
                    await generateAISummary(for: matchResult, matchId: matchId, allMatches: historySnapshot)
                }
            }

            resetMatchState()
            sendScore()
            Log.match.info(
                "Match ended \(games1)-\(games2) (winner \(winner)) - Full video: \(fullVideoURL?.lastPathComponent ?? "none"), Highlights: \(highlightVideoURL?.lastPathComponent ?? "none")"
            )
        } catch {
            Log.match.error("Error ending match: \(error)")
        }
    }

    /// Appends the MatchEndedEvent, updates the stored match metadata and returns the in-memory result.
    private func persistMatchEnd(
        matchId: UUID,
        winner: Int,
        fullVideoURL: URL?,
        highlightVideoURL: URL?
    ) throws -> MatchResult {
        let fullVideoURLString = fullVideoURL?.absoluteString
        let highlightVideoURLString = highlightVideoURL?.absoluteString

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

        return MatchResult(
            id: matchId,
            name: scoreState.currentMatchName,
            playerOneName: scoreState.playerOneName,
            playerTwoName: scoreState.playerTwoName,
            playerOneGames: scoreState.playerOneGames,
            playerTwoGames: scoreState.playerTwoGames,
            winner: winner,
            games: scoreState.currentMatchGames,
            timestamp: Date(),
            fullVideoURL: fullVideoURLString,
            highlightVideoURL: highlightVideoURLString,
            duration: recordingDuration
        )
    }

    // MARK: - AI Summary Generation

    /// Generates and saves the summary through the shared service, which persists it by
    /// `match.id` (== `matchId`) and joins a generation already running for this match (e.g. one
    /// started from the detail view) instead of racing it.
    private func generateAISummary(for match: MatchResult, matchId: UUID, allMatches: [MatchResult]) async {
        Log.match.debug("🤖 Auto-generating AI summary for match \(matchId)")
        let result = await MatchSummaryService.shared.generateAndStoreSummary(
            for: match, history: allMatches, store: eventStore)
        switch result {
        case .success(let summary):
            Log.match.info("✅ AI summary generated for match \(matchId): \(summary.matchSummary.headline)")
        case .failure(let error):
            Log.match.warning("🤖 No AI summary for match \(matchId): \(error.localizedDescription)")
        }
    }

    func deleteMatchFromHistory(at index: Int) {
        guard index >= 0 && index < scoreState.matchHistory.count else { return }

        let match = scoreState.matchHistory[index]

        // Delete associated video files if they exist
        if let fullVideoURLString = match.fullVideoURL,
            let fullVideoURL = URL(string: fullVideoURLString)
        {
            try? FileManager.default.removeItem(at: fullVideoURL)
        }
        if let highlightVideoURLString = match.highlightVideoURL,
            let highlightVideoURL = URL(string: highlightVideoURLString)
        {
            try? FileManager.default.removeItem(at: highlightVideoURL)
        }

        scoreState.matchHistory.remove(at: index)
        sendScore()
        Log.match.info("Deleted match at index \(index)")
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

        // Reset UI signals
        endMatchRequestCount = 0
        matchWonBy = nil
        exportProgress = 0
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
