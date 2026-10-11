//
//  AudioSessionCoordinator.swift
//  score
//
//  Single owner of the app's AVAudioSession. The capture session is told not to manage it
//  (automaticallyConfiguresApplicationAudioSession = false) so score announcements keep
//  playing through the speaker while the microphone records, and other apps' audio is only
//  ducked for the duration of a match. Outside a match it gives the detail screen's video player the
//  playback category, so recorded sound is heard with the Ring/Silent switch on.
//
//  The session is reached through `AudioSessionControlling`, and a test host gets an inert one: on CI's freshly
//  created simulator every AVAudioSession call blocked the main thread for 40-90 s (no audio server to answer), which
//  starved every other test and tripped their time limits. Tests of the coordinator's decisions install a spy.
//

import AVFoundation
import Foundation
import os

/// The part of `AVAudioSession` the coordinator uses.
protocol AudioSessionControlling: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionControlling {}

/// A session that accepts every call and does nothing: the test host's default.
final class InertAudioSession: AudioSessionControlling {
    func setCategory(
        _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
    ) throws {}
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
}

@MainActor
enum AudioSessionCoordinator {
    /// The session every call goes to: the shared `AVAudioSession`, or an inert one when the process is a test host
    /// (`xcodebuild test` sets `XCTestConfigurationFilePath`). Tests replace it with a spy.
    static var session: any AudioSessionControlling = isTestHost ? InertAudioSession() : AVAudioSession.sharedInstance()

    private static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil
    }

    /// True from `activateForMatch` until `deactivate`: the live match owns the session, and watching a finished
    /// match's video must not change it.
    private(set) static var isMatchLive = false

    /// Activates the session for a live match. `recording` adds the microphone (play-and-record).
    static func activateForMatch(recording: Bool) {
        isMatchLive = true
        do {
            if recording {
                try session.setCategory(
                    .playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .duckOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            }
            try session.setActive(true, options: [])
        } catch {
            Log.audio.error("Failed to activate audio session (recording: \(recording)): \(error)")
        }
    }

    /// Readies the session for a finished match's videos (the detail screen's player): the playback category, so
    /// their recorded sound plays with the Ring/Silent switch on. Without it the session has iOS's default
    /// solo-ambient category, which that switch mutes, until a match has set one in this launch. Only the category:
    /// AVPlayer activates the session when playback starts, so opening the screen leaves other apps' audio playing.
    /// Does nothing while a match is live (its category already ignores the switch, and it needs the microphone).
    static func prepareForPlayback() {
        guard !isMatchLive else { return }
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            Log.audio.error("Failed to set the playback audio category: \(error)")
        }
    }

    /// The detail screen's player has gone: release the session (other apps' audio resumes), unless a match is live.
    static func endPlayback() {
        guard !isMatchLive else { return }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Failed to deactivate audio session after playback: \(error)")
        }
    }

    /// Releases the session so other apps' audio resumes at full volume.
    static func deactivate() {
        isMatchLive = false
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Failed to deactivate audio session: \(error)")
        }
    }
}
