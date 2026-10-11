//
//  MatchVideoPlayer.swift
//  score
//
//  AVKit's player view controller in SwiftUI, with the system playback controls (play/pause, scrubber,
//  expand to full screen). SwiftUI's VideoPlayer showed no controls on the match detail screen.
//

import AVKit
import SwiftUI
import UIKit
import os

struct MatchVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Bumped by the caller (the section's Full Screen button) to open this player in the system full-screen
    /// player. A counter, not a flag: nothing has to be reset when that player is dismissed.
    let fullScreenRequest: Int
    /// The screen is landscape (compact vertical size class). Turning the phone sideways while the video plays
    /// opens the full-screen player, as the system video apps do.
    let isLandscape: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handledRequest: fullScreenRequest, isLandscape: isLandscape)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        Self.configure(controller, player: player)
        controller.delegate = context.coordinator
        context.coordinator.inline = controller
        AudioSessionCoordinator.prepareForPlayback()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        context.coordinator.presentFullScreenIfRequested(fullScreenRequest, from: controller, player: player)
        context.coordinator.orientationChanged(toLandscape: isLandscape, from: controller, player: player)
    }

    /// Leaving the screen (or switching video) removes the inline player: stop its sound. Not `onDisappear`, which
    /// also fires while a full-screen player covers the screen and would pause the video being watched there.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
        AudioSessionCoordinator.endPlayback()
        Log.ui.debug("Inline player removed: paused")
    }

    /// Shared by the inline and the full-screen controller.
    static func configure(_ controller: AVPlayerViewController, player: AVPlayer) {
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        // Live Text over a paused frame took taps (it read the clock as a date) and is noise over a scoreboard
        controller.allowsVideoFrameAnalysis = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private var handledRequest: Int
        private var rotation: LandscapeFullScreenTrigger
        /// The inline controller, to read the window's orientation when a full-screen player closes.
        weak var inline: AVPlayerViewController?
        /// The full-screen controller while it is presented (UIKit owns it; released once dismissed).
        private weak var fullScreen: AVPlayerViewController?
        /// AVKit's own full screen (the inline controls' expand button, or a delegate-reporting modal) is showing.
        private var inSystemFullScreen = false

        init(handledRequest: Int, isLandscape: Bool) {
            self.handledRequest = handledRequest
            rotation = LandscapeFullScreenTrigger(isLandscape: isLandscape)
        }

        private var isFullScreenShown: Bool {
            inSystemFullScreen || fullScreen?.presentingViewController != nil
        }

        /// Presents the full-screen player when `request` is new (the header's Full Screen button).
        func presentFullScreenIfRequested(_ request: Int, from presenter: UIViewController, player: AVPlayer) {
            guard request != handledRequest else { return }
            handledRequest = request
            presentFullScreen(from: presenter, player: player)
        }

        /// Opens the full-screen player when the phone turns sideways while the video is playing.
        func orientationChanged(toLandscape landscape: Bool, from presenter: UIViewController, player: AVPlayer) {
            let playing = player.timeControlStatus != .paused
            guard
                rotation.orientationChanged(
                    toLandscape: landscape, isPlaying: playing, isFullScreenShown: isFullScreenShown)
            else { return }
            Log.ui.debug("Turned to landscape while playing: full screen")
            presentFullScreen(from: presenter, player: player)
        }

        /// Presents `player` in a new AVPlayerViewController, full screen. The same AVPlayer drives both
        /// controllers, so playback carries on at the same position and is still there inline after Done.
        private func presentFullScreen(from presenter: UIViewController, player: AVPlayer) {
            guard !isFullScreenShown else { return }
            let controller = AVPlayerViewController()
            MatchVideoPlayer.configure(controller, player: player)
            controller.modalPresentationStyle = .fullScreen
            controller.delegate = self
            fullScreen = controller
            // Not from inside a SwiftUI update: present once this update has been committed
            Task { @MainActor [weak presenter] in
                guard let presenter, presenter.viewIfLoaded?.window != nil else {
                    Log.ui.warning("Full screen player: the inline player is not in a window")
                    return
                }
                presenter.present(controller, animated: true) {
                    MatchVideoPlayer.playFromStartIfEnded(player)
                }
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator:
                any UIViewControllerTransitionCoordinator
        ) {
            inSystemFullScreen = true
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !context.isCancelled else { return }
                inSystemFullScreen = false
                let landscape = inline?.viewIfLoaded?.window?.traitCollection.verticalSizeClass == .compact
                rotation.fullScreenClosed(inLandscape: landscape)
                Log.ui.debug("Full screen player closed (landscape: \(landscape))")
            }
        }
    }

    /// Plays, rewinding first when the video has reached its end (play() at the end does nothing).
    static func playFromStartIfEnded(_ player: AVPlayer) {
        if let item = player.currentItem, item.duration.isNumeric,
            item.currentTime().seconds >= item.duration.seconds - 0.1
        {
            player.seek(to: .zero)
        }
        player.play()
    }
}

/// When turning the phone opens the full-screen player: on a turn to landscape while the video plays and no
/// full-screen player is showing. Closing a full-screen player in landscape is not a turn: the inline screen may
/// only learn of the landscape it came back to after the player has gone, and must not reopen it then.
nonisolated struct LandscapeFullScreenTrigger: Sendable {
    private var isLandscape: Bool
    /// A full-screen player closed in landscape: the next change to landscape is that return, not a turn.
    private var closedInLandscape = false

    init(isLandscape: Bool) {
        self.isLandscape = isLandscape
    }

    /// The screen's orientation is now `landscape`; true when the full-screen player should open.
    mutating func orientationChanged(toLandscape landscape: Bool, isPlaying: Bool, isFullScreenShown: Bool) -> Bool {
        guard landscape != isLandscape else { return false }
        isLandscape = landscape
        guard landscape else {
            closedInLandscape = false
            return false
        }
        if closedInLandscape {
            closedInLandscape = false
            return false
        }
        return isPlaying && !isFullScreenShown
    }

    /// A full-screen player has closed with the screen in `landscape`.
    mutating func fullScreenClosed(inLandscape landscape: Bool) {
        closedInLandscape = landscape && !isLandscape
    }
}
