//
//  WatchStatusTests.swift
//  scoreTests
//
//  WatchStatus: how the home screen describes the paired Apple Watch.
//

import Testing

@testable import score

@Suite("WatchStatus")
struct WatchStatusTests {
    @Test("An iPhone without a paired watch gets no watch card")
    func notPaired() {
        #expect(WatchStatus(isPaired: false, isInstalled: false, isReachable: false) == .notPaired)
        // Stale flags from a previous pairing never outrank the pairing state
        #expect(WatchStatus(isPaired: false, isInstalled: true, isReachable: true) == .notPaired)
    }

    @Test("A paired watch is described by whether the app is installed and currently open")
    func paired() {
        #expect(WatchStatus(isPaired: true, isInstalled: false, isReachable: false) == .notInstalled)
        #expect(WatchStatus(isPaired: true, isInstalled: true, isReachable: false) == .installed)
        #expect(WatchStatus(isPaired: true, isInstalled: true, isReachable: true) == .connected)
    }
}
