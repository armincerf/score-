//
//  ReelScoreboard.swift
//  score
//
//  Broadcast-style scoreboard burned into the highlight reel: both players, games, points and who serves,
//  as a lower-third panel. Rendered to a bitmap with ImageRenderer and composited over the video frames by
//  ReelOverlayComposer, so the design lives in SwiftUI (previewable) and the export only deals in images.
//

import CoreGraphics
import SwiftUI

/// What the scoreboard shows during one stretch of the reel.
nonisolated struct ReelScoreboardState: Equatable, Sendable {
    let playerOneName: String
    let playerTwoName: String
    let playerOneGames: Int
    let playerTwoGames: Int
    let playerOnePoints: Int
    let playerTwoPoints: Int
    /// Who serves the next point (1 or 2), or nil when unknown.
    let server: Int?
    /// Player whose point is being celebrated (their row lights up), or nil.
    let pointWonBy: Int?
}

/// Pixel geometry of the scoreboard for a video size. Everything scales with the video height, so the
/// board looks the same at 720p, 1080p and 4K. Sizes are in pixels (the board is rendered at scale 1).
nonisolated struct ReelScoreboardLayout: Equatable, Sendable {
    /// 1 at 720p.
    let unit: CGFloat

    init(videoSize: CGSize) {
        unit = max(videoSize.height, 1) / 720
    }

    var rowHeight: CGFloat { 42 * unit }
    var separatorHeight: CGFloat { max(1, (1 * unit).rounded()) }
    var panelWidth: CGFloat { 440 * unit }
    var panelSize: CGSize { CGSize(width: panelWidth, height: rowHeight * 2 + separatorHeight) }
    /// Distance from the frame's left and bottom edges.
    var margin: CGFloat { 32 * unit }
    var cornerRadius: CGFloat { 6 * unit }
    var chipWidth: CGFloat { 7 * unit }
    var padding: CGFloat { 12 * unit }
    var nameFontSize: CGFloat { 21 * unit }
    var numberFontSize: CGFloat { 24 * unit }
    var serveMarkerSize: CGFloat { 12 * unit }
    var gamesBoxWidth: CGFloat { 46 * unit }
    var pointsWidth: CGFloat { 54 * unit }

    /// Bottom-left corner of the panel in Core Image coordinates (origin at the frame's bottom-left).
    var origin: CGPoint { CGPoint(x: margin, y: margin) }

    /// Frame of the panel in top-left image coordinates (as a CGImage/UIKit sees it).
    func panelFrame(in videoSize: CGSize) -> CGRect {
        CGRect(
            x: margin, y: videoSize.height - margin - panelSize.height,
            width: panelSize.width, height: panelSize.height)
    }

    /// Frame of one player's row (0 = player one, 1 = player two) in top-left image coordinates.
    func rowFrame(_ row: Int, in videoSize: CGSize) -> CGRect {
        let panel = panelFrame(in: videoSize)
        return CGRect(
            x: panel.minX, y: panel.minY + CGFloat(row) * (rowHeight + separatorHeight),
            width: panel.width, height: rowHeight)
    }

    /// The gold games box of a row, in top-left image coordinates.
    func gamesBox(row: Int, in videoSize: CGSize) -> CGRect {
        let rowRect = rowFrame(row, in: videoSize)
        return CGRect(
            x: rowRect.maxX - pointsWidth - gamesBoxWidth, y: rowRect.minY, width: gamesBoxWidth, height: rowHeight)
    }

    /// The points cell of a row, in top-left image coordinates.
    func pointsCell(row: Int, in videoSize: CGSize) -> CGRect {
        let rowRect = rowFrame(row, in: videoSize)
        return CGRect(x: rowRect.maxX - pointsWidth, y: rowRect.minY, width: pointsWidth, height: rowHeight)
    }

    /// The colour chip of a row, in top-left image coordinates.
    func chip(row: Int, in videoSize: CGSize) -> CGRect {
        let rowRect = rowFrame(row, in: videoSize)
        return CGRect(x: rowRect.minX, y: rowRect.minY, width: chipWidth, height: rowHeight)
    }
}

/// Colours of the burned-in board (fixed: the video is the same in light and dark mode).
enum ReelScoreboardStyle {
    static let panel = Color.black.opacity(0.82)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.2)
    static let playerOne = Color(red: 0.2, green: 0.55, blue: 1.0)
    static let playerTwo = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let highlight = Color.white.opacity(0.16)
    static let separator = Color.white.opacity(0.18)
}

/// The lower-third panel. Sized by `layout`, independent of Dynamic Type (it is video, not UI).
struct ReelScoreboardView: View {
    let state: ReelScoreboardState
    let layout: ReelScoreboardLayout

    var body: some View {
        VStack(spacing: 0) {
            ReelScoreboardRow(
                name: state.playerOneName, games: state.playerOneGames, points: state.playerOnePoints,
                chip: ReelScoreboardStyle.playerOne, isServing: state.server == 1,
                wonPoint: state.pointWonBy == 1, layout: layout)
            Rectangle()
                .fill(ReelScoreboardStyle.separator)
                .frame(height: layout.separatorHeight)
            ReelScoreboardRow(
                name: state.playerTwoName, games: state.playerTwoGames, points: state.playerTwoPoints,
                chip: ReelScoreboardStyle.playerTwo, isServing: state.server == 2,
                wonPoint: state.pointWonBy == 2, layout: layout)
        }
        .frame(width: layout.panelWidth, height: layout.panelSize.height)
        .background(ReelScoreboardStyle.panel)
        .clipShape(.rect(cornerRadius: layout.cornerRadius))
        .dynamicTypeSize(.large)
    }
}

/// One player: colour chip, name, serve marker, games (gold box) and points.
struct ReelScoreboardRow: View {
    let name: String
    let games: Int
    let points: Int
    let chip: Color
    let isServing: Bool
    let wonPoint: Bool
    let layout: ReelScoreboardLayout

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(chip)
                .frame(width: layout.chipWidth)
            // Broadcast boards set names in capitals; the name is user data, not a localized string
            Text(name.uppercased())
                .font(.system(size: layout.nameFontSize, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.leading, layout.padding)
            Spacer(minLength: layout.padding)
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: layout.serveMarkerSize))
                .foregroundStyle(ReelScoreboardStyle.gold)
                .opacity(isServing ? 1 : 0)
                .padding(.trailing, layout.padding)
            Text(games, format: .number)
                .font(.system(size: layout.numberFontSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.black)
                .frame(width: layout.gamesBoxWidth, height: layout.rowHeight)
                .background(ReelScoreboardStyle.gold)
            Text(points, format: .number)
                .font(.system(size: layout.numberFontSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: layout.pointsWidth, height: layout.rowHeight)
        }
        .frame(height: layout.rowHeight)
        .background(wonPoint ? ReelScoreboardStyle.highlight : Color.clear)
    }
}

/// Rasterises the board at its pixel size with a transparent background.
@MainActor
enum ReelScoreboardRenderer {
    static func render(_ state: ReelScoreboardState, layout: ReelScoreboardLayout) -> CGImage? {
        let renderer = ImageRenderer(content: ReelScoreboardView(state: state, layout: layout))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

#Preview("720p, player one serving") {
    ReelScoreboardView(
        state: ReelScoreboardState(
            playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 1, playerTwoGames: 0,
            playerOnePoints: 5, playerTwoPoints: 3, server: 1, pointWonBy: nil),
        layout: ReelScoreboardLayout(videoSize: CGSize(width: 1280, height: 720))
    )
    .padding()
    .background(.gray)
}
