//
//  RecordingTimeline.swift
//  score
//
//  Maps the wall-clock offsets that events store (seconds since the match's
//  recordingStartTime) onto the video that was actually captured. A match is recorded as
//  one or more segments: a new one starts whenever capture resumes after an interruption
//  (screen lock, phone call, app relaunch), so gaps between segments contain no footage.
//

import Foundation

/// One recorded movie file and where it sits on the match's wall clock.
nonisolated struct RecordingSegment: Codable, Sendable, Equatable {
    /// Stored reference understood by `VideoStore.resolve`.
    let fileReference: String
    /// Wall-clock offset (seconds since recordingStartTime) at which this file began capturing.
    let startOffset: Double
    /// Length of the file in seconds, once known (nil until the asset has been inspected).
    var duration: Double?

    init(fileReference: String, startOffset: Double, duration: Double? = nil) {
        self.fileReference = fileReference
        self.startOffset = startOffset
        self.duration = duration
    }
}

/// Converts wall-clock offsets into positions in the concatenated video of all segments.
nonisolated struct RecordingTimeline: Sendable {
    /// Segments in capture order, each with a known duration.
    let segments: [RecordingSegment]

    init(segments: [RecordingSegment]) {
        self.segments = segments.filter { ($0.duration ?? 0) > 0 }.sorted { $0.startOffset < $1.startOffset }
    }

    var totalDuration: Double {
        segments.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// Position in the concatenated video for a wall-clock offset. Offsets that fall in a gap
    /// (or before the first segment) clamp to the end of the preceding footage; offsets after
    /// the last segment clamp to the end.
    func videoTime(forWallOffset offset: Double) -> Double {
        var elapsed = 0.0
        for segment in segments {
            let duration = segment.duration ?? 0
            if offset < segment.startOffset {
                return elapsed
            }
            if offset <= segment.startOffset + duration {
                return elapsed + (offset - segment.startOffset)
            }
            elapsed += duration
        }
        return elapsed
    }

    /// Video range for a wall-clock range, or nil when no footage covers it (gap, or too short).
    func videoRange(wallStart: Double, wallEnd: Double, minimumDuration: Double = 0.1) -> ClosedRange<Double>? {
        let start = videoTime(forWallOffset: wallStart)
        let end = videoTime(forWallOffset: wallEnd)
        guard end - start >= minimumDuration else { return nil }
        return start...end
    }
}
