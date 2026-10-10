//
//  WatchConnectivityManager+WCSession.swift
//  score
//
//  WCSessionDelegate: receives commands from the watch and hops them onto the main actor.
//

import Foundation
@preconcurrency import WatchConnectivity
import os

/// How a message from the watch reached the phone (for logs).
nonisolated enum WatchDelivery: String, Sendable {
    case message
    case userInfo
    case applicationContext
}

/// The most recent watch command ids, oldest forgotten first, so a command delivered twice is applied once.
nonisolated struct RecentActionIDs: Sendable {
    let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Records `id`. Returns false when it is already among the recent ids, i.e. a duplicate delivery.
    mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }
}

extension WatchConnectivityManager {
    /// Watch command ids already applied. Static because the ids come from the one process-wide
    /// `WCSession.default` (and an extension cannot add instance storage); main-actor isolated like the class.
    /// A duplicate is the re-queued copy of a live send that failed; only the taps made in between separate it
    /// from the original, so the last 200 ids is ample.
    private static var recentWatchActionIds = RecentActionIDs(capacity: 200)

    /// How far the watch's `sentAt` may run behind the phone's clock (the watch takes its time from the phone).
    static let watchClockSkewAllowance: TimeInterval = 2

    /// A command the watch issued before the current match began recording belongs to an earlier match: the watch
    /// offers its controls only while recording, so this is a tap that waited in the `transferUserInfo` queue (watch
    /// out of range) while that match ended and this one started. Applied now it would score, or end, this match.
    /// `requestSync` is always answered; commands without `sentAt` (older watch builds) cannot be told apart.
    private func isFromEarlierMatch(_ messageData: WatchMessageData) -> Bool {
        guard let sentAt = messageData.sentAt, messageData.command != "requestSync",
            let recordingStart = scoreState.recordingStartTime
        else { return false }
        return sentAt < recordingStart.timeIntervalSince1970 - Self.watchClockSkewAllowance
    }
}

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
            self.receiveFromWatch(messageData, via: .message)
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let messageData = WatchMessageData(from: message)
        // Wrap replyHandler to make it Sendable - WCSession guarantees it's safe to call from any thread
        let sendableReply = UnsafeSendable(replyHandler)
        Task { @MainActor in
            // Reply even to a duplicate: the watch is waiting for the state either way.
            self.receiveFromWatch(messageData, via: .message)
            let scoreStateCopy = self.scoreState
            sendableReply.value(scoreStateCopy.toDictionary())
        }
    }

    /// Commands the watch queued with `transferUserInfo` (phone unreachable, or a live send failed).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let messageData = WatchMessageData(from: userInfo)
        Task { @MainActor in
            self.receiveFromWatch(messageData, via: .userInfo)
        }
    }

    // Current watch builds never write commands into their application context; older ones did.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let messageData = WatchMessageData(from: applicationContext)
        Task { @MainActor in
            self.receiveFromWatch(messageData, via: .applicationContext)
        }
    }

    /// Entry point for everything the watch delivers. A command whose `actionId` was already applied is dropped
    /// (the same tap can arrive live and again from the watch's `transferUserInfo` queue), and so is one issued
    /// before the current match began (`isFromEarlierMatch`); anything else, including commands without an id
    /// from older watch builds, goes to `handleMessageData`.
    /// - Returns: false when the message was dropped as a duplicate or as left over from an earlier match.
    @discardableResult
    func receiveFromWatch(_ messageData: WatchMessageData, via delivery: WatchDelivery) -> Bool {
        let command = messageData.command ?? "-"
        guard !isFromEarlierMatch(messageData) else {
            Log.match.info("Dropped watch command \(command) issued before this match began (\(delivery.rawValue))")
            return false
        }
        if let actionId = messageData.actionId {
            guard Self.recentWatchActionIds.insert(actionId) else {
                Log.match.debug("Dropped duplicate watch command \(command) \(actionId) (\(delivery.rawValue))")
                return false
            }
            if let sentAt = messageData.sentAt {
                let delay = Date().timeIntervalSince1970 - sentAt
                Log.match.debug(
                    "Watch command \(command) via \(delivery.rawValue), \(delay, format: .fixed(precision: 1)) s after the tap"
                )
            }
        }
        handleMessageData(messageData)
        return true
    }

    func handleMessageData(_ messageData: WatchMessageData) {
        // While the match is being stopped, exported and saved, late taps must not change it
        if isExporting, let command = messageData.command, command != "requestSync" {
            Log.match.warning("Ignoring watch command \(command) during export")
            return
        }
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
                // The watch has no score validation; the phone only ends finished or led games.
                // A queued End Game from minutes ago would end whatever game is current: drop it.
                if let sentAt = messageData.sentAt, Date().timeIntervalSince1970 - sentAt > 30 {
                    Log.match.warning(
                        "Ignoring stale endGame command (\(Int(Date().timeIntervalSince1970 - sentAt))s old)")
                } else {
                    self.endGame(force: true)
                }

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
