//
//  ReelScoreboard.swift
//  score
//
//  Broadcast-style scoreboard burned into the highlight reel: both players, games, points and who serves,
//  as a lower-third panel. Rendered to a bitmap with ImageRenderer and composited over the video frames by
//  ReelOverlayComposer, so the design lives in SwiftUI (previewable) and the export only deals in images.
//

import CoreGraphics
import CoreText
import SwiftUI
import UIKit

/// What the scoreboard shows during one stretch of the reel.
nonisolated struct ReelScoreboardState: Hashable, Sendable {
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

/// Pixel geometry of the scoreboard for a video size. Everything scales with the video's short side (the
/// height of landscape footage), so the board looks the same at 720p, 1080p and 4K and still fits across a
/// portrait frame. Sizes are in pixels (the board is rendered at scale 1). The type is sized to stay legible
/// when the reel plays inline (about 340 pt wide in MatchDetailView) or on an upright phone, not only full screen.
nonisolated struct ReelScoreboardLayout: Equatable, Sendable {
    /// 1 at 720p.
    let unit: CGFloat
    /// 440 px at 720p, never wider than the frame's short side minus both margins.
    let panelWidth: CGFloat

    /// The smallest share of `nameFontSize` both names shrink to together. A name too long even then shrinks on
    /// its own (the row's `minimumScaleFactor` guard, by this share again) and is then cut short.
    static let minimumNameScale: CGFloat = 0.6
    private static let marginAt720: CGFloat = 32
    private static let panelWidthAt720: CGFloat = 440

    init(videoSize: CGSize) {
        let shortSide = max(min(videoSize.width, videoSize.height), 1)
        let unit = shortSide / 720
        self.unit = unit
        panelWidth = min(Self.panelWidthAt720 * unit, shortSide - 2 * Self.marginAt720 * unit)
    }

    var rowHeight: CGFloat { 50 * unit }
    var separatorHeight: CGFloat { max(1, (1 * unit).rounded()) }
    var panelSize: CGSize { CGSize(width: panelWidth, height: rowHeight * 2 + separatorHeight) }
    /// Distance from the frame's left and bottom edges.
    var margin: CGFloat { Self.marginAt720 * unit }
    var cornerRadius: CGFloat { 6 * unit }
    var chipWidth: CGFloat { 9 * unit }
    var padding: CGFloat { 12 * unit }
    var nameFontSize: CGFloat { 25 * unit }
    var numberFontSize: CGFloat { 29 * unit }
    var serveMarkerSize: CGFloat { 17 * unit }
    var gamesBoxWidth: CGFloat { 55 * unit }
    var pointsWidth: CGFloat { 65 * unit }

    /// Room for a name: the row minus the chip, the paddings around the name and the serve marker, the serve
    /// marker, the games box and the points cell.
    var nameColumnWidth: CGFloat {
        panelWidth - chipWidth - 3 * padding - serveMarkerSize - gamesBoxWidth - pointsWidth
    }

    /// The scale both rows' names are set at, from their widths at `nameFontSize`: 1 when both fit the name
    /// column, else what makes the wider one fit, but never below `minimumNameScale`. One scale for both rows
    /// keeps the names the same size on one baseline when only one of them is long.
    static func sharedNameScale(nameWidths: [CGFloat], columnWidth: CGFloat) -> CGFloat {
        guard let widest = nameWidths.max(), widest > columnWidth else { return 1 }
        return max(minimumNameScale, columnWidth / widest)
    }

    /// The name size both rows share. `measure` gives the names' widths at a font size. The system font tracks
    /// smaller sizes more loosely, so a name is not exactly `sharedNameScale` narrower at the scaled size: re-measure
    /// and scale again until the wider name fits (two or three passes), never below `minimumNameScale` of `base`.
    static func sharedNameFontSize(base: CGFloat, columnWidth: CGFloat, measure: (CGFloat) -> [CGFloat]) -> CGFloat {
        let smallest = base * minimumNameScale
        var size = base
        for _ in 0..<4 {
            let scale = sharedNameScale(nameWidths: measure(size), columnWidth: columnWidth)
            guard scale < 1, size > smallest else { break }
            size = max(smallest, size * scale)
        }
        return size
    }

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

    /// Where a row's serve marker sits (just left of the games box), in top-left image coordinates.
    func serveMarkerSlot(row: Int, in videoSize: CGSize) -> CGRect {
        let box = gamesBox(row: row, in: videoSize)
        return CGRect(
            x: box.minX - padding - serveMarkerSize, y: box.midY - serveMarkerSize / 2, width: serveMarkerSize,
            height: serveMarkerSize)
    }

    /// The colour chip of a row, in top-left image coordinates.
    func chip(row: Int, in videoSize: CGSize) -> CGRect {
        let rowRect = rowFrame(row, in: videoSize)
        return CGRect(x: rowRect.minX, y: rowRect.minY, width: chipWidth, height: rowHeight)
    }

    /// Where a row's name may draw (after the chip and its padding, `nameColumnWidth` wide), in top-left image
    /// coordinates.
    func nameColumn(row: Int, in videoSize: CGSize) -> CGRect {
        let rowRect = rowFrame(row, in: videoSize)
        return CGRect(
            x: rowRect.minX + chipWidth + padding, y: rowRect.minY, width: nameColumnWidth, height: rowHeight)
    }
}

/// Colours of the burned-in board (fixed: the video is the same in light and dark mode).
enum ReelScoreboardStyle {
    static let panel = Color.black.opacity(0.82)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.2)
    static let playerOne = Color(red: 0.2, green: 0.55, blue: 1.0)
    static let playerTwo = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let highlight = Color.white.opacity(0.22)
    static let separator = Color.white.opacity(0.18)

    /// Player names: heavy condensed capitals, as broadcast boards set them. The same font measures the names
    /// (`ReelScoreboardView.nameFontSize`) and draws them, so the shared size fits what is drawn.
    static func nameFont(size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .heavy, width: .condensed)
    }
}

