//
//  VideoStoreTests.swift
//  scoreTests
//
//  Where match videos live and how stored references resolve, including legacy absolute URLs.
//  Uses the host app's real Application Support/Videos directory; every test uses fresh match ids
//  and removes the files it creates.
//

import Foundation
import Testing

@testable import score

@Suite("VideoStore")
struct VideoStoreTests {
    private static func touch(_ url: URL) throws {
        try Data("video".utf8).write(to: url)
    }

    @Test("File names are per match and kind, inside the store directory")
    func fileNames() {
        let id = UUID()
        #expect(VideoStore.fileName(matchId: id, kind: .full) == "\(id.uuidString)_full.mov")
        #expect(VideoStore.fileName(matchId: id, kind: .highlights) == "\(id.uuidString)_highlights.mov")
        #expect(VideoStore.fileName(matchId: id, kind: .mock) == "\(id.uuidString)_mock.mov")
        #expect(VideoStore.fileName(matchId: id, kind: .rawSegment(index: 2)) == "\(id.uuidString)_seg2.mov")
        let url = VideoStore.fileURL(matchId: id, kind: .full)
        #expect(url.lastPathComponent == VideoStore.fileName(matchId: id, kind: .full))
        #expect(
            url.deletingLastPathComponent().standardizedFileURL.path == VideoStore.directory.standardizedFileURL.path)
    }

    @Test("A file in the store is referenced by its bare name, which resolves back to it")
    func storeReferenceRoundTrip() {
        let url = VideoStore.fileURL(matchId: UUID(), kind: .highlights)
        let reference = VideoStore.storedReference(for: url)
        #expect(reference == url.lastPathComponent)
        #expect(VideoStore.resolve(reference)?.standardizedFileURL.path == url.standardizedFileURL.path)
    }

    @Test("A file outside the store keeps its absolute URL; legacy URLs and paths resolve back to it")
    func legacyReferenceRoundTrip() {
        let url = URL.temporaryDirectory.appending(path: "full_\(UUID().uuidString).mov")
        let reference = VideoStore.storedReference(for: url)
        #expect(reference == url.absoluteString)
        #expect(VideoStore.resolve(reference)?.path == url.path)
        #expect(VideoStore.resolve(url.path)?.path == url.path)  // legacy absolute path
    }

    @Test("Missing and empty references resolve to nothing", arguments: [nil, ""] as [String?])
    func emptyReferences(reference: String?) {
        #expect(VideoStore.resolve(reference) == nil)
        #expect(!VideoStore.exists(reference))
        VideoStore.remove(reference)  // a no-op, not a crash
    }

    @Test("exists and remove follow store names and legacy URLs to the file")
    func existsAndRemove() throws {
        let stored = VideoStore.fileURL(matchId: UUID(), kind: .full)
        let legacy = URL.temporaryDirectory.appending(path: "highlight_\(UUID().uuidString).mov")
        for url in [stored, legacy] {
            let reference = VideoStore.storedReference(for: url)
            #expect(!VideoStore.exists(reference))
            try Self.touch(url)
            #expect(VideoStore.exists(reference))
            VideoStore.remove(reference)
            #expect(!VideoStore.exists(reference) && !FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("removeAll deletes every file of one match and leaves other matches' files alone")
    func removeAllForMatch() throws {
        let matchId = UUID()
        let otherId = UUID()
        defer { VideoStore.removeAll(matchId: otherId) }
        let kinds: [VideoStore.Kind] = [.rawSegment(index: 0), .rawSegment(index: 1), .full, .highlights, .mock]
        let matchFiles = kinds.map { VideoStore.fileURL(matchId: matchId, kind: $0) }
        let otherFile = VideoStore.fileURL(matchId: otherId, kind: .full)
        for url in matchFiles + [otherFile] {
            try Self.touch(url)
        }

        VideoStore.removeAll(matchId: matchId)

        #expect(matchFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
    }
}
