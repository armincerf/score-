//
//  AudioSessionCoordinator.swift
//  score
//
//  Single owner of the app's AVAudioSession. The capture session is told not to manage it
//  (automaticallyConfiguresApplicationAudioSession = false) so score announcements keep
//  playing through the speaker while the microphone records, and other apps' audio is only
//  ducked for the duration of a match.
//

import AVFoundation
import os

@MainActor
enum AudioSessionCoordinator {
    /// Activates the session for a live match. `recording` adds the microphone (play-and-record).
    static func activateForMatch(recording: Bool) {
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

    /// Releases the session so other apps' audio resumes at full volume.
    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Failed to deactivate audio session: \(error)")
        }
    }
}
