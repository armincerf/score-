//
//  FrameCompositor.swift
//  score
//
//  The one video compositor of both exports (the full match and the highlight reel). Each frame is drawn with
//  Core Image as: black at the render size, the piece's stored frame turned upright and fitted (the geometry the
//  export decided for that piece: preferredTransform, detected correction, letterbox), then the scoreboard for that
//  moment, if the export has one. A custom AVVideoCompositing class (Apple's AVCustomEdit pattern), because the Core
//  Image applier (`AVVideoComposition(applyingFiltersTo:applier:)`) has no per-piece geometry, no explicit render
//  size and no frame duration of its own. Each frame is a pure function of its composition time.
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import os

/// One stretch of the composition and how its frames are drawn.
nonisolated final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// The board changes over time even where the source would not, so every frame is rendered.
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// The composition's video track the piece was inserted into.
    let trackID: CMPersistentTrackID
    /// Stored frame pixels -> render frame pixels, both with the origin at the top-left (as layer instructions
    /// and `MediaExportService.uprightGeometry` express it).
    let transform: CGAffineTransform
    let renderSize: CGSize
    let overlay: ScoreboardOverlaySource?

    init(
        timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform, renderSize: CGSize,
        overlay: ScoreboardOverlaySource?
    ) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        self.renderSize = renderSize
        self.overlay = overlay
    }

    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: trackID)] }
    var requiredSourceSampleDataTrackIDs: [NSNumber] { [] }

    /// `transform` for Core Image, whose origin is at the bottom-left: flip the stored frame (height
    /// `sourceHeight`) to top-left coordinates, apply, flip back by the render height. Pure so it can be tested.
    static func coreImageTransform(
        _ transform: CGAffineTransform, sourceHeight: CGFloat, renderHeight: CGFloat
    ) -> CGAffineTransform {
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let toBottomLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderHeight)
        return toTopLeft.concatenating(transform).concatenating(toBottomLeft)
    }
}

nonisolated final class FrameCompositor: NSObject, AVVideoCompositing, Sendable {
    /// No colour management: the composition converts the sources to its own colour space (Rec. 709) before they
    /// arrive, and the board's sRGB pixels are drawn as they are, so the video's pixels pass through unchanged.
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
    ])
    /// Video-range 4:2:0 in and out, as the decoder produces and the encoder takes it: no colour conversion pass
    /// on either side of the compositor.
    private static func bufferAttributes(_ formats: [OSType]) -> [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: formats,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
    }

    let sourcePixelBufferAttributes: [String: any Sendable]? = bufferAttributes([
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA,
    ])
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = bufferAttributes([
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    /// Bumped by `cancelAllPendingVideoCompositionRequests`: a frame still waiting for its board finishes as
    /// cancelled when this changed meanwhile.
    private let generation = Mutex(0)

    enum CompositorError: Error {
        case unexpectedInstruction
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? FrameInstruction else {
            request.finish(with: CompositorError.unexpectedInstruction)
            return
        }
        let picture = Self.picture(for: request, instruction: instruction)
        guard let overlay = instruction.overlay else {
            Self.finish(request, picture: picture, board: nil, renderSize: instruction.renderSize)
            return
        }
        let time = request.compositionTime
        switch overlay.boardIfReady(at: time) {
        case .ready(let board):
            Self.finish(request, picture: picture, board: board, renderSize: instruction.renderSize)
        case .pending:
            // The board is rendered on the main actor; finish the request from that task (AVFoundation allows a
            // request to be finished on any thread) rather than block this one
            let started = generation.withLock { $0 }
            Task {
                let board = await overlay.board(at: time)
                guard self.generation.withLock({ $0 }) == started else {
                    request.finishCancelledRequest()
                    return
                }
                Self.finish(request, picture: picture, board: board, renderSize: instruction.renderSize)
            }
        }
    }

    /// The piece's stored frame for this request, turned upright and fitted into the render frame; nil where the
    /// piece has no frame (a segment whose sound outlasts its last video frame is inserted for the file's whole
    /// duration, and a range rounded to 1/600 s can end just past the track): that frame is drawn black, as the
    /// default compositor draws it, rather than failing the export.
    private static func picture(
        for request: AVAsynchronousVideoCompositionRequest, instruction: FrameInstruction
    ) -> CIImage? {
        guard let source = request.sourceReadOnlyPixelBuffer(byTrackID: instruction.trackID) else {
            Log.video.debug("Compositor: no source frame at \(request.compositionTime.seconds)s, drawing black")
            return nil
        }
        // The image keeps the source buffer alive until the frame is rendered
        let stored = source.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
        let transform = FrameInstruction.coreImageTransform(
            instruction.transform, sourceHeight: stored.extent.height, renderHeight: instruction.renderSize.height)
        return stored.transformed(by: transform)
    }

    func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 += 1 }
    }

    /// Draws `picture` (none: a black frame) over black and `board` over both into a new buffer of the render
    /// context.
    private static func finish(
        _ request: AVAsynchronousVideoCompositionRequest, picture: CIImage?, board: CIImage?, renderSize: CGSize
    ) {
        let output: CVMutablePixelBuffer
        do {
            output = try request.renderContext.makeMutablePixelBuffer()
        } catch {
            request.finish(with: error)
            return
        }
        let frame = CGRect(origin: .zero, size: renderSize)
        // Black shows only where the piece does not cover the frame (letterbox bands), or where it has no frame
        let black = CIImage(color: .black).cropped(to: frame)
        var image: CIImage
        if let picture {
            image = picture.extent.contains(frame) ? picture : picture.composited(over: black)
        } else {
            image = black
        }
        if let board { image = board.composited(over: image) }
        // The render context is the render size unless a player scales it (renderScale)
        let size = request.renderContext.size
        if size != renderSize, renderSize.width > 0, renderSize.height > 0 {
            image = image.transformed(
                by: CGAffineTransform(scaleX: size.width / renderSize.width, y: size.height / renderSize.height))
        }
        let bounds = CGRect(origin: .zero, size: size)
        let composed = image.cropped(to: bounds)
        output.withUnsafeBuffer { context.render(composed, to: $0, bounds: bounds, colorSpace: nil) }
        request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(output))
    }
}
