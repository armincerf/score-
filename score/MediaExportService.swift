//
//  MediaExportService.swift
//  score
//
//  Video export: concatenates the recorded segments of a match into one upright full video
//  (each segment rotated by its own preferredTransform) and cuts highlight clips out of it.
//  Uses the iOS 26+ value-type AVVideoComposition configuration API and the iOS 18+ async
//  AVAssetExportSession API with live progress.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os

enum MediaExportService {
    // MARK: - Export Quality

    enum ExportQuality: Sendable, Equatable {
        case sd480p
        case hd720p
        case hd1080p
        case uhd4K
        case hevcHighestQuality
        case passthrough

        var preset: String {
            switch self {
            case .sd480p: return AVAssetExportPreset640x480
            case .hd720p: return AVAssetExportPreset1280x720
            case .hd1080p: return AVAssetExportPreset1920x1080
            case .uhd4K: return AVAssetExportPreset3840x2160
            case .hevcHighestQuality: return AVAssetExportPresetHEVCHighestQuality
            case .passthrough: return AVAssetExportPresetPassthrough
            }
        }

        var fileType: AVFileType { .mov }

        /// The export preset that keeps the user's chosen capture quality.
        nonisolated static func matching(_ capture: VideoQualityPreset) -> ExportQuality {
            switch capture {
            case .low, .medium: return .sd480p
            case .high, .hd720p: return .hd720p
            case .hd1080p: return .hd1080p
            case .hd4K: return .uhd4K
            }
        }
    }

    // MARK: - Export Result

    struct ExportResult: Sendable {
        let outputURL: URL
        let duration: TimeInterval
        let fileSize: Int64?

        init(outputURL: URL, duration: TimeInterval, fileSize: Int64? = nil) {
            self.outputURL = outputURL
            self.duration = duration
            self.fileSize = fileSize
        }
    }

    // MARK: - Highlight Clip Info

    /// A clip in the time base of the source video (seconds).
    struct HighlightClipInfo: Sendable {
        let startTimestamp: Double
        let endTimestamp: Double
        let player: Int?
        let gameNumber: Int

        var duration: Double {
            endTimestamp - startTimestamp
        }
    }

    /// Progress callback in 0...1. Always invoked on the main actor.
    typealias ProgressHandler = @MainActor @Sendable (Double) -> Void

    // MARK: - Full Video Export

    /// Concatenates `segments` (in order) into one upright movie. `corrections` is aligned with `segments` (a
    /// missing entry is `.none`): the extra turn each segment needs on top of its preferredTransform, as decided
    /// from its pictures by `VideoOrientationDetector`.
    static func exportFullVideo(
        segments: [URL],
        corrections: [VideoRotationCorrection] = [],
        to outputURL: URL,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !segments.isEmpty else { throw ExportError.noVideoTrackInSource }
        try? FileManager.default.removeItem(at: outputURL)

        let built = try await makeComposition(clips: segments.map { ($0, nil) }, corrections: corrections)
        try await exportComposition(built, to: outputURL, quality: quality, progressHandler: progressHandler)

        return ExportResult(
            outputURL: outputURL,
            duration: CMTimeGetSeconds(built.composition.duration),
            fileSize: fileSize(at: outputURL)
        )
    }

    // MARK: - Highlight Reel Export

    /// Cuts `clips` (times in `source`'s time base) out of `source` into one reel, in order. `scoreboard` cues
    /// (reel-time ranges and bitmaps, see `scoreboardOverlays`) are burned into the frames; empty = a plain reel.
    /// `correction` is the extra turn `source` needs on top of its preferredTransform: `.none` for an exported full
    /// video (already upright), the detected correction for a raw camera segment kept as the full video. A turned
    /// reel is exported without the board (see `withScoreboard`).
    static func exportHighlightReel(
        from source: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        scoreboard: [OverlayCue] = [],
        correction: VideoRotationCorrection = .none,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !clips.isEmpty else { throw ExportError.noClips }
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let timeRanges = clipTimeRanges(for: clips, assetDuration: durationSeconds)
        guard !timeRanges.isEmpty else { throw ExportError.noClips }

        var built = try await makeComposition(
            clips: timeRanges.map { (source, $0) }, corrections: Array(repeating: correction, count: timeRanges.count))
        if !scoreboard.isEmpty {
            built = try await withScoreboard(scoreboard, on: built, source: asset, correction: correction)
        }
        try await exportComposition(built, to: outputURL, quality: quality, progressHandler: progressHandler)

        let totalDuration = timeRanges.reduce(0) { $0 + CMTimeGetSeconds($1.duration) }
        return ExportResult(outputURL: outputURL, duration: totalDuration, fileSize: fileSize(at: outputURL))
    }

