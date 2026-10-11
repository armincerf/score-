//
//  InlinePlayerLayout.swift
//  score
//
//  The inline match video player's frame, shaped like the video: pure so it can be unit-tested.
//

import AVFoundation
import CoreGraphics

/// Sizes the inline player on the match detail screen so the video fills it without black bars.
nonisolated enum InlinePlayerLayout {
    /// Tallest the inline player gets, so a portrait video leaves room for the rest of the screen.
    static let maxHeight: CGFloat = 420
    /// The shape assumed while the video's size is unknown (not loaded yet, or unreadable): a landscape recording.
    static let fallbackAspectRatio: CGFloat = 16 / 9
    /// Share of the visible screen height the player may take, so all of it (AVKit's scrubber sits on its bottom
    /// edge) fits on screen with room for the card around it.
    static let viewportFraction: CGFloat = 0.8

    /// The player's height cap on a screen whose scroll view shows `viewportHeight` points (below the navigation bar,
    /// above the home indicator): `maxHeight`, or less on a short screen. An iPhone in landscape shows about 340 pt,
    /// where a 16:9 video at the full width would be taller than the screen. Unmeasured (0) gives `maxHeight`.
    static func maxHeight(forViewportHeight viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return maxHeight }
        return min(maxHeight, viewportHeight * viewportFraction)
    }

    /// The player's frame for a video of upright display size `videoSize` (nil while unknown) in `availableWidth`.
    /// The video's shape is fitted into `availableWidth` x `maxHeight`: a landscape or square video fills the width
    /// (unless that would be taller than `maxHeight`), a portrait one is capped at `maxHeight` and is narrower than
    /// the width (the caller centres it). An unknown or empty size gets 16:9 at the width.
    static func playerSize(
        for videoSize: CGSize?, availableWidth: CGFloat, maxHeight: CGFloat = maxHeight
    )
        -> CGSize
    {
        guard availableWidth > 0, maxHeight > 0 else { return .zero }
        let ratio: CGFloat
        if let videoSize, videoSize.width > 0, videoSize.height > 0 {
            ratio = videoSize.width / videoSize.height
        } else {
            ratio = fallbackAspectRatio
        }
        let height = availableWidth / ratio
        if height <= maxHeight {
            return CGSize(width: availableWidth, height: height)
        }
        return CGSize(width: maxHeight * ratio, height: maxHeight)
    }

    /// The size a video track is shown at: its natural size turned by its preferred transform (a phone recording
    /// stored landscape with a 90 degree transform plays portrait). Nil for an empty track.
    static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize? {
        let size = MediaExportService.uprightGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)
            .size
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// Loads the upright display size of the first video track in `url`; nil when it has none or cannot be read.
    @concurrent
    static func loadDisplaySize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            return displaySize(naturalSize: naturalSize, preferredTransform: transform)
        } catch {
            return nil
        }
    }
}
