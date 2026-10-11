//
//  MediaExportService.swift
//  score
//
//  Video export: concatenates the recorded segments of a match into one upright full video and joins ranges of
//  them into the highlight reel, each piece turned upright (preferredTransform, then the detected correction) and
//  letterboxed into the first piece's frame, with the scoreboard burned in, all drawn by one compositor
//  (`FrameCompositor`). Uses the iOS 26+ value-type AVVideoComposition configuration API and the iOS 18+ async
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

    /// A stretch of a source file in an export: the whole file (nil range) or a range of it in the file's own time
    /// base, and the extra turn the file needs on top of its preferredTransform (`VideoOrientationDetector`).
    nonisolated struct SourcePiece: Sendable {
        let url: URL
        let timeRange: CMTimeRange?
        let correction: VideoRotationCorrection

        init(url: URL, timeRange: CMTimeRange? = nil, correction: VideoRotationCorrection = .none) {
            self.url = url
            self.timeRange = timeRange
            self.correction = correction
        }
    }

    // MARK: - Full Video Export

    /// Concatenates `segments` (in order) into one upright movie. `corrections` is aligned with `segments` (a
    /// missing entry is `.none`): the extra turn each segment needs on top of its preferredTransform, as decided
    /// from its pictures by `VideoOrientationDetector`. `scoreboard` cues (times in the full video, see
    /// `MatchScoreboardTimeline`) are burned into the frames; empty = a plain video.
    static func exportFullVideo(
        segments: [URL],
        corrections: [VideoRotationCorrection] = [],
        scoreboard: [ReelScoreboardCue] = [],
        to outputURL: URL,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !segments.isEmpty else { throw ExportError.noVideoTrackInSource }
        try? FileManager.default.removeItem(at: outputURL)

        let pieces = segments.enumerated().map { index, url in
            SourcePiece(url: url, correction: corrections.indices.contains(index) ? corrections[index] : .none)
        }
        let built = try await makeComposition(pieces: pieces, scoreboard: scoreboard)
        try await exportComposition(built, to: outputURL, quality: quality, progressHandler: progressHandler)

        return ExportResult(
            outputURL: outputURL,
            duration: CMTimeGetSeconds(built.composition.duration),
            fileSize: fileSize(at: outputURL)
        )
    }

    // MARK: - Highlight Reel Export

    /// Joins `pieces` (ranges of the raw camera segments, each with its own correction) into one reel, in order.
    /// `scoreboard` cues (reel-time ranges, see `ReelScoreboardTimeline`) are burned into the frames; empty = a
    /// plain reel.
    static func exportHighlightReel(
        pieces: [SourcePiece],
        to outputURL: URL,
        scoreboard: [ReelScoreboardCue] = [],
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        let cut = pieces.filter { ($0.timeRange?.duration ?? .zero) > .zero }
        guard !cut.isEmpty else { throw ExportError.noClips }
        try? FileManager.default.removeItem(at: outputURL)

        let built = try await makeComposition(pieces: cut, scoreboard: scoreboard)
        try await exportComposition(built, to: outputURL, quality: quality, progressHandler: progressHandler)
        return ExportResult(
            outputURL: outputURL, duration: CMTimeGetSeconds(built.composition.duration),
            fileSize: fileSize(at: outputURL))
    }

    /// Cuts `clips` (times in `source`'s time base) out of one `source` into a reel, in order; `correction` is the
    /// extra turn `source` needs on top of its preferredTransform.
    static func exportHighlightReel(
        from source: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        scoreboard: [ReelScoreboardCue] = [],
        correction: VideoRotationCorrection = .none,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !clips.isEmpty else { throw ExportError.noClips }
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let timeRanges = clipTimeRanges(for: clips, assetDuration: durationSeconds)
        guard !timeRanges.isEmpty else { throw ExportError.noClips }
        return try await exportHighlightReel(
            pieces: timeRanges.map { SourcePiece(url: source, timeRange: $0, correction: correction) },
            to: outputURL, scoreboard: scoreboard, quality: quality, progressHandler: progressHandler)
    }

    /// The reel's pieces for `highlights` (wall-clock ranges, in reel order): each highlight's range of the
    /// concatenated video mapped back onto the segment files it was recorded in (two pieces when it crosses a
    /// segment boundary), with that segment's correction; `clips` pairs each highlight that has footage with how long
    /// it runs in the reel (for `ReelScoreboardTimeline`). `segments` and `corrections` line up with
    /// `timeline.segments`. Pure so it can be unit-tested.
    nonisolated static func reelPlan(
        for highlights: [HighlightClip], timeline: RecordingTimeline, segments: [URL],
        corrections: [VideoRotationCorrection]
    ) -> (pieces: [SourcePiece], clips: [ReelClip], withoutFootage: [HighlightClip]) {
        var pieces: [SourcePiece] = []
        var clips: [ReelClip] = []
        var withoutFootage: [HighlightClip] = []
        for highlight in highlights {
            let stretches =
                timeline.videoRange(wallStart: highlight.startTimestamp, wallEnd: highlight.endTimestamp)
                .map { timeline.segmentRanges(videoStart: $0.lowerBound, videoEnd: $0.upperBound) }?
                .filter { segments.indices.contains($0.segmentIndex) } ?? []
            guard !stretches.isEmpty else {
                withoutFootage.append(highlight)
                continue
            }
            for stretch in stretches {
                let index = stretch.segmentIndex
                let range = CMTimeRange(
                    start: CMTime(seconds: stretch.start, preferredTimescale: 600),
                    end: CMTime(seconds: stretch.end, preferredTimescale: 600))
                pieces.append(
                    SourcePiece(
                        url: segments[index], timeRange: range,
                        correction: corrections.indices.contains(index) ? corrections[index] : .none))
            }
            clips.append(ReelClip(highlight: highlight, reelDuration: stretches.map(\.duration).reduce(0, +)))
        }
        return (pieces, clips, withoutFootage)
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

    /// Inserts each piece in order (nil range = the whole file) and draws it with `FrameCompositor`: every piece is
    /// rotated upright with its own preferredTransform, then by its correction; the render size follows the first
    /// piece, and a piece of another size is scaled to fit and centred in it (`fitting`), never cropped. Non-empty
    /// `scoreboard` cues are drawn over the frames, rendered as the export reaches them (`ScoreboardOverlaySource`).
    private static func makeComposition(
        pieces: [SourcePiece], scoreboard: [ReelScoreboardCue] = []
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
        var placed: [(range: CMTimeRange, transform: CGAffineTransform)] = []
        var renderSize: CGSize?

        for (index, piece) in pieces.enumerated() {
            let asset = AVURLAsset(url: piece.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                continue  // unreadable segment: skip rather than fail the whole export
            }
            let range: CMTimeRange
            if let explicit = piece.timeRange {
                range = explicit
            } else {
                range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let audioTrack, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            let (naturalSize, preferredTransform) = try await sourceVideo.load(.naturalSize, .preferredTransform)
            let geometry = uprightGeometry(
                naturalSize: naturalSize, preferredTransform: preferredTransform, correction: piece.correction)
            let frame = renderSize ?? geometry.size
            renderSize = frame
            if geometry.size != frame {
                Log.video.warning(
                    "Export piece \(index) is \(Int(geometry.size.width))x\(Int(geometry.size.height)) in a \(Int(frame.width))x\(Int(frame.height)) frame: letterboxed"
                )
            }
            placed.append(
                (
                    CMTimeRange(start: cursor, duration: range.duration),
                    geometry.transform.concatenating(fitting(geometry.size, into: frame))
                ))
            cursor = CMTimeAdd(cursor, range.duration)
        }

        guard let renderSize, cursor > .zero else { throw ExportError.noVideoTrackInSource }
        // An audio track nothing was inserted into (silent sources, e.g. the simulator's mock footage) makes the
        // export fail with AVFoundationErrorDomain -11838 "operation not supported for this media"
        if let audioTrack, audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }
        let overlay = scoreboardSource(scoreboard, renderSize: renderSize, duration: cursor)
        return BuiltComposition(
            composition: composition,
            videoComposition: frameComposition(
                placed, trackID: videoTrack.trackID, renderSize: renderSize, overlay: overlay))
    }

    /// `FrameCompositor` drawing each placed piece (its composition range and stored-to-frame transform) at
    /// `renderSize`, 30 frames a second, tagged Rec. 709 like the camera's SDR footage.
    private static func frameComposition(
        _ placed: [(range: CMTimeRange, transform: CGAffineTransform)], trackID: CMPersistentTrackID,
        renderSize: CGSize, overlay: ScoreboardOverlaySource?
    ) -> AVVideoComposition {
        let instructions = placed.map { piece in
            FrameInstruction(
                timeRange: piece.range, trackID: trackID, transform: piece.transform, renderSize: renderSize,
                overlay: overlay)
        }
        let configuration = AVVideoComposition.Configuration(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: FrameCompositor.self,
            frameDuration: CMTime(value: 1, timescale: 30),
            instructions: instructions,
            renderSize: renderSize
        )
        return AVVideoComposition(configuration: configuration)
    }

    /// The lazy board source for a `renderSize` frame, or nil without cues. Logs the cues and warns when they run
    /// past the composition's end (misaligned times).
    private static func scoreboardSource(
        _ cues: [ReelScoreboardCue], renderSize: CGSize, duration: CMTime
    ) -> ScoreboardOverlaySource? {
        guard !cues.isEmpty else { return nil }
        let overrun = CMTimeSubtract(cues.map(\.timeRange.end).max() ?? .zero, duration).seconds
        if overrun > 1.0 / 30 {
            Log.video.warning("Scoreboard runs \(overrun)s past the video's end: cues may be misaligned")
        }
        Log.video.info(
            "Scoreboard: \(cues.count) cue(s), \(Set(cues.map(\.state)).count) board(s) over \(duration.seconds)s, frame \(Int(renderSize.width))x\(Int(renderSize.height))"
        )
        return ScoreboardOverlaySource(cues: cues, videoSize: renderSize)
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
