//
//  CameraPreviewTests.swift
//  scoreTests
//
//  The settings preview's fallback rotation (used before a camera is configured, when there is no
//  RotationCoordinator). The back camera's sensor is landscape-right native, so landscape-right
//  needs no rotation and portrait needs 90 degrees. Nothing here touches a capture session.
//

import CoreGraphics
import Testing
import UIKit

@testable import score

@Suite("CameraPreview")
struct CameraPreviewTests {
    @Test(
        "Fallback preview angle follows the interface orientation",
        arguments: [
            (UIInterfaceOrientation.portrait, 90),
            (.landscapeRight, 0),
            (.landscapeLeft, 180),
            (.portraitUpsideDown, 270),
            (.unknown, 90),
        ] as [(UIInterfaceOrientation, CGFloat)]
    )
    func fallbackPreviewAngle(orientation: UIInterfaceOrientation, expected: CGFloat) {
        #expect(CameraPreviewUIView.fallbackPreviewAngle(for: orientation) == expected)
    }
}
