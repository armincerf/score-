//
//  MatchVideoPlayerTests.swift
//  scoreTests
//
//  Turning the phone sideways while a video plays opens the full-screen player (LandscapeFullScreenTrigger), and
//  the detail screen's player gets the playback audio category outside a match (AudioSessionCoordinator).
//

import AVFoundation
import Testing

@testable import score

@Suite("Landscape opens full screen")
struct LandscapeFullScreenTriggerTests {
    @Test("Turning to landscape while playing opens full screen; paused, or already full screen, does not")
    func turnToLandscape() {
        var playing = LandscapeFullScreenTrigger(isLandscape: false)
        let opened1 = playing.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(opened1)

        var paused = LandscapeFullScreenTrigger(isLandscape: false)
        let opened2 = paused.orientationChanged(toLandscape: true, isPlaying: false, isFullScreenShown: false)
        #expect(!opened2)

        var shown = LandscapeFullScreenTrigger(isLandscape: false)
        let opened3 = shown.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: true)
        #expect(!opened3)
    }

    @Test("Only a change counts: staying landscape or turning back to portrait opens nothing")
    func onlyChangesToLandscape() {
        var trigger = LandscapeFullScreenTrigger(isLandscape: true)
        let opened4 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(!opened4)
        let opened5 = trigger.orientationChanged(toLandscape: false, isPlaying: true, isFullScreenShown: false)
        #expect(!opened5)
        let opened6 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(opened6)
    }

    @Test("Closing full screen in landscape before the screen has seen the turn does not reopen it")
    func closedInLandscapeIsNotATurn() {
        var trigger = LandscapeFullScreenTrigger(isLandscape: false)
        // Opened in portrait, turned in full screen, closed: the screen learns of landscape only now
        trigger.fullScreenClosed(inLandscape: true)
        let opened7 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(!opened7)
        // A real turn later still works
        let opened8 = trigger.orientationChanged(toLandscape: false, isPlaying: true, isFullScreenShown: false)
        #expect(!opened8)
        let opened9 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(opened9)
    }

    @Test("Closing full screen in landscape after the screen saw the turn leaves the next turn alone")
    func closedAfterTheScreenTurned() {
        var trigger = LandscapeFullScreenTrigger(isLandscape: false)
        // The screen saw the turn while the full-screen player covered it
        let opened10 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: true)
        #expect(!opened10)
        trigger.fullScreenClosed(inLandscape: true)
        let opened11 = trigger.orientationChanged(toLandscape: false, isPlaying: true, isFullScreenShown: false)
        #expect(!opened11)
        let opened12 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(opened12)
    }

    @Test("Closing full screen in portrait leaves the next turn alone")
    func closedInPortrait() {
        var trigger = LandscapeFullScreenTrigger(isLandscape: false)
        trigger.fullScreenClosed(inLandscape: false)
        let opened13 = trigger.orientationChanged(toLandscape: true, isPlaying: true, isFullScreenShown: false)
        #expect(opened13)
    }
}

/// Synchronous main-actor tests: nothing else touching the shared audio session can run in between.
@Suite("Playback audio session")
struct PlaybackAudioSessionTests {
    @Test("Outside a match the player gets the playback category, which the Ring/Silent switch does not mute")
    func playbackCategoryOutsideAMatch() {
        AudioSessionCoordinator.deactivate()
        AudioSessionCoordinator.prepareForPlayback()
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playback)
        #expect(session.mode == .moviePlayback)
        AudioSessionCoordinator.endPlayback()
    }

    @Test("A live match keeps its session: the player changes neither its category nor its activation")
    func liveMatchKeepsItsSession() {
        AudioSessionCoordinator.activateForMatch(recording: false)
        defer { AudioSessionCoordinator.deactivate() }
        #expect(AudioSessionCoordinator.isMatchLive)
        AudioSessionCoordinator.prepareForPlayback()
        AudioSessionCoordinator.endPlayback()
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playback)
        #expect(session.mode == .default)  // the match's, not .moviePlayback
        #expect(AudioSessionCoordinator.isMatchLive)
    }
}
