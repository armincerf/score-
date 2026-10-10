//
//  WatchSessionManager.swift
//  scorewatch Watch App
//
//  Manages communication between watchOS and iOS
//  Includes highlight marking via Double Tap gesture
//

import Foundation
import Observation
@preconcurrency import WatchConnectivity
import os

/// Sendable wrapper for WCSession message data
nonisolated struct MessageData: Sendable {
    let highlightConfirmed: Bool?
    let highlightCount: Int?
    let hasPendingHighlight: Bool?
    let playerOneScore: Int?
    let playerTwoScore: Int?
    let playerOneGames: Int?
    let playerTwoGames: Int?
    let isRecording: Bool?
    let playerOneName: String?
    let playerTwoName: String?
    let servingPlayer: Int?
    let currentGameFirstServer: Int?
    let recordingStartTime: TimeInterval?
    let currentMatchGamesData: Data?
    let matchHistoryData: Data?
    let currentGamePointsData: Data?

    init(from message: [String: Any]) {
        self.highlightConfirmed = message["highlightConfirmed"] as? Bool
        self.highlightCount = message["highlightCount"] as? Int
        self.hasPendingHighlight = message["hasPendingHighlight"] as? Bool
        self.playerOneScore = message["playerOneScore"] as? Int
        self.playerTwoScore = message["playerTwoScore"] as? Int
        self.playerOneGames = message["playerOneGames"] as? Int
        self.playerTwoGames = message["playerTwoGames"] as? Int
        self.isRecording = message["isRecording"] as? Bool
        self.playerOneName = message["playerOneName"] as? String
        self.playerTwoName = message["playerTwoName"] as? String
        self.servingPlayer = message["servingPlayer"] as? Int
        self.currentGameFirstServer = message["currentGameFirstServer"] as? Int
        self.recordingStartTime = message["recordingStartTime"] as? TimeInterval
        self.currentMatchGamesData = message["currentMatchGames"] as? Data
        self.matchHistoryData = message["matchHistory"] as? Data
        self.currentGamePointsData = message["currentGamePoints"] as? Data
    }

    func toScoreState() -> ScoreState? {
        guard let p1Score = playerOneScore, let p2Score = playerTwoScore else { return nil }

        var currentMatchGames: [GameResult] = []
        var matchHistory: [MatchResult] = []
        var currentGamePoints: [PointEvent] = []

        if let gamesData = currentMatchGamesData {
            currentMatchGames = (try? JSONDecoder().decode([GameResult].self, from: gamesData)) ?? []
        }

        if let matchData = matchHistoryData {
            matchHistory = (try? JSONDecoder().decode([MatchResult].self, from: matchData)) ?? []
        }

        if let pointsData = currentGamePointsData {
            currentGamePoints = (try? JSONDecoder().decode([PointEvent].self, from: pointsData)) ?? []
        }

        var state = ScoreState(
            playerOneScore: p1Score,
            playerTwoScore: p2Score,
            playerOneGames: playerOneGames ?? 0,
            playerTwoGames: playerTwoGames ?? 0,
            currentMatchGames: currentMatchGames,
            matchHistory: matchHistory,
            currentGamePoints: currentGamePoints,
            hasPendingHighlight: hasPendingHighlight ?? false,
            highlightCount: highlightCount ?? 0,
            isRecording: isRecording ?? false,
            playerOneName: playerOneName,
            playerTwoName: playerTwoName,
            servingPlayer: servingPlayer ?? 1,
            currentGameFirstServer: currentGameFirstServer
        )

        if let startTimeInterval = recordingStartTime {
            state.recordingStartTime = Date(timeIntervalSince1970: startTimeInterval)
        }

        return state
    }
}

