//
//  MatchVideosSection.swift
//  score
//
//  The match detail screen's video card: a Highlights / Full match picker, the inline player shaped like the
//  selected video, a Full Screen button and the share button; or why there is no video yet.
//

import AVKit
import SwiftUI

struct MatchVideosSection: View {
    let highlightCount: Int
    /// Height of the screen's scroll view (0 until measured): a short screen (landscape) caps the player's height.
    let viewportHeight: CGFloat
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var playback: MatchVideoPlayback
    @State private var fullScreenRequest = 0
    @State private var availableWidth: CGFloat = 0

    init(highlightVideo: URL?, fullVideo: URL?, highlightCount: Int, viewportHeight: CGFloat) {
        self.highlightCount = highlightCount
        self.viewportHeight = viewportHeight
        _playback = State(initialValue: MatchVideoPlayback(highlights: highlightVideo, fullMatch: fullVideo))
    }

    var body: some View {
        if playback.kinds.isEmpty {
            MatchVideosEmptyState(highlightCount: highlightCount)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                MatchVideosHeader(
                    kind: playback.selection, url: playback.url(for: playback.selection),
                    onFullScreen: { fullScreenRequest += 1 })

                if playback.kinds.count > 1 {
                    Picker("Video", selection: $playback.selection) {
                        ForEach(playback.kinds) { kind in
                            Text(kind.pickerTitle).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                inlinePlayer
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }

    private var inlinePlayer: some View {
        let kind = playback.selection
        let size = InlinePlayerLayout.playerSize(
            for: playback.displaySizes[kind], availableWidth: availableWidth,
            maxHeight: InlinePlayerLayout.maxHeight(forViewportHeight: viewportHeight))
        return ZStack {
            if let player = playback.player(for: kind) {
                MatchVideoPlayer(
                    player: player, fullScreenRequest: fullScreenRequest,
                    isLandscape: verticalSizeClass == .compact
                )
                .id(kind)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.black)
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .task(id: kind) { await playback.loadDisplaySize(for: kind) }
    }
}

/// Title of the selected video, then Full Screen and Share; the buttons wrap below the title at large type sizes.
private struct MatchVideosHeader: View {
    let kind: MatchVideoKind
    let url: URL?
    let onFullScreen: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Unwrapped: this row is only used when the title and both buttons fit on one line
            HStack(spacing: 12) {
                title.fixedSize()
                Spacer(minLength: 0)
                buttons.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                buttons
            }
        }
    }

    private var title: some View {
        Label {
            Text(kind.title)
                .font(.headline)
        } icon: {
            Image(systemName: kind.systemImage)
                .foregroundStyle(kind == .highlights ? .yellow : .blue)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: onFullScreen) {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)

            if let url {
                ShareLink(
                    item: VideoTransferable(url: url, name: kind.title),
                    preview: SharePreview(kind.title, image: Image(systemName: kind.systemImage))
                ) {
                    Label("Share \(kind.title)", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }
}

/// No video on disk: either nothing was marked, or the export has not produced it (yet).
private struct MatchVideosEmptyState: View {
    let highlightCount: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: highlightCount == 0 ? "star.slash" : "video.slash")
                .font(.largeTitle)
                .foregroundStyle(.gray)
            Text(highlightCount == 0 ? "No highlights marked" : "Video processing...")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(
                highlightCount == 0
                    ? "Use the double-tap gesture on your watch or the star button to mark highlights during play"
                    : "\(highlightCount) highlights were marked"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}
