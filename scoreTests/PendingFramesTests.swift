//
//  PendingFramesTests.swift
//  scoreTests
//
//  The bookkeeping behind FrameCompositor's frames that wait for their board: a cancel must finish every waiting
//  frame before it returns, and a frame must be finished exactly once whether its board or the cancel comes first.
//

import Testing

@testable import score

@Suite("PendingFrames")
struct PendingFramesTests {
    @Test("A parked frame comes out once, through its ticket")
    func takeOnce() {
        var frames = PendingFrames<String>()
        let first = frames.park("frame 1")
        let second = frames.park("frame 2")
        #expect(first != second)
        #expect(frames.take(first) == "frame 1")
        #expect(frames.take(first) == nil, "a frame taken out is not finished a second time")
        #expect(frames.count == 1)
        #expect(frames.take(second) == "frame 2")
        #expect(frames.isEmpty)
    }

    @Test("A cancel takes every waiting frame, in order, and the board that arrives later finds none")
    func cancelTakesEverything() {
        var frames = PendingFrames<String>()
        let tickets = (1...3).map { frames.park("frame \($0)") }
        #expect(frames.take(tickets[1]) == "frame 2", "its board was ready before the cancel")
        #expect(frames.takeAll() == ["frame 1", "frame 3"])
        #expect(frames.isEmpty)
        for ticket in tickets {
            #expect(frames.take(ticket) == nil, "cancelled frames are not finished again when their board arrives")
        }
        #expect(frames.takeAll().isEmpty)
        let later = frames.park("frame 4")
        #expect(!tickets.contains(later), "a ticket is never reused")
    }
}
