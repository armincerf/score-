//
//  VideoOrientationDetector.swift
//  score
//
//  Decides from the pictures whether a recorded segment needs rotating: samples a few frames around the middle,
//  runs Vision's human body pose model with each candidate orientation and scores how many people stand upright
//  (neck above hips) in each. `OrientationDecision` turns the scores into a correction, keeping the metadata
//  orientation unless the evidence is clear. The scores are logged so problems with real footage can be read
//  from the device logs.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Vision
import os

nonisolated enum VideoOrientationDetector {
    typealias Detection = (correction: VideoRotationCorrection, scores: [VideoRotationCorrection: Double])

    /// Frames are scaled to fit this box before detection (about 640 px on the long side).
    static let maximumFrameSize = CGSize(width: 640, height: 640)

    /// The correction each URL needs, in order, detected one after another (each runs several Vision requests).
    @concurrent
    static func corrections(for urls: [URL]) async -> [VideoRotationCorrection] {
        var corrections: [VideoRotationCorrection] = []
        for url in urls {
            corrections.append(await correction(for: url).correction)
        }
        return corrections
    }

    /// The correction `url`'s frames need to show people upright, with the per-orientation evidence. Any error
    /// gives `.none` (the metadata orientation) and empty scores.
    @concurrent
    static func correction(for url: URL) async -> Detection {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let scores = try await scores(for: url)
            let decision = OrientationDecision.decide(scores: scores)
            let elapsed = (clock.now - start).inSeconds
            Log.video.info(
                "Orientation \(url.lastPathComponent, privacy: .public): \(describe(scores), privacy: .public) -> \(decision.rawValue, privacy: .public) (\(String(format: "%.2f", elapsed), privacy: .public)s)"
            )
            return (decision, scores)
        } catch {
            Log.video.warning(
                "Orientation detection failed for \(url.lastPathComponent, privacy: .public), keeping the metadata orientation: \(error.localizedDescription, privacy: .public)"
            )
            return (.none, [:])
        }
    }

    /// Body-pose evidence per orientation, summed over the sampled frames.
    private static func scores(for url: URL) async throws -> [VideoRotationCorrection: Double] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let times = sampleTimes(duration: duration)
        guard !times.isEmpty else { throw DetectionError.noFrames }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true  // evidence is relative to the metadata orientation
        generator.maximumSize = maximumFrameSize

        let request = DetectHumanBodyPoseRequest()
        var scores = Dictionary(uniqueKeysWithValues: VideoRotationCorrection.allCases.map { ($0, 0.0) })
        for time in times {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            for correction in VideoRotationCorrection.allCases {
                let people = try await request.perform(on: frame, orientation: correction.imageOrientation)
                // Vision's coordinates are normalized to the oriented picture, whose sides swap on a quarter turn
                let oriented = correction.rotatedSize(CGSize(width: frame.width, height: frame.height))
                let aspectRatio = Double(oriented.width / max(oriented.height, 1))
                scores[correction, default: 0] += people.reduce(0) {
                    $0 + BodyPoseEvidence(observation: $1).score(aspectRatio: aspectRatio)
                }
            }
        }
        return scores
    }

    /// Where to sample a clip of `duration` seconds: 30, 40, 50, 60 and 70 % of the way through; three samples
    /// under 5 s, the middle frame under 2 s, none for an empty clip.
    static func sampleTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let fractions: [Double]
        if duration >= 5 {
            fractions = [0.3, 0.4, 0.5, 0.6, 0.7]
        } else if duration >= 2 {
            fractions = [0.3, 0.5, 0.7]
        } else {
            fractions = [0.5]
        }
        return fractions.map { $0 * duration }
    }

    /// "none=0.00 clockwise90=3.10 ..." in `VideoRotationCorrection.allCases` order.
    static func describe(_ scores: [VideoRotationCorrection: Double]) -> String {
        VideoRotationCorrection.allCases
            .map { "\($0.rawValue)=\(String(format: "%.2f", scores[$0] ?? 0))" }
            .joined(separator: " ")
    }

    nonisolated enum DetectionError: Error, LocalizedError {
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noFrames: return "The video has no frames to sample"
            }
        }
    }
}

/// The joints that say whether one detected person stands upright, in Vision's normalized coordinates of the
/// oriented picture (origin bottom-left, so a larger `y` is higher up).
nonisolated struct BodyPoseEvidence: Sendable, Equatable {
    nonisolated struct Joint: Sendable, Equatable {
        let x: Double
        let y: Double
        let confidence: Double

        init(x: Double = 0.5, y: Double, confidence: Double) {
            self.x = x
            self.y = y
            self.confidence = confidence
        }
    }

    /// Joints below this confidence are ignored.
    static let minimumConfidence = 0.3

    var neck: Joint?
    var nose: Joint?
    var root: Joint?
    var leftHip: Joint?
    var rightHip: Joint?

    init(neck: Joint? = nil, nose: Joint? = nil, root: Joint? = nil, leftHip: Joint? = nil, rightHip: Joint? = nil) {
        self.neck = neck
        self.nose = nose
        self.root = root
        self.leftHip = leftHip
        self.rightHip = rightHip
    }

    init(observation: HumanBodyPoseObservation) {
        func joint(_ name: HumanBodyPoseObservation.JointName) -> Joint? {
            observation.joint(for: name).map {
                Joint(x: Double($0.location.x), y: Double($0.location.y), confidence: Double($0.confidence))
            }
        }
        self.init(
            neck: joint(.neck), nose: joint(.nose), root: joint(.root), leftHip: joint(.leftHip),
            rightHip: joint(.rightHip))
    }

    /// How surely this person stands upright in a picture `aspectRatio` (width / height) wide: the mean confidence
    /// of the upper (neck, else nose) and lower (root, else the surer hip) joints, weighted by how upright the
    /// torso between them is (the cosine of its tilt from vertical, measured in pixels). 0 when either joint is
    /// missing or unsure, or the upper one is not above the lower one.
    ///
    /// The weighting matters: Vision also finds a leaning player in the picture turned a quarter, where the neck is
    /// still slightly "above" the root; counted in full, that runner-up came within 1.3x of the right orientation
    /// on a public-domain photo of a player reaching for the ball (see docs/plans/highlight-reel.md).
    func score(aspectRatio: Double) -> Double {
        guard let upper = Self.usable(neck) ?? Self.usable(nose),
            let lower = Self.usable(root)
                ?? [leftHip, rightHip].compactMap(Self.usable).max(by: {
                    $0.confidence < $1.confidence
                })
        else { return 0 }
        let rise = upper.y - lower.y
        let run = (upper.x - lower.x) * aspectRatio  // in units of the picture's height, like `rise`
        let length = (rise * rise + run * run).squareRoot()
        guard rise > 0, length > 0 else { return 0 }
        return (rise / length) * (upper.confidence + lower.confidence) / 2
    }

    private static func usable(_ joint: Joint?) -> Joint? {
        guard let joint, joint.confidence >= minimumConfidence else { return nil }
        return joint
    }
}

extension Duration {
    /// The duration in seconds, as a Double.
    nonisolated fileprivate var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
