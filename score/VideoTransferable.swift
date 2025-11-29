//
//  VideoTransferable.swift
//  score
//
//  Transferable implementation for video sharing via ShareLink
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct VideoTransferable: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            contentType: .movie,
            exporting: { video in
                SentTransferredFile(video.url)
            },
            importing: { received in
                let copy = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mov")
                try FileManager.default.copyItem(at: received.file, to: copy)
                return Self(url: copy, name: "Imported Video")
            }
        )

        // Also provide fallback for apps that accept MPEG4
        FileRepresentation(
            contentType: .mpeg4Movie,
            exporting: { video in
                SentTransferredFile(video.url)
            },
            importing: { received in
                let copy = URL.temporaryDirectory.appending(component: "\(UUID().uuidString).mp4")
                try FileManager.default.copyItem(at: received.file, to: copy)
                return Self(url: copy, name: "Imported Video")
            }
        )
    }
}
