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
import CoreMedia
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
    /// Unique per watch command (a UUID string). One command can arrive by `sendMessage` and again by the
    /// watch's `transferUserInfo` fallback; the phone applies each id once. Nil from older watch builds.
    let actionId: String?
    /// When the watch issued the command (`timeIntervalSince1970`). Nil from older watch builds.
    let sentAt: TimeInterval?
    let scoreState: ScoreState?

    init(from message: [String: Any]) {
        self.command = message["command"] as? String
        self.actionId = message["actionId"] as? String
        self.sentAt = message["sentAt"] as? TimeInterval
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
    var isWatchPaired = false
    var isWatchAppInstalled = false  // paired and installed

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
    /// Tests turn this off so no FoundationModels task outlives them.
    var generatesSummaries = true

    /// Wall-clock origin of every stored offset (persisted in MatchStartedEvent.recordingStartTime).
    private var matchClockOrigin: Date?
    private var automaticSegmentRestarts = 0

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
        loadMatchHistory()
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
            matchClockOrigin = scoreState.recordingStartTime
            if scoreState.isRecording, let startTime = scoreState.recordingStartTime {
                recordingDuration = Date().timeIntervalSince(startTime)
                startDurationTimer(from: startTime)
                // Camera-off matches still announce; resumeVideoRecordingIfNeeded re-activates for capture
                AudioSessionCoordinator.activateForMatch(recording: false)
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
            var projected = try stateProjector.project(events: events, matchMetadata: match)
            // A projection covers the active match only; keep the finished matches loaded at launch
            projected.matchHistory = scoreState.matchHistory
            scoreState = projected
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
        matchWonBy = ScoreAnnouncementUtils.checkMatchWon(
            playerOneGames: state.playerOneGames, playerTwoGames: state.playerTwoGames, bestOf: Self.bestOf)
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
            let manager = VideoRecordingManager()
            manager.onSegmentStarted = { [weak self] url, date in
                self?.recordSegmentStarted(url: url, at: date)
            }
            manager.onInterruptionEnded = { [weak self] in
                self?.startNextSegment()
            }
            manager.onSegmentInterrupted = { [weak self] url, sessionInterrupted in
                Log.match.warning(
                    "⚠️ Recording segment \(url.lastPathComponent) ended by the system (session interrupted: \(sessionInterrupted))"
                )
                guard !sessionInterrupted else { return }  // onInterruptionEnded restarts capture
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    self?.restartSegmentAfterSystemStop()
                }
            }
            videoManager = manager
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
            // @Sendable: WatchConnectivity calls the handler on its own queue. A main-actor closure (the default
            // in this main-actor method) would fail Swift 6's executor check there and trap.
            session.sendMessage(message, replyHandler: nil) { @Sendable error in
                Log.match.error("Error sending highlight confirmation: \(error.localizedDescription)")
            }
            Log.match.debug("⭐ Highlight confirmation sent instantly to watch (count: \(highlightCount))")
            try? session.updateApplicationContext(message)  // keep the snapshot current for a later launch
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
            // @Sendable: called on WatchConnectivity's queue (see sendHighlightConfirmation).
            session.sendMessage(message, replyHandler: nil) { @Sendable error in
                Log.match.error("Error sending: \(error.localizedDescription)")
            }
        }

        do {
            try session.updateApplicationContext(message)
            Log.match.info("Updated context: P1=\(self.scoreState.playerOneScore) P2=\(self.scoreState.playerTwoScore)")
        } catch {
            Log.match.warning("Watch context update failed: \(error.localizedDescription)")  // app works standalone
        }
    }

    // MARK: - Recording Control

    /// Marks the match as live (watch scoring, point timestamps, highlights) and, when the camera is
    /// enabled, starts video capture. The match is live even without a camera.
    /// Marks the match as live (watch scoring, point timestamps, highlights) and, when the camera is
    /// enabled, starts video capture. The match is live even without a camera.
    func startRecording() {
        guard let matchId = currentMatchId else {
            Log.match.error("⚠️ startRecording called without an active match")
            return
        }
        let cameraEnabled = preferencesService.isCameraEnabled()
        let capturesVideo = cameraEnabled && !isRunningOnSimulator
        Log.match.debug("🔴 startRecording (camera enabled: \(cameraEnabled), simulator: \(self.isRunningOnSimulator))")

        pointTimestamps = []
        currentGameStartTime = 0  // First game starts at 0
        recordingDuration = 0

        // Offsets are measured from the persisted match clock so replay and relaunch agree
        let startTime = matchClockOrigin ?? scoreState.recordingStartTime ?? Date()
        matchClockOrigin = startTime
        scoreState.isRecording = true
        scoreState.recordingStartTime = startTime
        isRecording = true
        startDurationTimer(from: startTime)
        AudioSessionCoordinator.activateForMatch(recording: capturesVideo)

        if capturesVideo {
            startVideoCapture(matchId: matchId)
        } else if cameraEnabled {
            Log.match.warning("⚠️ Simulator - a mock video is generated at match end")
        } else {
            Log.match.debug("⏭️ Camera disabled - scoring only")
        }

        sendScore()
    }

    /// Configures the capture session (creating it if needed) and starts a new recording segment.
    private func startVideoCapture(matchId: UUID) {
        Log.match.debug("🔴 Setting up video capture for match \(matchId)")
        setupVideoRecording { [weak self] in
            Task { @MainActor in
                self?.startNextSegment()
            }
        }
    }

    /// Starts writing the next movie file. Segment index = number of segments already started.
    private func startNextSegment() {
        guard let matchId = currentMatchId, let manager = videoManager, isRecording else { return }
        let index = scoreState.recordingSegments.count
        manager.startRecording(to: VideoStore.fileURL(matchId: matchId, kind: .rawSegment(index: index)))
    }

    /// The movie file ended while the session kept running: start another segment, a few times at most.
    private func restartSegmentAfterSystemStop() {
        guard isRecording, let manager = videoManager, manager.captureSession != nil else { return }
        automaticSegmentRestarts += 1
        guard automaticSegmentRestarts <= 3 else {
            manager.markFailed("recording keeps stopping; check free space")
            return
        }
        startNextSegment()
    }

    /// Call when the match screen (re)appears: after a relaunch or an interruption the capture
    /// session may be gone or idle while the match is still live.
    func resumeVideoRecordingIfNeeded() {
        guard isRecording, let matchId = currentMatchId, preferencesService.isCameraEnabled(), !isRunningOnSimulator
        else { return }
        if let manager = videoManager, manager.state.isRecording { return }
        AudioSessionCoordinator.activateForMatch(recording: true)
        if videoManager?.captureSession == nil {
            startVideoCapture(matchId: matchId)
        } else {
            startNextSegment()
        }
    }

    /// Persists the start of a movie file so export (and a relaunch) know what footage exists and
    /// where it sits on the match clock.
    private func recordSegmentStarted(url: URL, at date: Date) {
        guard let matchId = currentMatchId else { return }
        let offset = max(0, date.timeIntervalSince(scoreState.recordingStartTime ?? date))
        let reference = VideoStore.storedReference(for: url)
        do {
            let event = RecordingSegmentStartedEvent(
                matchId: matchId,
                sequenceNumber: try eventStore.getNextSequenceNumber(matchId: matchId),
                fileReference: reference,
                startOffset: offset
            )
            try eventStore.append(event: event)
            scoreState.recordingSegments.append(RecordingSegment(fileReference: reference, startOffset: offset))
            automaticSegmentRestarts = 0
            Log.match.info(
                "🎬 Segment \(self.scoreState.recordingSegments.count) started at +\(String(format: "%.1f", offset))s")
        } catch {
            Log.match.error("Error recording segment start: \(error)")
        }
    }

    /// Stops recording and returns the finished movie file once AVFoundation has finalized it.
    /// Stops the match clock and, if capturing, the camera; the finished footage is described by
    /// `scoreState.recordingSegments` for exportMatchVideos().
    func stopRecording() async {
        durationTimer?.invalidate()
        durationTimer = nil

        if preferencesService.isCameraEnabled() {
            if !isRunningOnSimulator {
                // Waits for the file to be fully written before the capture session is torn down
                _ = await videoManager?.stopRecording()
                videoManager?.stopCaptureSession()
            } else if let matchId = currentMatchId {
                let mockDuration = recordingDuration > 0 ? recordingDuration : 30.0
                Log.match.debug("🎬 Generating mock video (\(Int(mockDuration))s)...")
                let target = VideoStore.fileURL(matchId: matchId, kind: .mock)
                if let url = await MockVideoGenerator.generateMockVideo(duration: mockDuration, to: target) {
                    scoreState.recordingSegments = [
                        RecordingSegment(fileReference: VideoStore.storedReference(for: url), startOffset: 0)
                    ]
                }
            }
        } else {
            Log.match.debug("Camera disabled - no video to stop")
        }

        scoreState.isRecording = false
        isRecording = false
        // DON'T reset recordingDuration here - we need it for endMatch()

        sendScore()
        Log.match.info("⬛ Recording stopped - segments: \(self.scoreState.recordingSegments.count)")
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

    /// Player whose point the '-' button would remove: the last point of the current game, or, right
    /// after a game ended, the point that ended it (undo reopens that game).
    var lastPointPlayer: Int? {
        if let last = scoreState.currentGamePoints.last { return last.player }
        guard scoreState.pendingHighlight == nil else { return nil }
        return scoreState.currentMatchGames.last?.points.last?.player
    }

    /// Removes the last point if `player` scored it, through the event log so undo and relaunch agree.
    func undoPoint(forPlayer player: Int) {
        guard lastPointPlayer == player, let matchId = currentMatchId else { return }
        applyUndo { try undoService.undoLastPoint(in: matchId) }
    }

    /// Undoes the most recent point or highlight mark in the current game.
    func undoLastAction() {
        guard let matchId = currentMatchId else { return }
        applyUndo { try undoService.undoLastAction(in: matchId) }
    }

    private func applyUndo(_ operation: () throws -> UUID?) {
        do {
            if try operation() != nil {
                refreshState()  // also recomputes matchWonBy from the games
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
        // A highlight still pending ended with the game-winning rally: credit the game winner
        if scoreState.pendingHighlight != nil {
            attributePendingHighlight(toPlayer: winner, matchId: matchId)
        }
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

            matchWonBy = ScoreAnnouncementUtils.checkMatchWon(
                playerOneGames: scoreState.playerOneGames,
                playerTwoGames: scoreState.playerTwoGames,
                bestOf: Self.bestOf
            )
            announceGameEnd(game: game, winner: winner)

            sendScore()
            Log.match.info(
                "Game ended: \(game.playerOneScore)-\(game.playerTwoScore) (duration: \(String(format: "%.1f", gameDuration))s), games \(self.scoreState.playerOneGames)-\(self.scoreState.playerTwoGames)"
            )
        } catch {
            Log.match.error("Error ending game: \(error)")
        }
    }

    private func announceGameEnd(game: GameResult, winner: Int) {
        if let matchWinner = matchWonBy {
            scoreAnnouncer.announce(
                "Game and match to \(name(for: matchWinner)), \(scoreState.playerOneGames) games to \(scoreState.playerTwoGames)"
            )
        } else {
            scoreAnnouncer.announce("Game to \(name(for: winner)), \(game.playerOneScore) \(game.playerTwoScore)")
        }
    }

    // MARK: - Video Export

    /// Exports the full match (all segments concatenated, upright) and, when highlights exist, the
    /// highlight reel. Returns nil for whatever could not be produced.
    func exportMatchVideos(
        progressHandler: @escaping MediaExportService.ProgressHandler = { _ in }
    ) async -> (fullVideo: URL?, highlightReel: URL?) {
        guard let matchId = currentMatchId else { return (nil, nil) }
        let timeline = await loadTimeline()
        let segmentURLs = timeline.segments.compactMap { VideoStore.resolve($0.fileReference) }
        guard !segmentURLs.isEmpty else {
            Log.match.warning("No recorded footage to export")
            return (nil, nil)
        }
        let quality = MediaExportService.ExportQuality.matching(
            VideoQualityPreset.from(string: preferencesService.getCameraSettings().qualityPreset))
        Log.match.info("🎬 Exporting \(segmentURLs.count) segment(s), \(Int(timeline.totalDuration))s of footage")

        // Which way up each segment really is, from the pictures (Vision body pose; logged per segment)
        let corrections = await VideoOrientationDetector.corrections(for: segmentURLs)
        Log.match.info("🧭 Orientation corrections per segment: \(corrections.map(\.rawValue), privacy: .public)")

        let fullURL = VideoStore.fileURL(matchId: matchId, kind: .full)
        var fullVideo: URL?
        do {
            let result = try await MediaExportService.exportFullVideo(
                segments: segmentURLs,
                corrections: corrections,
                to: fullURL,
                quality: quality,
                progressHandler: { progress in progressHandler(progress * 0.5) }
            )
            fullVideo = result.outputURL
            Log.match.info("✅ Full video exported: \(result.outputURL.lastPathComponent)")
        } catch {
            Log.match.error("❌ Full video export failed: \(error.localizedDescription)")
            fullVideo = segmentURLs.count == 1 ? segmentURLs[0] : nil  // keep the raw file as the full video
        }

        let highlightReel = await exportHighlightReel(
            matchId: matchId,
            from: fullVideo,
            timeline: timeline,
            quality: quality,
            progressHandler: { progress in progressHandler(0.5 + progress * 0.5) }
        )

        // Raw segments are no longer needed once the full video has been written
        if fullVideo == fullURL {
            for url in segmentURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        progressHandler(1.0)
        return (fullVideo, highlightReel)
    }

    /// Segments that exist on disk, with their durations, in capture order.
    private func loadTimeline() async -> RecordingTimeline {
        var segments: [RecordingSegment] = []
        for segment in scoreState.recordingSegments {
            guard let url = VideoStore.resolve(segment.fileReference), FileManager.default.fileExists(atPath: url.path)
            else {
                Log.match.warning("⚠️ Missing recording segment \(segment.fileReference)")
                continue
            }
            do {
                let duration = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
                segments.append(
                    RecordingSegment(
                        fileReference: segment.fileReference, startOffset: segment.startOffset, duration: duration))
            } catch {
                Log.match.error("❌ Unreadable recording segment \(segment.fileReference): \(error)")
            }
        }
        return RecordingTimeline(segments: segments)
    }

    /// Cuts the marked highlight clips (wall-clock ranges) out of the exported full video, with the broadcast
    /// scoreboard burned in. Returns nil when there are no clips with footage or the export fails.
    private func exportHighlightReel(
        matchId: UUID,
        from source: URL?,
        timeline: RecordingTimeline,
        quality: MediaExportService.ExportQuality,
        progressHandler: @escaping MediaExportService.ProgressHandler
    ) async -> URL? {
        guard let source else { return nil }
        // A highlight marked after the final point is still pending; it belongs in the reel too
        let marked = scoreState.highlightClips + (scoreState.pendingHighlight.map { [$0] } ?? [])
        // Reel order = marked order: the clips (video time) and the scoreboard's view of them (wall clock) line up
        var clips: [MediaExportService.HighlightClipInfo] = []
        var reelClips: [ReelClip] = []
        for clip in marked {
            guard let range = timeline.videoRange(wallStart: clip.startTimestamp, wallEnd: clip.endTimestamp) else {
                Log.match.warning("⚠️ Highlight \(clip.id) has no footage (recording was paused)")
                continue
            }
            clips.append(
                MediaExportService.HighlightClipInfo(
                    startTimestamp: range.lowerBound, endTimestamp: range.upperBound, player: clip.player,
                    gameNumber: clip.gameNumber))
            reelClips.append(ReelClip(highlight: clip, reelDuration: range.upperBound - range.lowerBound))
        }
        guard !clips.isEmpty else {
            Log.match.debug("No highlight footage - only saving full video")
            return nil
        }
        Log.match.info("🎬 Generating highlight reel with \(clips.count) of \(marked.count) highlights")

        let cues = ReelScoreboardTimeline(scoreState: scoreState).cues(for: reelClips)
        let scoreboard: [OverlayCue]
        do {
            scoreboard = try await MediaExportService.scoreboardOverlays(cues, forReelFrom: source)
        } catch {
            Log.match.error("❌ Reel scoreboard not rendered, exporting without it: \(error.localizedDescription)")
            scoreboard = []
        }
        Log.match.info("🎬 Reel scoreboard: \(cues.count) cue(s), \(scoreboard.count) rendered")

        do {
            let result = try await MediaExportService.exportHighlightReel(
                from: source,
                to: VideoStore.fileURL(matchId: matchId, kind: .highlights),
                clips: clips,
                scoreboard: scoreboard,
                quality: quality,
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
            let startTime = Date()
            matchClockOrigin = startTime
            _ = try eventStore.createMatch(
                id: matchId,
                matchName: name,
                playerOneName: player1,
                playerTwoName: player2,
                startTimestamp: startTime
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
                // First recording segment (recording starts when GameView appears)
                fileURL = VideoStore.fileURL(matchId: matchId, kind: .rawSegment(index: 0))
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
                recordingStartTime: startTime,
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
                recordingStartTime: startTime  // the match clock; startRecording() marks it live
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
            // Delete every video file of this match
            VideoStore.removeAll(matchId: matchId)

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
    /// Stops recording, exports the videos and finalizes the active match. Concurrent calls are ignored.
    /// Returns false when the match could not be persisted (it then stays active).
    @discardableResult
    func finishActiveMatch() async -> Bool {
        guard !isExporting, let matchId = currentMatchId else { return false }
        isExporting = true
        exportProgress = 0
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true  // exports take minutes; don't auto-lock mid-way
        defer {
            isExporting = false
            UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
        }

        await stopRecording()
        let (fullVideo, highlightReel) = await exportMatchVideos { [weak self] progress in
            self?.exportProgress = progress
        }
        return endMatch(matchId: matchId, fullVideoURL: fullVideo, highlightVideoURL: highlightReel)
    }

    /// Called when the watch asks to end the match; GameView runs the same flow as the phone button.
    func requestEndMatchFromWatch() {
        guard currentMatchId != nil else { return }
        endMatchRequestCount += 1
        Log.match.debug("Command: endMatch from watch (request #\(self.endMatchRequestCount))")
    }

    @discardableResult
    func endMatch(fullVideoURL: URL?, highlightVideoURL: URL?) -> Bool {
        endMatch(matchId: currentMatchId, fullVideoURL: fullVideoURL, highlightVideoURL: highlightVideoURL)
    }

    /// Finalizes `matchId`. A finished game that was not yet recorded is saved; an unfinished game is
    /// discarded, never awarded. The match winner is by games; a tie has no winner.
    @discardableResult
    func endMatch(matchId: UUID?, fullVideoURL: URL?, highlightVideoURL: URL?) -> Bool {
        guard let matchId, matchId == currentMatchId else {
            Log.match.warning("No active match to end (requested \(matchId?.uuidString ?? "nil"))")
            return false
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
        // Whoever leads on games wins (covers early ends and playing on after a decided match)
        let winner = games1 == games2 ? MatchResult.noWinner : (games1 > games2 ? 1 : 2)

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
            if matchResult.hasWinner && generatesSummaries {
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
            return true
        } catch {
            Log.match.error("Error ending match: \(error)")
            return false
        }
    }

    /// Appends the MatchEndedEvent, updates the stored match metadata and returns the in-memory result.
    private func persistMatchEnd(
        matchId: UUID,
        winner: Int,
        fullVideoURL: URL?,
        highlightVideoURL: URL?
    ) throws -> MatchResult {
        // Store-relative file names, so the references survive container moves (see VideoStore)
        let fullVideoURLString = fullVideoURL.map { VideoStore.storedReference(for: $0) }
        let highlightVideoURLString = highlightVideoURL.map { VideoStore.storedReference(for: $0) }

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

        // History entries are dated by match start, here and when they are reloaded at launch
        var startTimestamp = Date()
        if let match = try eventStore.getMatch(id: matchId) {
            startTimestamp = match.startTimestamp
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
            highlightClips: scoreState.highlightClips + (scoreState.pendingHighlight.map { [$0] } ?? []),
            timestamp: startTimestamp,
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

    // MARK: - Match History

    /// Rebuilds `scoreState.matchHistory` from the finished matches in the store, oldest first, so the
    /// history screens, the next match's first server and the AI head-to-head context survive relaunches.
    private func loadMatchHistory() {
        let finished: [StoredMatch]
        do {
            // getAllMatches is newest first; history is oldest first (ServingLogic reads `.last`)
            finished = try eventStore.getAllMatches().filter { !$0.isActive }.reversed()
        } catch {
            Log.match.error("Error loading match history: \(error)")
            return
        }

        var history: [MatchResult] = []
        for match in finished {
            migrateLegacyVideos(of: match)
            do {
                let events = try eventStore.getEvents(matchId: match.id)
                let projected = try stateProjector.project(events: events, matchMetadata: match)
                history.append(
                    MatchResult(
                        id: match.id,
                        name: match.matchName,
                        playerOneName: match.playerOneName,
                        playerTwoName: match.playerTwoName,
                        playerOneGames: match.playerOneGames,
                        playerTwoGames: match.playerTwoGames,
                        winner: match.winner ?? MatchResult.noWinner,
                        games: projected.currentMatchGames,
                        highlightClips: projected.highlightClips + (projected.pendingHighlight.map { [$0] } ?? []),
                        timestamp: match.startTimestamp,
                        fullVideoURL: match.fullVideoURL,
                        highlightVideoURL: match.highlightVideoURL,
                        duration: match.totalDuration
                    ))
            } catch {
                Log.match.error("Skipping match \(match.id) in history: \(error)")
            }
        }
        scoreState.matchHistory = history
        Log.match.info("Loaded \(history.count) finished matches into history")
    }

    /// Best effort: moves videos still referenced at their legacy absolute location (tmp/, which iOS purges)
    /// into VideoStore and points the match at the new file names. Missing files are left referenced as-is.
    private func migrateLegacyVideos(of match: StoredMatch) {
        func migrated(_ reference: String?, kind: VideoStore.Kind) -> String? {
            guard let source = VideoStore.resolve(reference) else { return reference }
            let current = VideoStore.storedReference(for: source)
            guard current != source.lastPathComponent else { return current }  // already in the store
            let fileManager = FileManager.default
            let destination = VideoStore.fileURL(matchId: match.id, kind: kind)
            // A store file for this match and kind is the canonical copy (e.g. moved on an earlier launch whose
            // save failed). Otherwise take the legacy file at its recorded path or, because an app update can
            // move the container, under the same name in the current tmp/.
            if !fileManager.fileExists(atPath: destination.path) {
                let candidates = [source, URL.temporaryDirectory.appending(path: source.lastPathComponent)]
                guard let legacy = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                    return reference
                }
                do {
                    try fileManager.moveItem(at: legacy, to: destination)
                    Log.match.info("Moved legacy video \(legacy.lastPathComponent) to \(destination.lastPathComponent)")
                } catch {
                    Log.match.warning("Could not move legacy video \(legacy.lastPathComponent): \(error)")
                    return reference
                }
            }
            return VideoStore.storedReference(for: destination)
        }

        let full = migrated(match.fullVideoURL, kind: .full)
        let highlights = migrated(match.highlightVideoURL, kind: .highlights)
        guard full != match.fullVideoURL || highlights != match.highlightVideoURL else { return }
        match.fullVideoURL = full
        match.highlightVideoURL = highlights
        do {
            try eventStore.updateMatch(match)
        } catch {
            Log.match.error("Error saving migrated video references for match \(match.id): \(error)")
        }
    }

    /// Deletes a finished match everywhere: its StoredMatch and events, its video files and its history entry.
    func deleteMatchFromHistory(at index: Int) {
        guard scoreState.matchHistory.indices.contains(index) else { return }
        let match = scoreState.matchHistory[index]

        do {
            try eventStore.deleteMatch(id: match.id)
        } catch EventStoreError.matchNotFound {
            Log.match.warning("Match \(match.id) was not in the store; removing it from history only")
        } catch {
            Log.match.error("Error deleting match \(match.id): \(error)")
            return  // keep the entry so the list matches what will reload on next launch
        }

        // Legacy references point outside the store, so remove their files explicitly as well
        VideoStore.remove(match.fullVideoURL)
        VideoStore.remove(match.highlightVideoURL)
        VideoStore.removeAll(matchId: match.id)

        scoreState.matchHistory.remove(at: index)
        sendScore()
        Log.match.info("Deleted match \(match.id) from history")
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

        // Release the audio session once the match-end announcement has been spoken,
        // unless a new match has gone live in the meantime
        scoreAnnouncer.performWhenIdle { [weak self] in
            if self?.isRecording != true {
                AudioSessionCoordinator.deactivate()
            }
        }
        matchClockOrigin = nil
        automaticSegmentRestarts = 0

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