/// One command for the phone. `actionId` is unique per command so the phone applies it once even when it arrives
/// both live and from the `transferUserInfo` queue; `sentAt` is when the watch issued it.
nonisolated struct WatchCommand: Sendable {
    nonisolated enum Name: String, Sendable {
        case incrementP1
        case incrementP2
        case highlight
        case endGame
        case endMatch
        case requestSync

        /// Score and highlight commands set `pendingAction` and are confirmed by the phone's state.
        var awaitsConfirmation: Bool {
            switch self {
            case .incrementP1, .incrementP2, .highlight: true
            case .endGame, .endMatch, .requestSync: false
            }
        }
    }

    let name: Name
    let actionId: String
    let sentAt: TimeInterval

    init(_ name: Name, actionId: String = UUID().uuidString, sentAt: Date = Date()) {
        self.name = name
        self.actionId = actionId
        self.sentAt = sentAt.timeIntervalSince1970
    }

    /// The WatchConnectivity payload (property-list values only).
    var payload: [String: Any] {
        ["command": name.rawValue, "actionId": actionId, "sentAt": sentAt]
    }
}

@MainActor
@Observable
final class WatchSessionManager: NSObject {
    var scoreState = ScoreState()
    var isConnected = false
    var highlightCount = 0  // Track highlights marked this session
    /// The score/highlight action waiting for the phone to confirm it; the UI dims that control meanwhile.
    private(set) var pendingAction: PendingAction?
    /// Commands queued with `transferUserInfo` that have not reached the phone yet.
    private(set) var queuedCommandCount = 0
    /// Bumped whenever a command fails or goes unconfirmed; drives the `.error` haptic.
    private(set) var failedCommandCount = 0

    enum PendingAction {
        case player1Score
        case player2Score
        case highlight
    }

    private var session: WCSession?
    private var pendingTimer: Timer?
    private var pendingActionId: String?
    /// The most recent user command handed to WatchConnectivity (live or queued). Only it may be re-queued after a
    /// failed live send: anything older would reach the phone after a later command.
    private var lastCommandId: String?

    override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    // MARK: - Send to iPhone

    /// Sends a user command: live with `sendMessage` when the phone is reachable (the reply is the phone's state),
    /// otherwise queued with `transferUserInfo`, which delivers in order, eventually, even if the app exits.
    /// The phone dedupes by `actionId`, so a command sent both ways is applied once.
    /// - Returns: true when the command was handed to WatchConnectivity (live or queued), so the caller plays
    ///   its success haptic.
    private func send(_ name: WatchCommand.Name, pending action: PendingAction? = nil) -> Bool {
        guard let session, session.activationState == .activated else {
            Log.session.error("Cannot send \(name.rawValue): session not activated")
            signalFailure()
            return false
        }
        let command = WatchCommand(name)
        lastCommandId = command.actionId
        // While earlier commands are still queued, queue behind them so the phone applies taps in order.
        if session.isReachable && session.outstandingUserInfoTransfers.isEmpty {
            if let action {
                beginPending(action, actionId: command.actionId)
            }
            sendLive(command, on: session)
        } else {
            enqueue(command, on: session)
        }
        return true
    }

