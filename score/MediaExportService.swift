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
import CoreMedia
import Foundation

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

    /// Concatenates `segments` (in order) into one upright movie.
    static func exportFullVideo(
        segments: [URL],
        to outputURL: URL,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !segments.isEmpty else { throw ExportError.noVideoTrackInSource }
        try? FileManager.default.removeItem(at: outputURL)

        let built = try await makeComposition(clips: segments.map { ($0, nil) })
        try await exportComposition(built, to: outputURL, quality: quality, progressHandler: progressHandler)

        return ExportResult(
            outputURL: outputURL,
            duration: CMTimeGetSeconds(built.composition.duration),
            fileSize: fileSize(at: outputURL)
        )
    }

    // MARK: - Highlight Reel Export

    /// Cuts `clips` (times in `source`'s time base) out of `source` into one reel, in order.
    static func exportHighlightReel(
        from source: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !clips.isEmpty else { throw ExportError.noClips }
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let timeRanges = clipTimeRanges(for: clips, assetDuration: durationSeconds)
        guard !timeRanges.isEmpty else { throw ExportError.noClips }

        let built = try await makeComposition(clips: timeRanges.map { (source, $0) })
        try await exportComposition(built, to: outputURL, quality: quality, progressHandler: progressHandler)

        let totalDuration = timeRanges.reduce(0) { $0 + CMTimeGetSeconds($1.duration) }
        return ExportResult(outputURL: outputURL, duration: totalDuration, fileSize: fileSize(at: outputURL))
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

    /// Size of a track once its preferredTransform is applied, and the transform that puts
    /// the rotated frame at the origin. Pure so it can be unit-tested.
    nonisolated static func uprightGeometry(
        naturalSize: CGSize, preferredTransform: CGAffineTransform
    ) -> (size: CGSize, transform: CGAffineTransform) {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let fix = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        return (CGSize(width: abs(rect.width), height: abs(rect.height)), preferredTransform.concatenating(fix))
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
    /// upright with its own preferredTransform; the render size follows the first piece.
    private static func makeComposition(clips: [(url: URL, range: CMTimeRange?)]) async throws -> BuiltComposition {
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

        for clip in clips {
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
            let geometry = uprightGeometry(naturalSize: naturalSize, preferredTransform: preferredTransform)
            if renderSize == nil { renderSize = geometry.size }

            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
            layer.setTransform(geometry.transform, at: cursor)
            let instruction = AVVideoCompositionInstruction.Configuration(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: cursor, duration: range.duration)
            )
            instructions.append(AVVideoCompositionInstruction(configuration: instruction))
            cursor = CMTimeAdd(cursor, range.duration)
        }

        guard let renderSize, cursor > .zero else { throw ExportError.noVideoTrackInSource }
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