/// The lower-third panel. Sized by `layout`, independent of Dynamic Type (it is video, not UI).
struct ReelScoreboardView: View {
    let state: ReelScoreboardState
    let layout: ReelScoreboardLayout

    var body: some View {
        let nameSize = Self.nameFontSize(names: [state.playerOneName, state.playerTwoName], layout: layout)
        VStack(spacing: 0) {
            ReelScoreboardRow(
                name: state.playerOneName, games: state.playerOneGames, points: state.playerOnePoints,
                chip: ReelScoreboardStyle.playerOne, isServing: state.server == 1,
                wonPoint: state.pointWonBy == 1, nameFontSize: nameSize, layout: layout)
            Rectangle()
                .fill(ReelScoreboardStyle.separator)
                .frame(height: layout.separatorHeight)
            ReelScoreboardRow(
                name: state.playerTwoName, games: state.playerTwoGames, points: state.playerTwoPoints,
                chip: ReelScoreboardStyle.playerTwo, isServing: state.server == 2,
                wonPoint: state.pointWonBy == 2, nameFontSize: nameSize, layout: layout)
        }
        .frame(width: layout.panelWidth, height: layout.panelSize.height)
        .background(ReelScoreboardStyle.panel)
        .clipShape(.rect(cornerRadius: layout.cornerRadius))
        .dynamicTypeSize(.large)
    }

    /// The name size both rows share: `layout.nameFontSize`, scaled down until the wider capitalised name fits
    /// the name column (see `ReelScoreboardLayout.sharedNameFontSize`), measured with the font that draws it.
    static func nameFontSize(names: [String], layout: ReelScoreboardLayout) -> CGFloat {
        let capitals = names.map { $0.uppercased() as NSString }
        return ReelScoreboardLayout.sharedNameFontSize(base: layout.nameFontSize, columnWidth: layout.nameColumnWidth) {
            size in
            let attributes: [NSAttributedString.Key: Any] = [.font: ReelScoreboardStyle.nameFont(size: size)]
            return capitals.map { $0.size(withAttributes: attributes).width.rounded(.up) }
        }
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
    /// Shared by both rows (`ReelScoreboardView.nameFontSize`), so a long name does not shrink only its own row.
    let nameFontSize: CGFloat
    let layout: ReelScoreboardLayout

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(chip)
                .frame(width: layout.chipWidth)
            // Broadcast boards set names in capitals; the name is user data, not a localized string
            Text(name.uppercased())
                .font(Font(ReelScoreboardStyle.nameFont(size: nameFontSize) as CTFont))
                .foregroundStyle(.white)
                .lineLimit(1)
                // Last resort only: the shared size already fits unless a name is too long even at the minimum
                .minimumScaleFactor(ReelScoreboardLayout.minimumNameScale)
                .padding(.leading, layout.padding)
            Spacer(minLength: layout.padding)
            // A fixed slot, so the name column is exactly `layout.nameColumnWidth`
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: layout.serveMarkerSize))
                .foregroundStyle(ReelScoreboardStyle.gold)
                .frame(width: layout.serveMarkerSize)
                .opacity(isServing ? 1 : 0)
                .padding(.trailing, layout.padding)
            Text(games, format: .number)
                .font(.system(size: layout.numberFontSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.black)
                .frame(width: layout.gamesBoxWidth, height: layout.rowHeight)
                .background(ReelScoreboardStyle.gold)
            // The point just won flashes: the winner's points cell turns white
            Text(points, format: .number)
                .font(.system(size: layout.numberFontSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(wonPoint ? .black : .white)
                .frame(width: layout.pointsWidth, height: layout.rowHeight)
                .background(wonPoint ? Color.white : Color.clear)
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

#Preview("720p, player two has just won the point") {
    ReelScoreboardView(
        state: ReelScoreboardState(
            playerOneName: "Alex", playerTwoName: "Lucio", playerOneGames: 1, playerTwoGames: 1,
            playerOnePoints: 10, playerTwoPoints: 11, server: 2, pointWonBy: 2),
        layout: ReelScoreboardLayout(videoSize: CGSize(width: 1280, height: 720))
    )
    .padding()
    .background(.gray)
}

#Preview("720p, one long name: both rows share the smaller size") {
    ReelScoreboardView(
        state: ReelScoreboardState(
            playerOneName: "Christopher Featherstonehaugh", playerTwoName: "Bob", playerOneGames: 2,
            playerTwoGames: 1, playerOnePoints: 7, playerTwoPoints: 9, server: 1, pointWonBy: nil),
        layout: ReelScoreboardLayout(videoSize: CGSize(width: 1280, height: 720))
    )
    .padding()
    .background(.gray)
}
