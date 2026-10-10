//
//  MediaExportService.swift
//  score
//
//  Shared video export for the full match recording and the highlight reel.
//  Uses the iOS 26+ value-type AVVideoComposition configuration API and the
//  iOS 18+ async AVAssetExportSession API with live progress.
//

import AVFoundation
import CoreMedia
import Foundation
import UIKit

enum MediaExportService {
    // MARK: - Video Orientation

    enum VideoOrientation: Sendable, CustomStringConvertible {
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight

        var description: String {
            switch self {
            case .portrait: return "portrait"
            case .portraitUpsideDown: return "portraitUpsideDown"
            case .landscapeLeft: return "landscapeLeft"
            case .landscapeRight: return "landscapeRight"
            }
        }

        var isLandscape: Bool {
            self == .landscapeLeft || self == .landscapeRight
        }

        /// AVCaptureConnection.videoRotationAngle that records this orientation upright.
        var rotationAngle: CGFloat {
            switch self {
            case .portrait: return 90
            case .portraitUpsideDown: return 270
            case .landscapeLeft: return 0
            case .landscapeRight: return 180
            }
        }

        static func from(deviceOrientation: UIDeviceOrientation) -> VideoOrientation {
            switch deviceOrientation {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeLeft
            case .landscapeRight: return .landscapeRight
            default: return .portrait
            }
        }

        @MainActor
        static func current() -> VideoOrientation {
            from(deviceOrientation: UIDevice.current.orientation)
        }
    }

    // MARK: - Export Quality

    enum ExportQuality: Sendable {
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

    struct HighlightClipInfo: Sendable {
        let startTimestamp: Double
        let endTimestamp: Double
        let player: Int?
        let gameNumber: Int

        var duration: Double {
            endTimestamp - startTimestamp
        }
    }

    // MARK: - Export Options

    struct ExportOptions: Sendable {
        let quality: ExportQuality
        let orientation: VideoOrientation
        let includeAudio: Bool
        let optimizeForNetworkUse: Bool

        static let `default` = ExportOptions()

        init(
            quality: ExportQuality = .hd720p,
            orientation: VideoOrientation = .landscapeLeft,
            includeAudio: Bool = true,
            optimizeForNetworkUse: Bool = true
        ) {
            self.quality = quality
            self.orientation = orientation
            self.includeAudio = includeAudio
            self.optimizeForNetworkUse = optimizeForNetworkUse
        }
    }

    /// Progress callback in 0...1. Always invoked on the main actor.
    typealias ProgressHandler = @MainActor @Sendable (Double) -> Void

    // MARK: - Full Video Export

    static func exportFullVideo(
        from sourceURL: URL,
        to outputURL: URL,
        orientation: VideoOrientation,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        try await exportFullVideo(
            from: sourceURL,
            to: outputURL,
            options: ExportOptions(quality: quality, orientation: orientation),
            progressHandler: progressHandler
        )
    }

    static func exportFullVideo(
        from sourceURL: URL,
        to outputURL: URL,
        options: ExportOptions,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)

        let composition = try await createOrientedComposition(
            from: asset,
            orientation: options.orientation,
            timeRanges: nil,
            includeAudio: options.includeAudio
        )

        try await exportComposition(
            composition.composition,
            videoComposition: composition.videoComposition,
            to: outputURL,
            options: options,
            progressHandler: progressHandler
        )

        return ExportResult(
            outputURL: outputURL,
            duration: CMTimeGetSeconds(duration),
            fileSize: fileSize(at: outputURL)
        )
    }

    // MARK: - Highlight Reel Export

    static func exportHighlightReel(
        from sourceURL: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        orientation: VideoOrientation,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        try await exportHighlightReel(
            from: sourceURL,
            to: outputURL,
            clips: clips,
            options: ExportOptions(quality: quality, orientation: orientation),
            progressHandler: progressHandler
        )
    }

    static func exportHighlightReel(
        from sourceURL: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        options: ExportOptions,
        progressHandler: @escaping ProgressHandler = { _ in }
    ) async throws -> ExportResult {
        guard !clips.isEmpty else {
            throw ExportError.noClips
        }

        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let timeRanges = clipTimeRanges(for: clips, assetDuration: durationSeconds)

        guard !timeRanges.isEmpty else {
            throw ExportError.noClips
        }

        let composition = try await createOrientedComposition(
            from: asset,
            orientation: options.orientation,
            timeRanges: timeRanges,
            includeAudio: options.includeAudio
        )

        try await exportComposition(
            composition.composition,
            videoComposition: composition.videoComposition,
            to: outputURL,
            options: options,
            progressHandler: progressHandler
        )

        let totalDuration = timeRanges.reduce(0) { $0 + CMTimeGetSeconds($1.duration) }
        return ExportResult(
            outputURL: outputURL,
            duration: totalDuration,
            fileSize: fileSize(at: outputURL)
        )
    }

