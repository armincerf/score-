//
//  ExportRetryPolicyTests.swift
//  scoreTests
//
//  When an export with the scoreboard fails, the manager tries once more without it, but only for a failure the
//  board may have caused (a full disk or an interruption would fail the plain export again, after the same wait),
//  and the retry's progress continues from where the bar got to instead of starting again at 0.
//

import AVFoundation
import Foundation
import Testing

@testable import score

@Suite("ExportRetryPolicy")
struct ExportRetryPolicyTests {
    @Test(
        "Lasting failures are not retried without the board",
        arguments: [
            CancellationError() as any Error,
            AVError(.diskFull),
            AVError(.operationInterrupted),
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            NSError(
                domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]),
        ])
    func lastingFailures(error: any Error) {
        #expect(!MediaExportService.boardMayHaveCaused(error), "\(error)")
    }

    @Test(
        "Other failures may come from the board and are retried without it",
        arguments: [
            AVError(.unknown) as any Error,
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.operationNotSupportedForAsset.rawValue),
            MediaExportService.ExportError.failedToCreateExportSession,
        ])
    func boardFailures(error: any Error) {
        #expect(MediaExportService.boardMayHaveCaused(error), "\(error)")
    }

    @Test("A retry's progress fills what is left of the bar")
    func retryProgressNeverGoesBack() {
        #expect(MediaExportService.retryProgress(0, after: 0.6) == 0.6)
        #expect(abs(MediaExportService.retryProgress(0.5, after: 0.6) - 0.8) < 1e-9)
        #expect(MediaExportService.retryProgress(1, after: 0.6) == 1)
        #expect(MediaExportService.retryProgress(0.3, after: 0) == 0.3, "a failure at the start: plain progress")
        #expect(MediaExportService.retryProgress(1.2, after: 1.5) == 1, "kept within 0...1")
    }
}
