//
//  WatchSessionManager.swift
//  scorewatch Watch App
//
//  Manages communication between watchOS and iOS
//  Includes highlight marking via Double Tap gesture
//

import Foundation
import Combine
@preconcurrency import WatchConnectivity

/// Sendable wrapper for WCSession message data
struct MessageData: Sendable {
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

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    @Published var scoreState = ScoreState()
    @Published var isConnected = false
    @Published var highlightCount = 0  // Track highlights marked this session
    @Published var pendingAction: PendingAction? = nil

    enum PendingAction {
        case player1Score
        case player2Score
        case highlight
    }

    private var session: WCSession?
    private var pendingTimer: Timer?

    override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    // MARK: - Send to iPhone

    private func sendCommand(_ command: String, data: [String: Any] = [:]) {
        guard let session = session else { return }

        var message = data
        message["command"] = command

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                print("[Watch] Error sending command: \(error.localizedDescription)")
            }
        } else {
            // Phone not immediately reachable - queue via context
            // Commands will be processed when phone wakes
            do {
                try session.updateApplicationContext(message)
            } catch {
                print("[Watch] Error updating context: \(error.localizedDescription)")
            }
        }
    }

    private func sendScore() {
        guard let session = session else { return }

        let message = scoreState.toDictionary()

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                print("[Watch] Error sending: \(error.localizedDescription)")
            }
        }

        do {
            try session.updateApplicationContext(message)
        } catch {
            print("[Watch] Error updating context: \(error.localizedDescription)")
        }
    }

    // MARK: - Score Actions

    func incrementPlayer1() {
        // Don't allow multiple pending actions
        guard pendingAction == nil else { return }

        // Set pending state
        pendingAction = .player1Score

        // Send command to phone - phone is source of truth
        sendCommand("incrementP1")

        // Timeout after 2 seconds in case iOS doesn't respond
        startPendingTimeout()

        print("[Watch] P1 scored - waiting for iOS confirmation")
    }

    func incrementPlayer2() {
        // Don't allow multiple pending actions
        guard pendingAction == nil else { return }

        // Set pending state
        pendingAction = .player2Score

        // Send command to phone - phone is source of truth
        sendCommand("incrementP2")

        // Timeout after 2 seconds in case iOS doesn't respond
        startPendingTimeout()

        print("[Watch] P2 scored - waiting for iOS confirmation")
    }

    private func startPendingTimeout() {
        // Cancel any existing timer
        pendingTimer?.invalidate()

        // Set timeout to clear pending state if no response
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.clearPendingState()
                print("[Watch] ⚠️ Timeout waiting for iOS response")
            }
        }
    }

    private func clearPendingState() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingAction = nil
    }

    // MARK: - Highlight Action (triggered by Double Tap gesture)

    func markHighlight() {
        // Only mark if we're recording
        guard scoreState.isRecording else {
            print("[Watch] Not recording - highlight ignored")
            return
        }

        // Don't allow multiple pending actions
        guard pendingAction == nil else { return }

        // Set pending state
        pendingAction = .highlight

        // Send highlight command to phone
        sendCommand("highlight")

        // Timeout after 2 seconds in case iOS doesn't respond
        startPendingTimeout()

        print("[Watch] ⭐ HIGHLIGHT MARKED! Waiting for iOS confirmation")
    }

    // MARK: - Game/Match Actions (optional - can also be done from phone)

    func endGame() {
        sendCommand("endGame")
    }

    func endMatch() {
        sendCommand("endMatch")
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let isActivated = activationState == .activated
        let isReachable = session.isReachable
        let context = session.applicationContext
        let messageData = context.isEmpty ? nil : MessageData(from: context)
        
        Task { @MainActor in
            self.isConnected = isActivated
            if let messageData = messageData {
                self.handleMessageData(messageData)
            }
            if isActivated {
                self.sendCommand("requestSync")
            }
        }
        print("[Watch] Session activated: \(activationState.rawValue), Reachable: \(isReachable)")
        if isActivated {
            print("[Watch] Sent initial sync request to phone")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isConnected = isReachable
            if isReachable {
                self.sendCommand("requestSync")
            }
        }
        print("[Watch] Reachability: \(isReachable)")
    }

    // Receive messages from iPhone
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let messageData = MessageData(from: message)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
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
            print("[Watch] ⭐ Highlight confirmed by phone")
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
        print("[Watch] State updated: P1=\(newState.playerOneScore) P2=\(newState.playerTwoScore) Recording=\(newState.isRecording)")
    }
}