    /// Asks the phone for its state. Live only: an unreachable phone pushes its state through the application
    /// context anyway, so a queued sync would be stale on arrival.
    private func requestSync() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        sendLive(WatchCommand(.requestSync), on: session)
        Log.session.debug("Requested sync from phone")
    }

    private func sendLive(_ command: WatchCommand, on session: WCSession) {
        // WatchConnectivity calls both handlers on a background queue: @Sendable keeps them off the main actor,
        // and only Sendable values cross into the hop.
        session.sendMessage(
            command.payload,
            replyHandler: { @Sendable [weak self] reply in
                let state = MessageData(from: reply)
                Task { @MainActor in
                    self?.didReceiveReply(state, to: command)
                }
            },
            errorHandler: { @Sendable [weak self] error in
                let reason = error.localizedDescription
                Task { @MainActor in
                    self?.liveSendFailed(command, reason: reason)
                }
            })
    }

    private func enqueue(_ command: WatchCommand, on session: WCSession) {
        session.transferUserInfo(command.payload)
        refreshQueuedCommandCount()
        Log.session.info(
            "Queued \(command.name.rawValue) until the phone is reachable (\(self.queuedCommandCount) queued)")
    }

    /// Recounts the outstanding transfers on the main actor, so a `didFinish` computed before a newer `enqueue`
    /// cannot overwrite the badge with a stale count. `finishedActionId` is the transfer that just completed,
    /// which may still be listed while its delegate callback runs.
    private func refreshQueuedCommandCount(excluding finishedActionId: String? = nil) {
        guard let session else {
            queuedCommandCount = 0
            return
        }
        queuedCommandCount = session.outstandingUserInfoTransfers.count { transfer in
            finishedActionId == nil || (transfer.userInfo["actionId"] as? String) != finishedActionId
        }
    }

    /// The phone answers every live command with its full state.
    private func didReceiveReply(_ state: MessageData, to command: WatchCommand) {
        handleMessageData(state)
        if pendingActionId == command.actionId {
            clearPendingState()
        }
    }

    /// The live send failed: the phone was not reachable after all, delivery failed, or the reply never came (the
    /// phone may still have applied it). The command is queued again under the same `actionId`, which the phone
    /// drops if it is a duplicate, but only while a retry is what the user expects:
    /// - it is still the latest command, so the phone cannot apply it after a later one (a retried End Game
    ///   arriving after the next game's points would end that game);
    /// - a score/highlight tap is still pending. Once the 2 s timeout has fired the user has felt the error
    ///   haptic and may have tapped again, so a late retry would score twice; once the phone's state confirmed
    ///   it, it was applied.
    /// A re-queued command is not a failure: like a tap made while unreachable it waits in the queue (badge), and
    /// an error haptic would only invite a second tap that queues behind it and scores too.
    private func liveSendFailed(_ command: WatchCommand, reason: String) {
        Log.session.error("Sending \(command.name.rawValue) failed: \(reason)")
        guard command.name != .requestSync else { return }
        let wasPending = pendingActionId == command.actionId
        if wasPending {
            clearPendingState()
        }
        let isRetryExpected = command.name.awaitsConfirmation ? wasPending : true
        if isRetryExpected, lastCommandId == command.actionId, let session, session.activationState == .activated {
            enqueue(command, on: session)
            return
        }
        Log.session.warning("Not retrying \(command.name.rawValue): superseded, timed out or already confirmed")
        // A tap that timed out has had its error haptic; one the phone confirmed needs none.
        if isRetryExpected {
            signalFailure()
        }
    }

    private func signalFailure() {
        failedCommandCount += 1
    }

    // MARK: - Score Actions

    /// - Returns: true when the tap was sent; false when it was ignored, e.g. while an earlier one is pending.
    @discardableResult
    func incrementPlayer1() -> Bool {
        sendAwaitingConfirmation(.incrementP1, as: .player1Score)
    }

    /// - Returns: true when the tap was sent; false when it was ignored, e.g. while an earlier one is pending.
    @discardableResult
    func incrementPlayer2() -> Bool {
        sendAwaitingConfirmation(.incrementP2, as: .player2Score)
    }

    /// One score/highlight action in flight at a time: the phone is the source of truth, so the watch waits for
    /// its state (or the 2 s timeout) before accepting the next tap.
    private func sendAwaitingConfirmation(_ name: WatchCommand.Name, as action: PendingAction) -> Bool {
        guard pendingAction == nil else {
            Log.session.debug("Ignored \(name.rawValue): waiting for the phone to confirm the previous action")
            return false
        }
        return send(name, pending: action)
    }

    private func beginPending(_ action: PendingAction, actionId: String) {
        pendingAction = action
        pendingActionId = actionId

        // Timeout after 2 seconds in case iOS doesn't respond
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingTimedOut(actionId: actionId)
            }
        }
    }

    private func pendingTimedOut(actionId: String) {
        // The action may have been confirmed (and a new one started) while this hop was queued.
        guard pendingActionId == actionId else { return }
        clearPendingState()
        signalFailure()
        Log.session.warning("⚠️ Timeout waiting for iOS response")
    }

    private func clearPendingState() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingAction = nil
        pendingActionId = nil
    }

    // MARK: - Highlight Action (triggered by Double Tap gesture)

    /// - Returns: true when the highlight was sent; false when not recording or an action is pending.
    @discardableResult
    func markHighlight() -> Bool {
        // Only mark if we're recording
        guard scoreState.isRecording else {
            Log.session.debug("Not recording - highlight ignored")
            return false
        }

        let sent = sendAwaitingConfirmation(.highlight, as: .highlight)
        if sent {
            Log.session.info("⭐ HIGHLIGHT MARKED! Waiting for iOS confirmation")
        }
        return sent
    }

    // MARK: - Game/Match Actions (optional - can also be done from phone)

    /// - Returns: true when the command was sent (live or queued).
    @discardableResult
    func endGame() -> Bool {
        send(.endGame)
    }

    /// - Returns: true when the command was sent (live or queued).
    @discardableResult
    func endMatch() -> Bool {
        send(.endMatch)
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        let isActivated = activationState == .activated
        let isReachable = session.isReachable
        // The last state the phone pushed. (`applicationContext` is this side's own outgoing context.)
        let context = session.receivedApplicationContext
        let messageData = context.isEmpty ? nil : MessageData(from: context)

        Task { @MainActor in
            self.isConnected = isActivated
            // Transfers queued by an earlier run of the app are still pending after a relaunch.
            self.refreshQueuedCommandCount()
            if let messageData {
                self.handleMessageData(messageData)
            }
            if isActivated {
                self.requestSync()
            }
        }
        Log.session.info("Session activated: \(activationState.rawValue), Reachable: \(isReachable)")
        if let error {
            Log.session.error("Session activation error: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isConnected = isReachable
            if isReachable {
                self.requestSync()
            }
        }
        Log.session.info("Reachability: \(isReachable)")
    }

    /// A queued command reached the phone, or could not be delivered.
    nonisolated func session(
        _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?
    ) {
        let remaining = session.outstandingUserInfoTransfers.count { $0 !== userInfoTransfer }
        let command = userInfoTransfer.userInfo["command"] as? String ?? "?"
        let finishedActionId = userInfoTransfer.userInfo["actionId"] as? String
        let reason = error?.localizedDescription

        Task { @MainActor in
            self.refreshQueuedCommandCount(excluding: finishedActionId)
            if reason != nil {
                self.signalFailure()
            }
        }
        if let reason {
            Log.session.error("Queued \(command) was not delivered: \(reason)")
        } else {
            Log.session.debug("Queued \(command) delivered (\(remaining) still queued)")
        }
    }

    // Receive messages from iPhone
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let messageData = MessageData(from: message)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let messageData = MessageData(from: message)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
        replyHandler(["status": "received"])
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let messageData = MessageData(from: applicationContext)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
    }

    // iOS-only delegate methods (required for protocol conformance even though not used on watchOS)
    #if os(iOS)
        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
            // iOS only - not called on watchOS
        }

        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            // iOS only - not called on watchOS
            session.activate()
        }
    #endif

    private func handleMessageData(_ messageData: MessageData) {
        // Check for highlight confirmation
        if let highlightConfirmed = messageData.highlightConfirmed, highlightConfirmed {
            // Clear pending state immediately
            if self.pendingAction == .highlight {
                self.clearPendingState()
            }

            // Update highlight count if provided
            if let newCount = messageData.highlightCount {
                self.highlightCount = newCount
            }
            Log.session.info("⭐ Highlight confirmed by phone")
        }

        // Check for highlight count sync
        let syncedHighlightCount = messageData.highlightCount

        // Parse as state update
        guard let newState = messageData.toScoreState() else {
            return
        }

        // Check if recording state changed
        let wasRecording = self.scoreState.isRecording
        let isNowRecording = newState.isRecording

        // Reset highlight count when recording starts
        if !wasRecording && isNowRecording {
            self.highlightCount = 0
        }

        // Check if pending action was confirmed
        if let pending = self.pendingAction {
            switch pending {
            case .player1Score:
                if newState.playerOneScore > self.scoreState.playerOneScore {
                    self.clearPendingState()
                }
            case .player2Score:
                if newState.playerTwoScore > self.scoreState.playerTwoScore {
                    self.clearPendingState()
                }
            case .highlight:
                // Highlight confirmed by count increase
                if let newCount = syncedHighlightCount, newCount > self.highlightCount {
                    self.clearPendingState()
                }
            }
        }

        // Update highlight count if provided
        if let newCount = syncedHighlightCount {
            self.highlightCount = newCount
        }

        self.scoreState = newState
        Log.session.debug(
            "State updated: P1=\(newState.playerOneScore) P2=\(newState.playerTwoScore) Recording=\(newState.isRecording)"
        )
    }
}
