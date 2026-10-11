//
//  DetectOrientation.swift
//  scripts/orientation (macOS command-line harness, built by scripts/detect-orientation.sh)
//
//  Runs the app's own VideoOrientationDetector (compiled from score/ unchanged) on the Mac, where Vision's human
//  body pose model runs (it has no compute device on the iOS simulator). Two modes:
//
//    detect-orientation <video>...      print each video's per-orientation scores, decision and detection time
//    detect-orientation --selftest <png> <dir>
//                                       fit the picture (people in it) into a 1280x720 frame, turn it by each
//                                       correction's inverse, write a 3 s video (and a PNG) per turn into <dir> and
//                                       check the detector picks the correction that turns it back (exit 1 if not)
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

@main
struct DetectOrientation {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--selftest", arguments.count == 3 {
            exit(
                await selfTest(
                    picture: URL(fileURLWithPath: arguments[1]), directory: URL(fileURLWithPath: arguments[2])) ? 0 : 1)
        }
        guard !arguments.isEmpty else {
            say("usage: detect-orientation <video>... | --selftest <png> <dir>")
            exit(2)
        }
        for path in arguments {
            _ = await detect(URL(fileURLWithPath: path))
        }
    }

    /// One line on stdout (this is a command-line tool, not the app: no Logger).
    static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    @discardableResult
    static func detect(_ url: URL) async -> VideoRotationCorrection {
        let clock = ContinuousClock()
        let start = clock.now
        let detection = await VideoOrientationDetector.correction(for: url)
        let elapsed = clock.now - start
        say(
            "\(url.lastPathComponent): \(detection.correction.rawValue)  "
                + "[\(VideoOrientationDetector.describe(detection.scores))]  "
                + "\(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
        return detection.correction
    }

    // MARK: - Self test

    static func selfTest(picture: URL, directory: URL) async -> Bool {
        guard let source = CGImageSourceCreateWithURL(picture as CFURL, nil),
            let picture = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let scene = landscapeFrame(picture)
        else {
            say("cannot read \(picture.path)")
            return false
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var passed = true
        for correction in VideoRotationCorrection.allCases {
            // The picture as a camera would record it if the phone were turned the other way
            guard let turned = turnedCounterclockwise(scene, degrees: correction.degrees) else { return false }
            let url = directory.appendingPathComponent("needs-\(correction.rawValue).mov")
            savePNG(turned, to: url.deletingPathExtension().appendingPathExtension("png"))
            do {
                try await writeStillVideo(turned, to: url, seconds: 3)
            } catch {
                say("cannot write \(url.path): \(error)")
                return false
            }
            let detected = await detect(url)
            let verdict = detected == correction ? "ok" : "MISMATCH (expected \(correction.rawValue))"
            say("  -> \(verdict)")
            passed = passed && detected == correction
        }
        say(passed ? "selftest passed" : "selftest FAILED")
        return passed
    }

    /// The picture fitted into a 1280x720 grey frame, like a landscape recording.
    static func landscapeFrame(_ picture: CGImage) -> CGImage? {
        guard let context = bitmap(width: 1280, height: 720) else { return nil }
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        let scale = min(1280 / CGFloat(picture.width), 720 / CGFloat(picture.height))
        let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
        context.draw(
            picture,
            in: CGRect(x: (1280 - size.width) / 2, y: (720 - size.height) / 2, width: size.width, height: size.height))
        return context.makeImage()
    }

    static func savePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// `image` turned counterclockwise by `degrees`, so it needs a `degrees` clockwise turn to look upright.
    /// Core Graphics contexts are y-up, so a positive angle turns the picture counterclockwise on screen.
    static func turnedCounterclockwise(_ image: CGImage, degrees: Int) -> CGImage? {
        let quarter = !degrees.isMultiple(of: 180)
        let width = quarter ? image.height : image.width
        let height = quarter ? image.width : image.height
        guard let context = bitmap(width: width, height: height) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(degrees) * .pi / 180)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width),
                height: CGFloat(image.height)))
        return context.makeImage()
    }

    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// A `seconds` long H.264 movie (10 fps) showing `image` in every frame.
    static func writeStillVideo(_ image: CGImage, to url: URL, seconds: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
