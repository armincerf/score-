//
//  ScoreboardOverlaySource.swift
//  score
//
//  The scoreboard bitmaps an export draws, rendered when the export reaches them rather than all up front: a full
//  match has hundreds of board states (two per point), and at 4K one board is 1.6 MB. Cues are looked up by time
//  (binary search); rendered boards sit in a small least-recently-used cache, and serving a cached board starts
//  rendering the next cue's board (one prefetch at a time), so the export rarely waits for the main actor, where
//  SwiftUI's ImageRenderer has to run.
//

import CoreGraphics
import CoreImage
import CoreMedia
import Synchronization
import os

nonisolated final class ScoreboardOverlaySource: Sendable {
    /// Renders one board state at the layout's size (the app: `ReelScoreboardRenderer` on the main actor).
    typealias Renderer = @Sendable (ReelScoreboardState, ReelScoreboardLayout) async -> CGImage?

    /// The most boards kept rendered at once (2.8 MB at 720p, 26 MB at 4K).
    static let cacheCapacity = 16

    /// Sorted by start time, not overlapping.
    let cues: [ReelScoreboardCue]
    let layout: ReelScoreboardLayout
    private let renderer: Renderer
    private let cache = Mutex(Cache())

    /// The board as the app draws it: SwiftUI rasterised on the main actor.
    static let mainActorRenderer: Renderer = { state, layout in
        await MainActor.run { ReelScoreboardRenderer.render(state, layout: layout) }
    }

    /// `cues` in any order (they are sorted by start), drawn on a `videoSize` frame.
    init(cues: [ReelScoreboardCue], videoSize: CGSize, renderer: @escaping Renderer = mainActorRenderer) {
        self.cues = cues.sorted { $0.timeRange.start < $1.timeRange.start }
        layout = ReelScoreboardLayout(videoSize: videoSize)
        self.renderer = renderer
    }

    /// What `board(at:)` would return, without waiting: `.ready` when the board is rendered (or there is none to
    /// draw), `.pending` when it still has to be rendered.
    enum Lookup: Sendable {
        case ready(CIImage?)
        case pending
    }

    // MARK: - Lookup

    /// Index of the cue shown at `time`, if any.
    func cueIndex(at time: CMTime) -> Int? {
        var low = 0
        var high = cues.count
        while low < high {  // the first cue starting after `time`
            let middle = (low + high) / 2
            if cues[middle].timeRange.start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, cues[low - 1].timeRange.containsTime(time) else { return nil }
        return low - 1
    }

    /// The board for `time`, placed in frame coordinates (Core Image: origin at the bottom-left), if it is ready.
    /// Serving a rendered board prefetches the next cue's.
    func boardIfReady(at time: CMTime) -> Lookup {
        guard let index = cueIndex(at: time) else { return .ready(nil) }
        let state = cues[index].state
        let found: Lookup = cache.withLock { cache in
            if cache.failed.contains(state) { return .ready(nil) }
            return cache.touch(state).map { .ready($0) } ?? .pending
        }
        if case .ready(.some) = found { prefetch(after: index) }
        return found
    }

    /// The board for `time` (nil when no cue covers it or its state failed to render), rendering it if needed.
    func board(at time: CMTime) async -> CIImage? {
        if case .ready(let board) = boardIfReady(at: time) { return board }
        guard let index = cueIndex(at: time) else { return nil }
        return await rendering(cues[index].state, prefetch: false).value
    }

    // MARK: - Test seams

    /// How many boards have been rendered so far.
    var renderCount: Int { cache.withLock { $0.renders } }
    /// How many boards are cached now.
    var cachedCount: Int { cache.withLock { $0.boards.count } }

    /// Waits for every render in flight (prefetches included).
    func waitForRenders() async {
        for task in cache.withLock({ Array($0.inFlight.values) }) {
            _ = await task.value
        }
    }

    // MARK: - Rendering

    /// Starts rendering the first later cue whose state is neither cached nor being rendered, unless a prefetch is
    /// already running.
    private func prefetch(after index: Int) {
        let current = cues[index].state
        guard let next = cues[(index + 1)...].first(where: { $0.state != current })?.state else { return }
        cache.withLock { cache in
            guard !cache.prefetching, cache.boards[next] == nil, cache.inFlight[next] == nil,
                !cache.failed.contains(next)
            else { return }
            cache.prefetching = true
            cache.inFlight[next] = Task { await self.render(next, prefetch: true) }
        }
    }

    /// The render of `state` in flight, started if there is none (two frames of one cue share a render).
    private func rendering(_ state: ReelScoreboardState, prefetch: Bool) -> Task<CIImage?, Never> {
        cache.withLock { cache in
            if let task = cache.inFlight[state] { return task }
            let task = Task { await self.render(state, prefetch: prefetch) }
            cache.inFlight[state] = task
            return task
        }
    }

    private func render(_ state: ReelScoreboardState, prefetch: Bool) async -> CIImage? {
        let image = await renderer(state, layout)
        let origin = layout.origin
        let board = image.map {
            CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        }
        cache.withLock { cache in
            cache.renders += 1
            cache.inFlight[state] = nil
            if prefetch { cache.prefetching = false }
            if let board {
                cache.insert(board, for: state)
            } else {
                cache.failed.insert(state)
            }
        }
        if board == nil { Log.video.error("Scoreboard: a board state failed to render; frames go without it") }
        return board
    }

    /// Rendered boards, least recently used first, and the renders in flight.
    private struct Cache {
        var boards: [ReelScoreboardState: CIImage] = [:]
        var order: [ReelScoreboardState] = []
        var inFlight: [ReelScoreboardState: Task<CIImage?, Never>] = [:]
        var failed: Set<ReelScoreboardState> = []
        var prefetching = false
        var renders = 0

        /// The cached board for `state`, marked as just used.
        mutating func touch(_ state: ReelScoreboardState) -> CIImage? {
            guard let board = boards[state] else { return nil }
            if order.last != state, let position = order.firstIndex(of: state) {
                order.remove(at: position)
                order.append(state)
            }
            return board
        }

        mutating func insert(_ board: CIImage, for state: ReelScoreboardState) {
            if boards.updateValue(board, forKey: state) == nil { order.append(state) }
            while order.count > ScoreboardOverlaySource.cacheCapacity {
                boards[order.removeFirst()] = nil
            }
        }
    }
}
