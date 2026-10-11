//
//  MockVideoGenerator.swift
//  score
//
//  Generates a synthetic match video so the simulator (which has no camera)
//  can exercise the export and highlight pipeline end to end.
//

import AVFoundation
import CoreVideo
import UIKit
import os

nonisolated enum MockVideoGenerator {
    private static let videoSize = CGSize(width: 1280, height: 720)
    private static let fps: Int32 = 30

    /// Renders `duration` seconds of placeholder frames into a temporary .mov file.
    /// Runs off the main actor; returns nil if writing fails.
    @concurrent
    static func generateMockVideo(duration: TimeInterval = 60.0, to outputURL: URL? = nil) async -> URL? {
        let fileURL =
            outputURL
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("mock_match_\(Date().timeIntervalSince1970).mov")
        try? FileManager.default.removeItem(at: fileURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
        } catch {
            Log.video.error("Mock: failed to create video writer: \(error)")
            return nil
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)

        do {
            try writer.start()
        } catch {
            Log.video.error("Mock: failed to start writer: \(error)")
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(duration * Double(fps))
        Log.video.debug("Mock: generating \(totalFrames) frames...")

        for frame in 0..<totalFrames {
            let currentTime = Double(frame) / Double(fps)
            guard let buffer = createFrame(time: currentTime) else { continue }
            let presentationTime = CMTime(value: Int64(frame), timescale: fps)
            do {
                try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: presentationTime)
            } catch {
                Log.video.error("Mock: failed to append frame \(frame): \(error)")
                break
            }
        }

        receiver.finish()
        await writer.finishWriting()

        guard writer.status == .completed else {
            Log.video.error("Mock: video generation failed: \(String(describing: writer.error))")
            return nil
        }
        Log.video.info("Mock: video generated (\(Int(duration))s, \(totalFrames) frames): \(fileURL.lastPathComponent)")
        return fileURL
    }

    private static func createFrame(time: TimeInterval) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(videoSize.width),
            Int(videoSize.height),
            kCVPixelFormatType_32ARGB,
            options as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(videoSize.width),
                height: Int(videoSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else {
            return nil
        }

        draw(in: context, time: time)
        return buffer
    }

    private static func draw(in context: CGContext, time: TimeInterval) {
        // UIKit draws in top-left coordinates, but a bitmap context's origin is bottom-left: flip it first, or the
        // text comes out upside down and mirrored with the caption at the bottom
        context.translateBy(x: 0, y: videoSize.height)
        context.scaleBy(x: 1, y: -1)
        // UIKit string drawing needs a current context; push ours for the duration of the draw.
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // Gradient background that drifts over time
        let hue = (time / 10.0).truncatingRemainder(dividingBy: 1.0)
        context.setFillColor(UIColor(hue: hue, saturation: 0.3, brightness: 0.2, alpha: 1.0).cgColor)
        context.fill(CGRect(origin: .zero, size: videoSize))

        // Court centre line
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(4)
        context.move(to: CGPoint(x: videoSize.width / 2, y: 0))
        context.addLine(to: CGPoint(x: videoSize.width / 2, y: videoSize.height))
        context.strokePath()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let timeString = String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 80, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle,
            .strokeColor: UIColor.black,
            .strokeWidth: -3,
        ]
        NSAttributedString(string: timeString, attributes: timeAttributes)
            .draw(in: CGRect(x: 0, y: videoSize.height / 2 - 50, width: videoSize.width, height: 100))

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            .paragraphStyle: paragraphStyle,
        ]
        NSAttributedString(string: "MOCK MATCH VIDEO", attributes: labelAttributes)
            .draw(in: CGRect(x: 0, y: 40, width: videoSize.width, height: 40))
    }
}
