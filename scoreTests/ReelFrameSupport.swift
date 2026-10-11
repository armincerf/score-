//
//  ReelFrameSupport.swift
//  scoreTests
//
//  Shared by the reel suites (ReelOverlayTests, ReelExportTests): where inspected frames are written, reading a
//  frame back out of an exported movie, saving PNGs for a person to look at, and pixel access for the checks.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
import UIKit

enum ReelFrames {
    /// Where exported movies and inspected frames are written: `REEL_FRAMES_DIR` (make test sets it to
    /// .build/shots/reel on the Mac, because xcodebuild runs tests in a throwaway simulator clone) or, failing
    /// that, the same folder found from this source file (the simulator can write to the Mac's filesystem).
    static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["REEL_FRAMES_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent(".build/shots/reel", isDirectory: true)
    }

    static func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    /// The frame shown at `seconds` (exact, no tolerance), upright.
    static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: Self.seconds(seconds)).image
    }

    static func savePNG(_ image: CGImage, name: String, in directory: URL = outputDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(UIImage(cgImage: image).pngData(), "PNG encoding failed for \(describe(image))")
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    static func describe(_ image: CGImage) -> String {
        let space = image.colorSpace.flatMap { $0.name as String? } ?? "nil"
        return "\(image.width)x\(image.height) bpc=\(image.bitsPerComponent) bpp=\(image.bitsPerPixel) "
            + "info=\(image.bitmapInfo.rawValue) alpha=\(image.alphaInfo.rawValue) space=\(space)"
    }
}

// MARK: - Pixel access

/// RGBA bytes of a CGImage, in top-left coordinates.
struct ReelPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        let imageWidth = image.width
        let imageHeight = image.height
        width = imageWidth
        height = imageHeight
        var buffer = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: imageWidth, height: imageHeight, bitsPerComponent: 8,
                    bytesPerRow: imageWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        }
        bytes = buffer
    }

    func rgb(at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        let index = offset(of: point)
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    func alpha(at point: CGPoint) -> Int {
        Int(bytes[offset(of: point) + 3])
    }

    /// Manhattan distance between the two images' colours at one point.
    func distance(to other: Self, at point: CGPoint) -> Int {
        let mine = rgb(at: point)
        let theirs = other.rgb(at: point)
        return abs(mine.r - theirs.r) + abs(mine.g - theirs.g) + abs(mine.b - theirs.b)
    }

    /// Mean per-channel absolute difference over a rectangle (sampled every 2 px).
    func meanDifference(to other: Self, in rect: CGRect) -> Double {
        let samples = points(in: rect)
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + distance(to: other, at: $1) }
        return Double(total) / Double(samples.count * 3)
    }

    /// Mean of (r + g + b) / 3 over a rectangle (sampled every 2 px).
    func meanBrightness(in rect: CGRect) -> Double {
        let samples = points(in: rect)
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { sum, point in
            let colour = rgb(at: point)
            return sum + colour.r + colour.g + colour.b
        }
        return Double(total) / Double(samples.count * 3)
    }

    /// How many sampled pixels of a rectangle (every pixel) satisfy `predicate`.
    func count(in rect: CGRect, where predicate: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
        points(in: rect, step: 1).filter { predicate(rgb(at: $0)) }.count
    }

    /// Median of (r + g + b) / 3 over a rectangle (every pixel): the colour of a cell's background, whatever its
    /// digit, since a digit covers less than half of its cell.
    func medianBrightness(in rect: CGRect) -> Int {
        let levels = points(in: rect, step: 1).map(brightness(at:)).sorted()
        return levels.isEmpty ? 0 : levels[levels.count / 2]
    }

    /// How many pixels of a rectangle (every pixel) are ink in one frame and not in the other. Ink is the cell's
    /// minority colour: a pixel whose brightness is more than `contrast` away from the rectangle's median brightness
    /// in its own frame (a white digit on the dark panel, a black digit on the white celebration cell). Video
    /// drifting behind the translucent panel moves the background, not the ink, so only a changed glyph counts.
    func inkChanges(to other: Self, in rect: CGRect, contrast: Int = 90) -> Int {
        zip(inkMask(in: rect, contrast: contrast), other.inkMask(in: rect, contrast: contrast)).filter { $0 != $1 }
            .count
    }

    /// How many pixels of a rectangle (every pixel) are ink, as `inkChanges` classifies them.
    func inkCount(in rect: CGRect, contrast: Int = 90) -> Int {
        inkMask(in: rect, contrast: contrast).filter(\.self).count
    }

    /// Gold of the games box and the serve marker, allowing for re-encoding.
    static func isGold(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
        colour.r > 180 && colour.g > 130 && colour.b < 120
    }

    private func brightness(at point: CGPoint) -> Int {
        let colour = rgb(at: point)
        return (colour.r + colour.g + colour.b) / 3
    }

    /// Row by row, every pixel of `rect`: whether it stands out from the rectangle's median brightness.
    private func inkMask(in rect: CGRect, contrast: Int) -> [Bool] {
        let levels = points(in: rect, step: 1).map(brightness(at:))
        guard !levels.isEmpty else { return [] }
        let median = levels.sorted()[levels.count / 2]
        return levels.map { abs($0 - median) > contrast }
    }

    private func offset(of point: CGPoint) -> Int {
        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(point.y), 0), height - 1)
        return (y * width + x) * 4
    }

    private func points(in rect: CGRect, step: Int = 2) -> [CGPoint] {
        stride(from: Int(rect.minY), to: Int(rect.maxY), by: step).flatMap { y in
            stride(from: Int(rect.minX), to: Int(rect.maxX), by: step).map { x in CGPoint(x: x, y: y) }
        }
    }
}
