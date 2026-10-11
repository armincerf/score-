//
//  ReelOverlayComposer.swift
//  score
//
//  Burns still images (the reel scoreboard) into a video composition's frames for given time ranges.
//  Uses AVFoundation's per-frame Core Image hook (iOS 26 `AVVideoComposition(applyingFiltersTo:applier:)`),
//  which runs for export and playback alike and has none of the Core Animation tool's timing quirks: each
//  frame is a pure function of its composition time.
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia

/// A still image shown over the video for a stretch of the composition's timeline.
nonisolated struct OverlayCue: Sendable {
    let timeRange: CMTimeRange
    let image: CGImage
    /// Bottom-left corner of the image in frame pixels (Core Image coordinates: origin at the bottom-left).
    let origin: CGPoint
}

enum ReelOverlayComposer {
    /// A video composition that draws each cue over `asset`'s frames during its time range. Frames outside
    /// every cue pass through untouched; overlapping cues draw in array order (later on top).
    static func videoComposition(for asset: AVAsset, cues: [OverlayCue]) async throws -> AVVideoComposition {
        let overlays: [(range: CMTimeRange, image: CIImage)] = cues.map { cue in
            let placed = CIImage(cgImage: cue.image)
                .transformed(by: CGAffineTransform(translationX: cue.origin.x, y: cue.origin.y))
            return (cue.timeRange, placed)
        }
        return try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            let source = parameters.sourceImage
            var image = source
            for overlay in overlays where overlay.range.containsTime(parameters.compositionTime) {
                image = overlay.image.composited(over: image).cropped(to: source.extent)
            }
            return AVCIImageFilteringResult(resultImage: image)
        }
    }
}