    /// Converts highlight clips to time ranges inside the asset, dropping empty or out-of-range clips.
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

    // MARK: - Private Implementation

    private struct CompositionResult {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }

    private static func createOrientedComposition(
        from asset: AVURLAsset,
        orientation: VideoOrientation,
        timeRanges: [CMTimeRange]?,
        includeAudio: Bool
    ) async throws -> CompositionResult {
        let composition = AVMutableComposition()

        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw ExportError.failedToCreateVideoTrack
        }

        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrackInSource
        }

        var audioTrack: AVMutableCompositionTrack?
        var sourceAudioTrack: AVAssetTrack?

        if includeAudio {
            sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first
            if sourceAudioTrack != nil {
                audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            }
        }

        if let ranges = timeRanges {
            var currentTime = CMTime.zero
            for range in ranges {
                try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: currentTime)
                if let sourceAudio = sourceAudioTrack, let audioTrack {
                    try? audioTrack.insertTimeRange(range, of: sourceAudio, at: currentTime)
                }
                currentTime = CMTimeAdd(currentTime, range.duration)
            }
        } else {
            let duration = try await asset.load(.duration)
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(fullRange, of: sourceVideoTrack, at: .zero)
            if let sourceAudio = sourceAudioTrack, let audioTrack {
                try? audioTrack.insertTimeRange(fullRange, of: sourceAudio, at: .zero)
            }
        }

        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        let videoComposition = createVideoComposition(
            for: composition,
            videoTrack: videoTrack,
            naturalSize: naturalSize,
            sourceTransform: preferredTransform,
            targetOrientation: orientation
        )

        return CompositionResult(composition: composition, videoComposition: videoComposition)
    }

    private static func createVideoComposition(
        for composition: AVMutableComposition,
        videoTrack: AVMutableCompositionTrack,
        naturalSize: CGSize,
        sourceTransform: CGAffineTransform,
        targetOrientation: VideoOrientation
    ) -> AVVideoComposition {
        let isSourceRotated = abs(sourceTransform.b) == 1.0
        let sourceWidth = isSourceRotated ? naturalSize.height : naturalSize.width
        let sourceHeight = isSourceRotated ? naturalSize.width : naturalSize.height

        let renderSize: CGSize
        let layerTransform: CGAffineTransform

        switch targetOrientation {
        case .landscapeLeft:
            renderSize = CGSize(width: sourceWidth, height: sourceHeight)
            layerTransform = .identity
        case .landscapeRight:
            renderSize = CGSize(width: sourceWidth, height: sourceHeight)
            layerTransform = CGAffineTransform(translationX: sourceWidth, y: sourceHeight).rotated(by: .pi)
        case .portrait:
            renderSize = CGSize(width: sourceHeight, height: sourceWidth)
            layerTransform = CGAffineTransform(translationX: sourceHeight, y: 0).rotated(by: .pi / 2)
        case .portraitUpsideDown:
            renderSize = CGSize(width: sourceHeight, height: sourceWidth)
            layerTransform = CGAffineTransform(translationX: 0, y: sourceWidth).rotated(by: -.pi / 2)
        }

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
        layer.setTransform(sourceTransform.concatenating(layerTransform), at: .zero)

        let instruction = AVVideoCompositionInstruction.Configuration(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: composition.duration)
        )

        let configuration = AVVideoComposition.Configuration(
            frameDuration: CMTime(value: 1, timescale: 30),
            instructions: [AVVideoCompositionInstruction(configuration: instruction)],
            renderSize: renderSize
        )
        return AVVideoComposition(configuration: configuration)
    }

    private static func exportComposition(
        _ composition: AVMutableComposition,
        videoComposition: AVVideoComposition?,
        to outputURL: URL,
        options: ExportOptions,
        progressHandler: @escaping ProgressHandler
    ) async throws {
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: options.quality.preset) else {
            throw ExportError.failedToCreateExportSession
        }

        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = options.optimizeForNetworkUse

        let states = exportSession.states(updateInterval: 0.25)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let progress) = state {
                    progressHandler(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        try await exportSession.export(to: outputURL, as: options.quality.fileType)
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
