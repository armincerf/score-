//
//  MockVideoGenerator.swift
//  score
//
//  Generate mock video for simulator testing
//

import AVFoundation
import UIKit
import CoreImage

class MockVideoGenerator {
    static func generateMockVideo(duration: TimeInterval = 60.0) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "mock_match_\(Date().timeIntervalSince1970).mov"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Remove old file if exists
        try? FileManager.default.removeItem(at: fileURL)

        let videoSize = CGSize(width: 1280, height: 720)

        guard let videoWriter = try? AVAssetWriter(outputURL: fileURL, fileType: .mov) else {
            print("[Mock] Failed to create video writer")
            return nil
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6000000,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: videoSize.width,
                kCVPixelBufferHeightKey as String: videoSize.height
            ]
        )

        videoWriter.add(videoInput)

        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let totalFrames = Int(duration * Double(fps))

        var frameCount: Int64 = 0

        print("[Mock] Generating \(totalFrames) frames...")

        for frame in 0..<totalFrames {
            autoreleasepool {
                let currentTime = Double(frame) / Double(fps)

                while !videoInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                if let buffer = createFrame(size: videoSize, time: currentTime, frameNumber: frame) {
                    let presentationTime = CMTime(value: frameCount, timescale: CMTimeScale(fps))
                    adaptor.append(buffer, withPresentationTime: presentationTime)
                    frameCount += 1
                }
            }
        }

        videoInput.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        videoWriter.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if videoWriter.status == .completed {
            print("[Mock] Video generated successfully: \(fileURL.lastPathComponent)")
            print("[Mock] Duration: \(duration)s, Frames: \(totalFrames)")
            return fileURL
        } else {
            print("[Mock] Video generation failed: \(String(describing: videoWriter.error))")
            return nil
        }
    }

    private static func createFrame(size: CGSize, time: TimeInterval, frameNumber: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            options as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        // Create gradient background that changes over time
        let hue = (time / 10.0).truncatingRemainder(dividingBy: 1.0)
        let backgroundColor = UIColor(hue: hue, saturation: 0.3, brightness: 0.2, alpha: 1.0)
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        // Draw court-like lines
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(4)

        // Center line
        context.move(to: CGPoint(x: size.width / 2, y: 0))
        context.addLine(to: CGPoint(x: size.width / 2, y: size.height))
        context.strokePath()

        // Draw timestamp
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let timeString = String(format: "%d:%02d", minutes, seconds)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 80, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraphStyle,
            .strokeColor: UIColor.black,
            .strokeWidth: -3
        ]

        let attrString = NSAttributedString(string: timeString, attributes: attributes)
        let textRect = CGRect(x: 0, y: size.height / 2 - 50, width: size.width, height: 100)

        attrString.draw(in: textRect)

        // Draw "MOCK VIDEO" label
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            .paragraphStyle: paragraphStyle
        ]

        let label = NSAttributedString(string: "MOCK MATCH VIDEO", attributes: labelAttributes)
        let labelRect = CGRect(x: 0, y: 40, width: size.width, height: 40)
        label.draw(in: labelRect)

        return buffer
    }
}
