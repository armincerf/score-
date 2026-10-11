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

import AVFoundation
import os

@MainActor
enum AudioSessionCoordinator {
    /// True from `activateForMatch` until `deactivate`: the live match owns the session, and watching a finished
    /// match's video must not change it.
    private(set) static var isMatchLive = false

    /// Activates the session for a live match. `recording` adds the microphone (play-and-record).
    static func activateForMatch(recording: Bool) {
        isMatchLive = true
        let session = AVAudioSession.sharedInstance()
        do {
            if recording {
                try session.setCategory(
                    .playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .duckOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            }
            try session.setActive(true)
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            Log.audio.error("Failed to set the playback audio category: \(error)")
        }
    }

    /// The detail screen's player has gone: release the session (other apps' audio resumes), unless a match is live.
    static func endPlayback() {
        guard !isMatchLive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Failed to deactivate audio session after playback: \(error)")
        }
    }

    /// Releases the session so other apps' audio resumes at full volume.
    static func deactivate() {
        isMatchLive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Failed to deactivate audio session: \(error)")
        }
    }
}
