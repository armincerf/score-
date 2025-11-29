//
//  MediaExportService.swift
//  score
//
//  Shared video export functionality for highlights and full match clips
//  Designed for iOS 18+ with Swift 6 concurrency
//

import Foundation
import AVFoundation
import UIKit
import CoreMedia

// MARK: - Media Export Service

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
        
        var rotationAngle: CGFloat {
            switch self {
            case .portrait: return 90
            case .portraitUpsideDown: return 270
            case .landscapeLeft: return 0
            case .landscapeRight: return 180
            }
        }
        
        var preferredTransform: CGAffineTransform {
            switch self {
            case .portrait:
                return CGAffineTransform(rotationAngle: .pi / 2)
            case .portraitUpsideDown:
                return CGAffineTransform(rotationAngle: -.pi / 2)
            case .landscapeLeft:
                return .identity
            case .landscapeRight:
                return CGAffineTransform(rotationAngle: .pi)
            }
        }
        
        var isLandscape: Bool {
            self == .landscapeLeft || self == .landscapeRight
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
        
        var fileType: AVFileType {
            switch self {
            case .hevcHighestQuality:
                return .mov
            default:
                return .mov
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
        
        static let `default` = ExportOptions(
            quality: .hd720p,
            orientation: .landscapeLeft,
            includeAudio: true,
            optimizeForNetworkUse: true
        )
        
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
    
    // MARK: - Full Video Export
    
    static func exportFullVideo(
        from sourceURL: URL,
        to outputURL: URL,
        orientation: VideoOrientation,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ExportResult {
        let options = ExportOptions(quality: quality, orientation: orientation)
        return try await exportFullVideo(
            from: sourceURL,
            to: outputURL,
            options: options,
            progressHandler: progressHandler
        )
    }
    
    static func exportFullVideo(
        from sourceURL: URL,
        to outputURL: URL,
        options: ExportOptions,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ExportResult {
        try? FileManager.default.removeItem(at: outputURL)
        
        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        
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
        
        let fileSize = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64
        
        return ExportResult(
            outputURL: outputURL,
            duration: CMTimeGetSeconds(duration),
            fileSize: fileSize
        )
    }
    
    // MARK: - Highlight Reel Export
    
    static func exportHighlightReel(
        from sourceURL: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        orientation: VideoOrientation,
        quality: ExportQuality = .hd720p,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ExportResult {
        let options = ExportOptions(quality: quality, orientation: orientation)
        return try await exportHighlightReel(
            from: sourceURL,
            to: outputURL,
            clips: clips,
            options: options,
            progressHandler: progressHandler
        )
    }
    
    static func exportHighlightReel(
        from sourceURL: URL,
        to outputURL: URL,
        clips: [HighlightClipInfo],
        options: ExportOptions,
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ExportResult {
        guard !clips.isEmpty else {
            throw ExportError.noClips
        }
        
        try? FileManager.default.removeItem(at: outputURL)
        
        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        let timeRanges = clips.compactMap { clip -> CMTimeRange? in
            let clipStart = clip.startTimestamp
            let clipEnd = min(durationSeconds, clip.endTimestamp)
            let clipDuration = clipEnd - clipStart
            
            guard clipDuration > 0 else { return nil }
            
            let startTime = CMTime(seconds: clipStart, preferredTimescale: 600)
            let clipDurationTime = CMTime(seconds: clipDuration, preferredTimescale: 600)
            
            return CMTimeRange(start: startTime, duration: clipDurationTime)
        }
        
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
        let fileSize = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64
        
        return ExportResult(
            outputURL: outputURL,
            duration: totalDuration,
            fileSize: fileSize
        )
    }
    
    // MARK: - Video Metadata
    
    struct VideoMetadata: Sendable {
        let duration: TimeInterval
        let naturalSize: CGSize
        let frameRate: Float
        let hasAudio: Bool
        let isHDR: Bool
        let codec: String?
    }
    
    static func loadMetadata(from url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        
        let duration = try await asset.load(.duration)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrackInSource
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let codec = formatDescriptions.first.flatMap { desc -> String? in
            let codecType = CMFormatDescriptionGetMediaSubType(desc)
            return FourCharCode(codecType).description
        }
        
        let isHDR = formatDescriptions.first.map { desc -> Bool in
            if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                return extensions["CVImageBufferColorPrimaries"] as? String == "ITU_R_2020"
            }
            return false
        } ?? false
        
        return VideoMetadata(
            duration: CMTimeGetSeconds(duration),
            naturalSize: naturalSize,
            frameRate: nominalFrameRate,
            hasAudio: !audioTracks.isEmpty,
            isHDR: isHDR,
            codec: codec
        )
    }
    
    // MARK: - Check Export Compatibility
    
    static func isExportCompatible(
        for asset: AVAsset,
        with quality: ExportQuality
    ) async -> Bool {
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        return compatiblePresets.contains(quality.preset)
    }
    
    // MARK: - Private Implementation
    
    private struct CompositionResult {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
    }
    
    private static func createOrientedComposition(
        from asset: AVURLAsset,
        orientation: VideoOrientation,
        timeRanges: [CMTimeRange]?,
        includeAudio: Bool
    ) async throws -> CompositionResult {
        let composition = AVMutableComposition()
        
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.failedToCreateVideoTrack
        }
        
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrackInSource
        }
        
        var audioTrack: AVMutableCompositionTrack?
        var sourceAudioTrack: AVAssetTrack?
        
        if includeAudio {
            let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
            sourceAudioTrack = sourceAudioTracks.first
            
            if sourceAudioTrack != nil {
                audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            }
        }
        
        var currentTime = CMTime.zero
        
        if let ranges = timeRanges {
            for range in ranges {
                try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: currentTime)
                
                if let sourceAudio = sourceAudioTrack, let audioTrack = audioTrack {
                    try? audioTrack.insertTimeRange(range, of: sourceAudio, at: currentTime)
                }
                
                currentTime = CMTimeAdd(currentTime, range.duration)
            }
        } else {
            let duration = try await asset.load(.duration)
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(fullRange, of: sourceVideoTrack, at: .zero)
            
            if let sourceAudio = sourceAudioTrack, let audioTrack = audioTrack {
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
        
        return CompositionResult(
            composition: composition,
            videoComposition: videoComposition
        )
    }
    
    private static func createVideoComposition(
        for composition: AVMutableComposition,
        videoTrack: AVMutableCompositionTrack,
        naturalSize: CGSize,
        sourceTransform: CGAffineTransform,
        targetOrientation: VideoOrientation
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let isSourceRotated = abs(sourceTransform.b) == 1.0
        let sourceWidth = isSourceRotated ? naturalSize.height : naturalSize.width
        let sourceHeight = isSourceRotated ? naturalSize.width : naturalSize.height
        
        let renderSize: CGSize
        let layerTransform: CGAffineTransform
        
        switch targetOrientation {
        case .landscapeLeft, .landscapeRight:
            renderSize = CGSize(width: sourceWidth, height: sourceHeight)
            
            if targetOrientation == .landscapeRight {
                var transform = CGAffineTransform(translationX: sourceWidth, y: sourceHeight)
                transform = transform.rotated(by: .pi)
                layerTransform = transform
            } else {
                layerTransform = .identity
            }
            
        case .portrait, .portraitUpsideDown:
            renderSize = CGSize(width: sourceHeight, height: sourceWidth)
            
            if targetOrientation == .portrait {
                var transform = CGAffineTransform(translationX: sourceHeight, y: 0)
                transform = transform.rotated(by: .pi / 2)
                layerTransform = transform
            } else {
                var transform = CGAffineTransform(translationX: 0, y: sourceWidth)
                transform = transform.rotated(by: -.pi / 2)
                layerTransform = transform
            }
        }
        
        videoComposition.renderSize = renderSize
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        
        let combinedTransform = sourceTransform.concatenating(layerTransform)
        layerInstruction.setTransform(combinedTransform, at: .zero)
        
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        return videoComposition
    }
    
    private static func exportComposition(
        _ composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        to outputURL: URL,
        options: ExportOptions,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: options.quality.preset
        ) else {
            throw ExportError.failedToCreateExportSession
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = options.quality.fileType
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = options.optimizeForNetworkUse
        
        try await exportSession.export(to: outputURL, as: options.quality.fileType)
        
        await MainActor.run {
            progressHandler(1.0)
        }
    }
    
    // MARK: - Errors
    
    enum ExportError: Error, LocalizedError, Sendable {
        case noClips
        case failedToCreateVideoTrack
        case noVideoTrackInSource
        case failedToCreateExportSession
        case exportFailed(String)
        case unsupportedFormat
        case cancelled
        
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
            case .exportFailed(let message):
                return "Export failed: \(message)"
            case .unsupportedFormat:
                return "Unsupported video format"
            case .cancelled:
                return "Export was cancelled"
            }
        }
    }
}

// MARK: - FourCharCode Extension

private extension FourCharCode {
    var description: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
