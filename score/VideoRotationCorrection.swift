//
//  VideoRotationCorrection.swift
//  score
//
//  The extra rotation a recorded segment needs, on top of its capture metadata (preferredTransform), for the
//  people in it to stand upright, and the pure decision that picks one from per-orientation evidence
//  (`VideoOrientationDetector` gathers the evidence; `MediaExportService.uprightGeometry` applies the result).
//
//  Conventions (pinned by OrientationConventionTests and VideoOrientationTests):
//  - A correction is a clockwise rotation of the metadata-upright frame, as seen on screen.
//  - `transform(for:)` works in top-left-origin pixel coordinates (y down), the space of AVFoundation layer
//    transforms and UIKit drawing.
//  - `imageOrientation` is the EXIF orientation that tells Vision "this pixel data needs this correction to be
//    upright", so Vision analyses (and reports coordinates in) the corrected picture.
//

import CoreGraphics
import Foundation
import ImageIO

/// A clockwise rotation applied to frames that are already upright according to their capture metadata.
nonisolated enum VideoRotationCorrection: String, Sendable, CaseIterable, Hashable {
    /// The metadata orientation is right: nothing to do.
    case none
    /// A quarter turn clockwise.
    case clockwise90
    /// A half turn.
    case upsideDown180
    /// A quarter turn counterclockwise (270 degrees clockwise).
    case counterclockwise270

    /// Clockwise rotation in degrees: 0, 90, 180 or 270.
    var degrees: Int {
        switch self {
        case .none: return 0
        case .clockwise90: return 90
        case .upsideDown180: return 180
        case .counterclockwise270: return 270
        }
    }

    /// True for the quarter turns, which swap the frame's width and height.
    var swapsDimensions: Bool {
        self == .clockwise90 || self == .counterclockwise270
    }

    /// The correction that undoes this one.
    var inverse: VideoRotationCorrection {
        switch self {
        case .none: return .none
        case .clockwise90: return .counterclockwise270
        case .upsideDown180: return .upsideDown180
        case .counterclockwise270: return .clockwise90
        }
    }

    /// EXIF orientation of pixel data that needs this correction to read upright (`.right`: the picture has to
    /// turn 90 degrees clockwise). Passing it to Vision makes Vision analyse the corrected picture.
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .none: return .up
        case .clockwise90: return .right
        case .upsideDown180: return .down
        case .counterclockwise270: return .left
        }
    }

    /// Size of a `size` frame after the correction.
    func rotatedSize(_ size: CGSize) -> CGSize {
        swapsDimensions ? CGSize(width: size.height, height: size.width) : size
    }

    /// Rotates a `size` frame about its centre and moves the result back to the origin, in top-left-origin pixel
    /// coordinates. The corrected frame covers `CGRect(origin: .zero, size: rotatedSize(size))`.
    func transform(for size: CGSize) -> CGAffineTransform {
        let width = size.width
        let height = size.height
        // (x, y) -> (a x + c y + tx, b x + d y + ty); exact matrices, so corners land on whole pixels
        switch self {
        case .none:
            return .identity
        case .clockwise90:  // (x, y) -> (height - y, x): the top-left corner goes to the top-right
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case .upsideDown180:  // (x, y) -> (width - x, height - y)
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case .counterclockwise270:  // (x, y) -> (y, width - x): the top-left corner goes to the bottom-left
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        }
    }
}

/// Picks a correction from per-orientation evidence, conservatively: weak or ambiguous evidence keeps the metadata
/// orientation (`.none`), because a wrong rotation is far worse than none.
nonisolated enum OrientationDecision {
    /// The best-scoring correction when its score is at least `minimumScore` and at least `margin` times the
    /// runner-up's; otherwise `.none`. Ties, empty input and non-finite scores give `.none`.
    static func decide(
        scores: [VideoRotationCorrection: Double], minimumScore: Double = 1.0, margin: Double = 1.5
    ) -> VideoRotationCorrection {
        let ranked = scores.filter(\.value.isFinite).sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= minimumScore else { return .none }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard best.value > runnerUp, best.value >= margin * runnerUp else { return .none }
        return best.key
    }
}
