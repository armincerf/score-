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

        Task { @MainActor in
            self.isWatchReachable = isReachable
            self.isWatchAppInstalled = isPaired && isWatchAppInstalled
        }
        Log.match.info(
            "Session activated: \(activationState.rawValue), Paired: \(isPaired), Watch app installed: \(isWatchAppInstalled), Reachable: \(isReachable)"
        )
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let installed = session.isPaired && session.isWatchAppInstalled
        Task { @MainActor in
            self.isWatchAppInstalled = installed
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
                // The watch has no score validation; the phone only ends finished or led games
                self.endGame(force: true)

            case "endMatch":
                self.requestEndMatchFromWatch()

            case "requestSync":
                self.sendScore()
                Log.match.debug("Command: requestSync")

            default:
                Log.match.debug("Unknown command: \(command)")
            }
            return
        }

        // The watch only mirrors the phone's state; a command-less payload is never applied
        if messageData.scoreState != nil {
            Log.match.debug("Ignoring state payload from watch (phone is the source of truth)")
        }
    }
}