    /// Renders each distinct board state once, sized for a `videoSize` frame (the reel's upright size), and pairs
    /// the bitmaps with the cues' reel-time ranges. A state that fails to render is left out (and logged).
    static func scoreboardOverlays(_ cues: [ReelScoreboardCue], videoSize: CGSize) -> [OverlayCue] {
        let layout = ReelScoreboardLayout(videoSize: videoSize)
        var rendered: [ReelScoreboardState: CGImage] = [:]
        return cues.compactMap { cue in
            if rendered[cue.state] == nil {
                rendered[cue.state] = ReelScoreboardRenderer.render(cue.state, layout: layout)
            }
            guard let image = rendered[cue.state] else {
                Log.video.error("Reel scoreboard: a board state failed to render")
                return nil
            }
            return OverlayCue(timeRange: cue.timeRange, image: image, origin: layout.origin)
        }
    }

    /// `scoreboardOverlays` sized for a reel cut from `source` (its first video track's upright size).
    static func scoreboardOverlays(_ cues: [ReelScoreboardCue], forReelFrom source: URL) async throws -> [OverlayCue] {
        guard !cues.isEmpty else { return [] }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrackInSource
        }
        let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
        extendLifetime(asset)  // a track does not keep its asset alive
        return scoreboardOverlays(
            cues, videoSize: uprightGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform).size)
    }

    /// Swaps the reel's video composition for one that draws the scoreboard over each frame.
    ///
    /// The Core Image composition shows the composition track's frames as stored (the track's preferredTransform
    /// is identity) and ignores any correction, so the board is only drawn over a source that is stored upright
    /// and needs no correction. The exported full video always is (it is rendered through a video composition); a
    /// raw camera file kept as the full video after a failed export may not be, so such a source keeps the plain
    /// reel, turned upright by makeComposition.
    private static func withScoreboard(
        _ scoreboard: [OverlayCue], on built: BuiltComposition, source: AVURLAsset,
        correction: VideoRotationCorrection
    ) async throws -> BuiltComposition {
        guard correction == .none else {
            Log.video.warning(
                "Reel scoreboard skipped: the source needs a \(correction.rawValue, privacy: .public) correction")
            return built
        }
        guard let sourceTrack = try await source.loadTracks(withMediaType: .video).first,
            try await sourceTrack.load(.preferredTransform).isIdentity
        else {
            Log.video.warning("Reel scoreboard skipped: the source video is not stored upright")
            return built
        }
        let reelDuration = built.composition.duration
        let overrun = CMTimeSubtract(scoreboard.map(\.timeRange.end).max() ?? .zero, reelDuration).seconds
        if overrun > 1.0 / 30 {
            Log.video.warning("Reel scoreboard runs \(overrun)s past the reel's end: cues may be misaligned")
        }
        let videoComposition = try await ReelOverlayComposer.videoComposition(for: built.composition, cues: scoreboard)
        Log.video.info(
            "Reel scoreboard: \(scoreboard.count) cue(s) over \(reelDuration.seconds)s, frame \(Int(videoComposition.renderSize.width))x\(Int(videoComposition.renderSize.height)), \(videoComposition.frameDuration.seconds)s per frame"
        )
        return BuiltComposition(composition: built.composition, videoComposition: videoComposition)
    }

    /// Converts clips to time ranges inside the asset, dropping empty or out-of-range clips.
    /// Pure so it can be unit-tested.
    nonisolated static func clipTimeRanges(for clips: [HighlightClipInfo], assetDuration: Double) -> [CMTimeRange] {
        clips.compactMap { clip -> CMTimeRange? in
            let clipStart = max(0, clip.startTimestamp)
            let clipEnd = min(assetDuration, clip.endTimestamp)
            let clipDuration = clipEnd - clipStart
            guard clipDuration > 0 else { return nil }
            return CMTimeRange(
                start: CMTime(seconds: clipStart, preferredTimescale: 600),
                duration: CMTime(seconds: clipDuration, preferredTimescale: 600)
            )
        }
    }

    /// Size of a track once its preferredTransform and then `correction` (a clockwise turn about the frame's
    /// centre) are applied, and the transform that puts the final frame at the origin. Pure so it can be
    /// unit-tested.
    nonisolated static func uprightGeometry(
        naturalSize: CGSize, preferredTransform: CGAffineTransform, correction: VideoRotationCorrection = .none
    ) -> (size: CGSize, transform: CGAffineTransform) {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let fix = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        let metadataSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        let transform = preferredTransform.concatenating(fix).concatenating(correction.transform(for: metadataSize))
        return (correction.rotatedSize(metadataSize), transform)
    }

    /// Places a `pieceSize` frame (upright, at the origin) in a `renderSize` frame: unchanged when the sizes match,
    /// otherwise scaled to fit (the smaller of the two ratios) and centred on whole pixels, so a piece shaped unlike
    /// the first one (a mid-match orientation change, a different correction) letterboxes instead of being cropped.
    /// The bands show the composition's black background. Pure so it can be unit-tested.
    nonisolated static func fitting(_ pieceSize: CGSize, into renderSize: CGSize) -> CGAffineTransform {
        guard pieceSize != renderSize, pieceSize.width > 0, pieceSize.height > 0 else { return .identity }
        let scale = min(renderSize.width / pieceSize.width, renderSize.height / pieceSize.height)
        // max(0, ...): rounding error must not floor a zero margin to -1
        let offsetX = max(0, ((renderSize.width - pieceSize.width * scale) / 2).rounded(.down))
        let offsetY = max(0, ((renderSize.height - pieceSize.height * scale) / 2).rounded(.down))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
    }

    // MARK: - Private Implementation

    private struct BuiltComposition {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    /// Inserts each (file, range) in order; nil range = the whole file. Every piece is rotated
    /// upright with its own preferredTransform, then by its entry in `corrections` (aligned with `clips`;
    /// missing entries are `.none`); the render size follows the first piece, and a piece of another size is
    /// scaled to fit and centred in it (`fitting`), never cropped.
    private static func makeComposition(
        clips: [(url: URL, range: CMTimeRange?)], corrections: [VideoRotationCorrection] = []
    ) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ExportError.failedToCreateVideoTrack
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var instructions: [AVVideoCompositionInstruction] = []
        var renderSize: CGSize?

        for (index, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                continue  // unreadable segment: skip rather than fail the whole export
            }
            let range: CMTimeRange
            if let explicit = clip.range {
                range = explicit
            } else {
                range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let audioTrack, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            let (naturalSize, preferredTransform) = try await sourceVideo.load(.naturalSize, .preferredTransform)
            let correction = corrections.indices.contains(index) ? corrections[index] : .none
            let geometry = uprightGeometry(
                naturalSize: naturalSize, preferredTransform: preferredTransform, correction: correction)
            let frame = renderSize ?? geometry.size
            renderSize = frame
            if geometry.size != frame {
                Log.video.warning(
                    "Export piece \(index) is \(Int(geometry.size.width))x\(Int(geometry.size.height)) in a \(Int(frame.width))x\(Int(frame.height)) frame: letterboxed"
                )
            }

            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
            layer.setTransform(geometry.transform.concatenating(fitting(geometry.size, into: frame)), at: cursor)
            let instruction = AVVideoCompositionInstruction.Configuration(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: cursor, duration: range.duration)
            )
            instructions.append(AVVideoCompositionInstruction(configuration: instruction))
            cursor = CMTimeAdd(cursor, range.duration)
        }

        guard let renderSize, cursor > .zero else { throw ExportError.noVideoTrackInSource }
        // An audio track nothing was inserted into (silent sources, e.g. the simulator's mock footage) makes the
        // export fail with AVFoundationErrorDomain -11838 "operation not supported for this media"
        if let audioTrack, audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }
        let configuration = AVVideoComposition.Configuration(
            frameDuration: CMTime(value: 1, timescale: 30),
            instructions: instructions,
            renderSize: renderSize
        )
        return BuiltComposition(
            composition: composition, videoComposition: AVVideoComposition(configuration: configuration))
    }

    private static func exportComposition(
        _ built: BuiltComposition,
        to outputURL: URL,
        quality: ExportQuality,
        progressHandler: @escaping ProgressHandler
    ) async throws {
        guard let exportSession = AVAssetExportSession(asset: built.composition, presetName: quality.preset) else {
            throw ExportError.failedToCreateExportSession
        }
        exportSession.videoComposition = built.videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        let states = exportSession.states(updateInterval: 0.25)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    progressHandler(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        try await exportSession.export(to: outputURL, as: quality.fileType)
        progressHandler(1.0)
    }

    // MARK: - Errors

    enum ExportError: Error, LocalizedError, Sendable {
        case noClips
        case failedToCreateVideoTrack
        case noVideoTrackInSource
        case failedToCreateExportSession

        var errorDescription: String? {
            switch self {
            case .noClips:
                return "No highlight clips to export"
            case .failedToCreateVideoTrack:
                return "Failed to create video track"
            case .noVideoTrackInSource:
                return "No video track in source file"
            case .failedToCreateExportSession:
                return "Failed to create export session"
            }
        }
    }
}
