//
//  RecordingTimelineTests.swift
//  scoreTests
//
//  Wall-clock -> video-time mapping across recording segments and gaps.
//

import Testing

@testable import score

@Suite("RecordingTimeline")
struct RecordingTimelineTests {
    // Camera started 2 s after the match clock, ran 60 s, then (after a 30 s gap: locked phone)
    // a second segment ran 40 s starting at wall 92.
    private let timeline = RecordingTimeline(segments: [
        RecordingSegment(fileReference: "a.mov", startOffset: 2, duration: 60),
        RecordingSegment(fileReference: "b.mov", startOffset: 92, duration: 40),
    ])

    @Test(
        "Offsets inside a segment map to that segment's position in the concatenation",
        arguments: [
            (2.0, 0.0), (12.0, 10.0), (62.0, 60.0), (92.0, 60.0), (102.0, 70.0), (132.0, 100.0),
        ])
    func insideSegments(wall: Double, video: Double) {
        #expect(timeline.videoTime(forWallOffset: wall) == video)
    }

    @Test("Offsets before the first segment, in a gap, or after the end clamp to the surrounding footage")
    func clamping() {
        #expect(timeline.videoTime(forWallOffset: 0) == 0)  // camera not running yet
        #expect(timeline.videoTime(forWallOffset: 75) == 60)  // phone was locked
        #expect(timeline.videoTime(forWallOffset: 500) == 100)  // after the last segment
        #expect(timeline.totalDuration == 100)
    }

    @Test("Clip ranges that fall entirely in a gap are dropped; ones spanning a gap keep the footage")
    func ranges() {
        #expect(timeline.videoRange(wallStart: 65, wallEnd: 80) == nil)
        #expect(timeline.videoRange(wallStart: 50, wallEnd: 100) == 48...68)
        #expect(timeline.videoRange(wallStart: 10, wallEnd: 10.05) == nil)
    }

    @Test("Segments without a duration are ignored and order follows the wall clock")
    func filtering() {
        let unordered = RecordingTimeline(segments: [
            RecordingSegment(fileReference: "late.mov", startOffset: 100, duration: 10),
            RecordingSegment(fileReference: "broken.mov", startOffset: 50, duration: nil),
            RecordingSegment(fileReference: "early.mov", startOffset: 0, duration: 20),
        ])
        #expect(unordered.segments.map(\.fileReference) == ["early.mov", "late.mov"])
        #expect(unordered.videoTime(forWallOffset: 105) == 25)
    }

    @Test("An empty timeline maps everything to zero")
    func empty() {
        let none = RecordingTimeline(segments: [])
        #expect(none.videoTime(forWallOffset: 42) == 0 && none.totalDuration == 0)
        #expect(none.videoRange(wallStart: 0, wallEnd: 10) == nil)
    }

    // MARK: - Video ranges back onto the segments' files

    @Test("A range inside one segment is one stretch of that segment's file")
    func rangeInsideASegment() {
        #expect(
            timeline.segmentRanges(videoStart: 70, videoEnd: 75)
                == [SegmentRange(segmentIndex: 1, start: 10, end: 15)])
        #expect(
            timeline.segmentRanges(videoStart: 5, videoEnd: 9) == [SegmentRange(segmentIndex: 0, start: 5, end: 9)])
    }

    @Test("A range across a segment boundary is two stretches, in order")
    func rangeAcrossABoundary() {
        // Video 58-63: the last 2 s of a.mov, then the first 3 s of b.mov
        let ranges = timeline.segmentRanges(videoStart: 58, videoEnd: 63)
        #expect(
            ranges == [
                SegmentRange(segmentIndex: 0, start: 58, end: 60), SegmentRange(segmentIndex: 1, start: 0, end: 3),
            ])
        #expect(ranges.map(\.duration).reduce(0, +) == 5)
    }

    @Test("A range ending on a boundary has no sliver of the next segment; an empty range has no stretch")
    func boundariesAndEmpty() {
        #expect(
            timeline.segmentRanges(videoStart: 55, videoEnd: 60)
                == [SegmentRange(segmentIndex: 0, start: 55, end: 60)])
        #expect(timeline.segmentRanges(videoStart: 30, videoEnd: 30).isEmpty)
        #expect(timeline.segmentRanges(videoStart: 100, videoEnd: 120).isEmpty, "past the footage")
    }

    @Test("A wall-clock highlight maps to video time and back onto the files it was recorded in")
    func highlightAcrossSegments() throws {
        // Wall 60-95: a.mov from 58 s to its end, the 30 s gap (no footage), then b.mov's first 3 s
        let video = try #require(timeline.videoRange(wallStart: 60, wallEnd: 95))
        let ranges = timeline.segmentRanges(videoStart: video.lowerBound, videoEnd: video.upperBound)
        #expect(ranges.map(\.segmentIndex) == [0, 1])
        #expect(ranges.first?.start == 58 && ranges.last?.end == 3)
    }
}
