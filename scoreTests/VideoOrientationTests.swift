//
//  VideoOrientationTests.swift
//  scoreTests
//
//  Pure logic of the orientation fix: the correction enum and its transform, the decision rule, the body-pose
//  evidence score, where frames are sampled, and how `MediaExportService.uprightGeometry` folds a correction into
//  the capture metadata. The Vision and AVFoundation ends are covered in VideoOrientationIntegrationTests.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import score

@Suite("VideoOrientation")
struct VideoOrientationTests {
    typealias Correction = VideoRotationCorrection

    // MARK: - VideoRotationCorrection

    @Test(
        "Each correction's degrees, dimension swap, inverse and EXIF orientation",
        arguments: [
            (Correction.none, 0, false, Correction.none, CGImagePropertyOrientation.up),
            (.clockwise90, 90, true, .counterclockwise270, .right),
            (.upsideDown180, 180, false, .upsideDown180, .down),
            (.counterclockwise270, 270, true, .clockwise90, .left),
        ])
    func correctionProperties(
        correction: Correction, degrees: Int, swaps: Bool, inverse: Correction,
        orientation: CGImagePropertyOrientation
    ) {
        #expect(correction.degrees == degrees)
        #expect(correction.swapsDimensions == swaps)
        #expect(correction.inverse == inverse)
        #expect(correction.imageOrientation == orientation)
        #expect(
            correction.rotatedSize(CGSize(width: 16, height: 9))
                == (swaps ? CGSize(width: 9, height: 16) : CGSize(width: 16, height: 9)))
    }

    /// Where the source's top-left pixel corner lands, as a fraction of the corrected frame (top-left origin).
    @Test(
        "The transform turns the frame clockwise by `degrees` about its centre and keeps it at the origin",
        arguments: [
            (Correction.none, CGPoint.zero),
            (.clockwise90, CGPoint(x: 1, y: 0)),  // clockwise: top-left -> top-right
            (.upsideDown180, CGPoint(x: 1, y: 1)),  // half turn: top-left -> bottom-right
            (.counterclockwise270, CGPoint(x: 0, y: 1)),  // anticlockwise: top-left -> bottom-left
        ])
    func transformTurnsAboutTheCentre(correction: Correction, topLeftLandsAt fraction: CGPoint) {
        let size = CGSize(width: 1280, height: 720)
        let transform = correction.transform(for: size)
        let output = correction.rotatedSize(size)

        let frame = CGRect(origin: .zero, size: size).applying(transform)
        #expect(abs(frame.minX) < 0.001 && abs(frame.minY) < 0.001)
        #expect(abs(frame.width - output.width) < 0.001 && abs(frame.height - output.height) < 0.001)

        let corner = CGPoint.zero.applying(transform)
        #expect(abs(corner.x - fraction.x * output.width) < 0.001 && abs(corner.y - fraction.y * output.height) < 0.001)
        // The centre stays the centre
        let centre = CGPoint(x: size.width / 2, y: size.height / 2).applying(transform)
        #expect(abs(centre.x - output.width / 2) < 0.001 && abs(centre.y - output.height / 2) < 0.001)
    }

    @Test("A clockwise quarter turn moves the frame's top edge to the right edge", arguments: [Correction.clockwise90])
    func clockwiseMovesTopToRight(correction: Correction) {
        let size = CGSize(width: 1280, height: 720)
        let transform = correction.transform(for: size)
        let topMiddle = CGPoint(x: 640, y: 0).applying(transform)
        #expect(abs(topMiddle.x - 720) < 0.001 && abs(topMiddle.y - 640) < 0.001)
    }

    @Test("A correction followed by its inverse is the identity", arguments: Correction.allCases)
    func inverseUndoes(correction: Correction) {
        let size = CGSize(width: 640, height: 360)
        let there = correction.transform(for: size)
        let back = correction.inverse.transform(for: correction.rotatedSize(size))
        let roundTrip = there.concatenating(back)
        for point in [CGPoint.zero, CGPoint(x: 640, y: 0), CGPoint(x: 13, y: 297), CGPoint(x: 640, y: 360)] {
            let mapped = point.applying(roundTrip)
            #expect(abs(mapped.x - point.x) < 0.001 && abs(mapped.y - point.y) < 0.001, "\(point) -> \(mapped)")
        }
    }

    // MARK: - OrientationDecision

    @Test("A clear winner above the minimum is chosen")
    func clearWinner() {
        let scores: [Correction: Double] = [
            .none: 0.4, .clockwise90: 4.2, .upsideDown180: 0, .counterclockwise270: 0.9,
        ]
        #expect(OrientationDecision.decide(scores: scores) == .clockwise90)
        #expect(OrientationDecision.decide(scores: [.upsideDown180: 3]) == .upsideDown180)
    }

    @Test("Strong evidence for the metadata orientation keeps it")
    func metadataWins() {
        #expect(OrientationDecision.decide(scores: [.none: 6, .clockwise90: 1, .upsideDown180: 0]) == .none)
    }

    @Test(
        "Weak, ambiguous, tied, empty or non-finite evidence keeps the metadata orientation",
        arguments: [
            [Correction: Double](),
            [.none: 0, .clockwise90: 0, .upsideDown180: 0, .counterclockwise270: 0],
            [.upsideDown180: 0.99],  // below the minimum score
            [.upsideDown180: 3, .none: 2.1],  // 3 < 1.5 x 2.1
            [.clockwise90: 2, .counterclockwise270: 2],  // tie
            [.clockwise90: .infinity, .none: 1],
            [.clockwise90: .nan],
        ])
    func weakEvidenceKeepsMetadata(scores: [Correction: Double]) {
        #expect(OrientationDecision.decide(scores: scores) == .none)
    }

    @Test("The margin is inclusive and both thresholds are configurable")
    func thresholds() {
        #expect(OrientationDecision.decide(scores: [.upsideDown180: 3, .none: 2]) == .upsideDown180)  // exactly 1.5x
        #expect(OrientationDecision.decide(scores: [.upsideDown180: 1]) == .upsideDown180)  // exactly the minimum
        #expect(OrientationDecision.decide(scores: [.upsideDown180: 3, .none: 2], margin: 2) == .none)
        #expect(OrientationDecision.decide(scores: [.upsideDown180: 0.5], minimumScore: 0.4) == .upsideDown180)
    }

    // MARK: - Body pose evidence

    private typealias Joint = BodyPoseEvidence.Joint

    private static let landscape = 16.0 / 9.0

    @Test("A person standing straight scores the mean confidence of neck and root")
    func uprightPersonScores() {
        let pose = BodyPoseEvidence(neck: Joint(y: 0.8, confidence: 0.9), root: Joint(y: 0.5, confidence: 0.7))
        #expect(abs(pose.score(aspectRatio: Self.landscape) - 0.8) < 1e-9)
    }

    @Test("A person upside down or lying exactly flat (neck not above root) scores nothing")
    func notUprightScoresZero() {
        let upsideDown = BodyPoseEvidence(neck: Joint(y: 0.3, confidence: 0.9), root: Joint(y: 0.6, confidence: 0.9))
        #expect(upsideDown.score(aspectRatio: Self.landscape) == 0)
        let flat = BodyPoseEvidence(
            neck: Joint(x: 0.3, y: 0.5, confidence: 0.9), root: Joint(x: 0.6, y: 0.5, confidence: 0.9))
        #expect(flat.score(aspectRatio: Self.landscape) == 0)
        let sameSpot = BodyPoseEvidence(neck: Joint(y: 0.5, confidence: 0.9), root: Joint(y: 0.5, confidence: 0.9))
        #expect(sameSpot.score(aspectRatio: Self.landscape) == 0)
    }

    @Test("A leaning torso counts by the cosine of its tilt from vertical, measured in pixels")
    func tiltWeighting() {
        // 45 degrees in a 16:9 picture: the horizontal run in normalized units is the rise x 9/16
        let leaning = BodyPoseEvidence(
            neck: Joint(x: 0.5, y: 0.8, confidence: 1), root: Joint(x: 0.5 + 0.3 * 9 / 16, y: 0.5, confidence: 1))
        #expect(abs(leaning.score(aspectRatio: Self.landscape) - 0.5.squareRoot()) < 1e-9)
        // The same normalized points in a 9:16 picture are a much steeper torso
        let steep = 0.3 / (0.09 + pow(0.3 * 9 / 16 * 9 / 16, 2)).squareRoot()
        #expect(abs(leaning.score(aspectRatio: 9.0 / 16.0) - steep) < 1e-9)
        // Nearly flat: almost nothing
        let nearlyFlat = BodyPoseEvidence(
            neck: Joint(x: 0.2, y: 0.51, confidence: 1), root: Joint(x: 0.5, y: 0.5, confidence: 1))
        #expect(nearlyFlat.score(aspectRatio: Self.landscape) < 0.02)
    }

    @Test("A player leaning 30 degrees scores clearly more upright than in the picture turned a quarter")
    func leaningPlayerBeatsQuarterTurn() {
        // Tilt 30 degrees from vertical upright; turned a quarter, the same torso is 60 degrees from vertical
        let rise = cos(Double.pi / 6) * 0.3
        let run = sin(Double.pi / 6) * 0.3
        let upright = BodyPoseEvidence(
            neck: Joint(x: 0.5 + run, y: 0.5 + rise, confidence: 0.8), root: Joint(x: 0.5, y: 0.5, confidence: 0.8))
        let turned = BodyPoseEvidence(
            neck: Joint(x: 0.5 + rise, y: 0.5 + run, confidence: 0.8), root: Joint(x: 0.5, y: 0.5, confidence: 0.8))
        let uprightScore = upright.score(aspectRatio: 1)
        let turnedScore = turned.score(aspectRatio: 1)
        #expect(abs(uprightScore - 0.8 * cos(Double.pi / 6)) < 1e-9)
        #expect(abs(turnedScore - 0.8 * 0.5) < 1e-9)
        #expect(
            OrientationDecision.decide(scores: [.none: uprightScore * 3, .clockwise90: turnedScore * 3]) == .none)
        #expect(
            OrientationDecision.decide(scores: [.none: turnedScore * 3, .clockwise90: uprightScore * 3])
                == .clockwise90)
    }

    @Test("Missing or unsure joints fall back to the nose and the surer hip")
    func fallbacks() {
        // Neck below the confidence floor: the nose stands in
        let nose = BodyPoseEvidence(
            neck: Joint(y: 0.9, confidence: 0.2), nose: Joint(y: 0.85, confidence: 0.6),
            root: Joint(y: 0.4, confidence: 0.8))
        #expect(abs(nose.score(aspectRatio: Self.landscape) - 0.7) < 1e-9)
        // No root: the hip with the higher confidence stands in (here the right one, which is lower down)
        let hips = BodyPoseEvidence(
            neck: Joint(y: 0.7, confidence: 0.8), leftHip: Joint(y: 0.75, confidence: 0.4),
            rightHip: Joint(y: 0.4, confidence: 0.6))
        #expect(abs(hips.score(aspectRatio: Self.landscape) - 0.7) < 1e-9)
        // Exactly at the floor counts
        let floor = BodyPoseEvidence(neck: Joint(y: 0.7, confidence: 0.3), root: Joint(y: 0.4, confidence: 0.3))
        #expect(abs(floor.score(aspectRatio: Self.landscape) - 0.3) < 1e-9)
    }

    @Test("Without an upper and a lower joint there is no evidence")
    func incompletePoses() {
        let poses = [
            BodyPoseEvidence(),
            BodyPoseEvidence(neck: Joint(y: 0.8, confidence: 0.9)),
            BodyPoseEvidence(root: Joint(y: 0.2, confidence: 0.9)),
            BodyPoseEvidence(neck: Joint(y: 0.8, confidence: 0.9), root: Joint(y: 0.2, confidence: 0.1)),
        ]
        for pose in poses {
            #expect(pose.score(aspectRatio: Self.landscape) == 0)
        }
    }

    // MARK: - Frame sampling

    @Test(
        "Frames are sampled at 30-70 % of the clip, fewer for short clips, none for an empty one",
        arguments: [
            (60.0, [18.0, 24, 30, 36, 42]),
            (5.0, [1.5, 2, 2.5, 3, 3.5]),
            (4.0, [1.2, 2, 2.8]),
            (2.0, [0.6, 1, 1.4]),
            (1.0, [0.5]),
            (0.2, [0.1]),
            (0.0, []),
            (-3.0, []),
            (Double.nan, []),
            (Double.infinity, []),
        ])
    func sampleTimes(duration: Double, expected: [Double]) {
        let times = VideoOrientationDetector.sampleTimes(duration: duration)
        #expect(times.count == expected.count)
        for (time, want) in zip(times, expected) {
            #expect(abs(time - want) < 1e-9, "\(times) != \(expected)")
        }
    }

    @Test("Scores are logged in a fixed order with two decimals")
    func describeScores() {
        let text = VideoOrientationDetector.describe([.clockwise90: 3.14159, .none: 0.5])
        #expect(text == "none=0.50 clockwise90=3.14 upsideDown180=0.00 counterclockwise270=0.00")
    }

    // MARK: - uprightGeometry with a correction

    /// What AVCaptureMovieFileOutput writes for a portrait recording on a 1280x720 sensor (videoRotationAngle 90).
    private static let portraitTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)

    /// Expected output size and where the source's top-left corner (as seen after the preferredTransform) lands,
    /// as a fraction of the output frame.
    @Test(
        "Landscape input: the correction turns the metadata-upright frame about its centre",
        arguments: [
            (Correction.none, CGSize(width: 1280, height: 720), CGPoint.zero),
            (.clockwise90, CGSize(width: 720, height: 1280), CGPoint(x: 1, y: 0)),
            (.upsideDown180, CGSize(width: 1280, height: 720), CGPoint(x: 1, y: 1)),
            (.counterclockwise270, CGSize(width: 720, height: 1280), CGPoint(x: 0, y: 1)),
        ])
    func geometryLandscape(correction: Correction, size: CGSize, topLeftLandsAt fraction: CGPoint) {
        let natural = CGSize(width: 1280, height: 720)
        let geometry = MediaExportService.uprightGeometry(
            naturalSize: natural, preferredTransform: .identity, correction: correction)
        #expect(geometry.size == size)
        let frame = CGRect(origin: .zero, size: natural).applying(geometry.transform)
        #expect(abs(frame.minX) < 0.001 && abs(frame.minY) < 0.001)
        #expect(abs(frame.width - size.width) < 0.001 && abs(frame.height - size.height) < 0.001)
        let corner = CGPoint.zero.applying(geometry.transform)
        #expect(abs(corner.x - fraction.x * size.width) < 0.001 && abs(corner.y - fraction.y * size.height) < 0.001)
    }

    @Test(
        "Portrait input (90° preferredTransform): the correction applies after the metadata rotation",
        arguments: [
            (Correction.none, CGSize(width: 720, height: 1280), CGPoint.zero),
            (.clockwise90, CGSize(width: 1280, height: 720), CGPoint(x: 1, y: 0)),
            (.upsideDown180, CGSize(width: 720, height: 1280), CGPoint(x: 1, y: 1)),
            (.counterclockwise270, CGSize(width: 1280, height: 720), CGPoint(x: 0, y: 1)),
        ])
    func geometryPortrait(correction: Correction, size: CGSize, topLeftLandsAt fraction: CGPoint) {
        let natural = CGSize(width: 1280, height: 720)
        let geometry = MediaExportService.uprightGeometry(
            naturalSize: natural, preferredTransform: Self.portraitTransform, correction: correction)
        #expect(geometry.size == size)
        let frame = CGRect(origin: .zero, size: natural).applying(geometry.transform)
        #expect(abs(frame.minX) < 0.001 && abs(frame.minY) < 0.001)
        #expect(abs(frame.width - size.width) < 0.001 && abs(frame.height - size.height) < 0.001)
        // The metadata rotation alone puts the sensor's bottom-left corner (0, 720) at the upright top-left;
        // the correction then moves that point like any other top-left corner
        let uprightTopLeft = CGPoint(x: 0, y: 720).applying(geometry.transform)
        #expect(
            abs(uprightTopLeft.x - fraction.x * size.width) < 0.001
                && abs(uprightTopLeft.y - fraction.y * size.height) < 0.001,
            "upright top-left landed at \(uprightTopLeft)")
    }

    @Test("Without a correction the geometry is what it was before corrections existed")
    func defaultCorrectionIsNone() {
        let natural = CGSize(width: 1280, height: 720)
        for transform in [CGAffineTransform.identity, Self.portraitTransform, CGAffineTransform(rotationAngle: .pi)] {
            let implicit = MediaExportService.uprightGeometry(naturalSize: natural, preferredTransform: transform)
            let explicit = MediaExportService.uprightGeometry(
                naturalSize: natural, preferredTransform: transform, correction: .none)
            #expect(implicit.size == explicit.size && implicit.transform == explicit.transform)
        }
    }
}
