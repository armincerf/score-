//
//  WatchConnectivityManager+WCSession.swift
//  score
//
//  WCSessionDelegate: receives commands from the watch and hops them onto the main actor.
//

import Foundation
@preconcurrency import WatchConnectivity
import os

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
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
        Log.match.info(
            "Session activated: \(activationState.rawValue), Paired: \(isPaired), Watch app installed: \(isWatchAppInstalled), Reachable: \(isReachable)"
        )
        if hasContext {
            Log.match.debug("Watch app detected via application context")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Log.match.debug("Session inactive")
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = isReachable
        }
        Log.match.info("Reachability: \(isReachable)")
    }

    // Receive messages from watch
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let messageData = WatchMessageData(from: message)
        Task { @MainActor in
            self.handleMessageData(messageData)
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
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

    func handleMessageData(_ messageData: WatchMessageData) {
        // Any message from watch means the watch app is installed and connected
        self.isWatchAppInstalled = true

        // Check for commands from watch
        if let command = messageData.command {
            switch command {
            case "incrementP1":
                self.incrementPlayer1()
                Log.match.debug("Command: incrementP1")

            case "incrementP2":
                self.incrementPlayer2()
                Log.match.debug("Command: incrementP2")

            case "highlight":
                self.playHighlightSound()
                self.markHighlight()
                Log.match.debug("Command: highlight from watch")

            case "endGame":
                self.endGame()

            case "endMatch":
                // Watch requested match end - signal GameView to trigger the same flow as phone button
                self.shouldEndMatchFromWatch = true
                Log.match.debug("Command: endMatch from watch - signaling GameView")

            case "requestSync":
                self.sendScore()
                Log.match.debug("Command: requestSync")

            default:
                Log.match.debug("Unknown command: \(command)")
            }
            return
        }

        // Parse as full state update (shouldn't happen often - watch sends commands)
        guard let newState = messageData.scoreState else {
            return
        }

        self.scoreState = newState
        Log.match.debug("Received state update")
    }
}
