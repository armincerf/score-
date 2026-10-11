//
//  ReelScoreboardLayoutTests.swift
//  scoreTests
//
//  The board's geometry (ReelScoreboardLayout) and the one name size both rows share (sharedNameScale, measured by
//  ReelScoreboardView.nameFontSize). Boards with long names are rendered (board-long-name.png,
//  board-full-names.png next to ReelOverlayTests' frames) and both rows' names are checked for the same size.
//

import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import score

@Suite("ReelScoreboardLayout")
struct ReelScoreboardLayoutTests {
    private static let hd = CGSize(width: 1280, height: 720)

    // MARK: - Geometry

    @Test("At 720p the type is phone-sized and the panel is no wider than before")
    func sizesAt720p() {
        let layout = ReelScoreboardLayout(videoSize: Self.hd)
        #expect(layout.panelWidth == 440 && layout.margin == 32, "the panel must not cover more of the picture")
        #expect(layout.rowHeight == 50 && layout.panelSize.height == 101)
        #expect(layout.nameFontSize == 25 && layout.numberFontSize == 29 && layout.serveMarkerSize == 17)
        #expect(layout.chipWidth == 9)
        // 440 - 9 (chip) - 3 x 12 (paddings) - 17 (serve marker) - 55 (games) - 65 (points)
        #expect(layout.nameColumnWidth == 258)
    }

    @Test("The panel and the name column scale with the video height at 1080p and 4K", arguments: [1080, 2160])
    func panelScalesWithHeight(height: Int) {
        let layout = ReelScoreboardLayout(videoSize: CGSize(width: height * 16 / 9, height: height))
        let reference = ReelScoreboardLayout(videoSize: Self.hd)
        let scale = CGFloat(height) / 720
        #expect(abs(layout.panelSize.width - reference.panelSize.width * scale) < 0.001)
        #expect(abs(layout.panelSize.height - reference.panelSize.height * scale) <= 1, "separator rounds to a pixel")
        #expect(abs(layout.nameColumnWidth - reference.nameColumnWidth * scale) < 0.001)
        #expect(abs(layout.nameFontSize - reference.nameFontSize * scale) < 0.001)
    }

    @Test("Portrait 720x1280: the panel is capped to the frame's width less both margins and fits")
    func panelFitsPortrait() {
        let portrait = CGSize(width: 720, height: 1280)
        let layout = ReelScoreboardLayout(videoSize: portrait)
        #expect(layout == ReelScoreboardLayout(videoSize: Self.hd))
        #expect(layout.panelWidth <= portrait.width - 2 * layout.margin)
        #expect(layout.panelFrame(in: portrait).maxX + layout.margin <= portrait.width)
        #expect(layout.nameColumn(row: 0, in: portrait).maxX < layout.serveMarkerSlot(row: 0, in: portrait).minX)
    }

    // MARK: - One name size for both rows

    @Test("Both names fit: both rows keep the full name size")
    func bothNamesFit() {
        let layout = ReelScoreboardLayout(videoSize: Self.hd)
        let column = layout.nameColumnWidth
        #expect(ReelScoreboardLayout.sharedNameScale(nameWidths: [60, 80], columnWidth: column) == 1)
        #expect(ReelScoreboardLayout.sharedNameScale(nameWidths: [column, 10], columnWidth: column) == 1)
        #expect(ReelScoreboardLayout.sharedNameScale(nameWidths: [], columnWidth: column) == 1)
        #expect(ReelScoreboardView.nameFontSize(names: ["Alex", "Lucio"], layout: layout) == layout.nameFontSize)
    }

    @Test("One long name: one scale for both rows, just small enough for the wider name to fit")
    func oneLongName() {
        let scale = ReelScoreboardLayout.sharedNameScale(nameWidths: [300, 40], columnWidth: 240)
        #expect(scale == 0.8)
        #expect(ReelScoreboardLayout.sharedNameScale(nameWidths: [40, 300], columnWidth: 240) == scale)
    }

    @Test("An absurdly long name stops at the minimum scale (0.6)")
    func absurdName() {
        #expect(ReelScoreboardLayout.minimumNameScale == 0.6)
        #expect(ReelScoreboardLayout.sharedNameScale(nameWidths: [2400, 40], columnWidth: 240) == 0.6)
    }

    @Test("Widths not proportional to size (looser tracking when smaller): re-measured until the wider name fits")
    func sizeIsRefinedUntilItFits() {
        // 20 characters, each 0.6 em plus 0.5 px of tracking that does not shrink with the size, rounded up to whole
        // pixels like the real measurement
        let measure: (CGFloat) -> [CGFloat] = { size in [(20 * (0.6 * size + 0.5)).rounded(.up), 60] }
        let size = ReelScoreboardLayout.sharedNameFontSize(base: 25, columnWidth: 258, measure: measure)
        let oneScale = 25 * ReelScoreboardLayout.sharedNameScale(nameWidths: measure(25), columnWidth: 258)
        #expect(measure(oneScale)[0] > 258, "one scale alone overflows: the case being tested")
        #expect(measure(size)[0] <= 258, "fits after refining, got \(measure(size)[0]) at \(size)")
        #expect(size > 258 / (20 * 0.6) - 1, "and not much smaller than needed, got \(size)")
        #expect(ReelScoreboardLayout.sharedNameFontSize(base: 25, columnWidth: 258) { _ in [2000] } == 15, "floor")
        #expect(ReelScoreboardLayout.sharedNameFontSize(base: 25, columnWidth: 258) { _ in [100, 200] } == 25)
    }

    @Test("Measured: a long name gives both rows one smaller size, at which it fits the column")
    func measuredLongName() {
        let layout = ReelScoreboardLayout(videoSize: Self.hd)
        let long = "Christopher Featherstonehaugh"
        let size = ReelScoreboardView.nameFontSize(names: [long, "Bob"], layout: layout)
        #expect(size < layout.nameFontSize && size >= layout.nameFontSize * ReelScoreboardLayout.minimumNameScale)
        #expect(ReelScoreboardView.nameFontSize(names: ["Bob", long], layout: layout) == size)
        let font = ReelScoreboardStyle.nameFont(size: size)
        let width = (long.uppercased() as NSString).size(withAttributes: [.font: font]).width
        #expect(width <= layout.nameColumnWidth, "\(width) px at \(size) px in a \(layout.nameColumnWidth) px column")
    }

    // MARK: - Rendered

    @Test(
        "Rendered: both rows' names have the same cap height and baseline, and the long one fits its column",
        arguments: [
            ("Christopher Featherstonehaugh", "Bob", "board-long-name"),
            ("Alex Davis", "Lucio D'Alessandro", "board-full-names"),
        ])
    func renderedNamesShareOneSize(one: String, two: String, file: String) throws {
        let layout = ReelScoreboardLayout(videoSize: Self.hd)
        let state = ReelScoreboardState(
            playerOneName: one, playerTwoName: two, playerOneGames: 2, playerTwoGames: 1, playerOnePoints: 7,
            playerTwoPoints: 9, server: 1, pointWonBy: nil)
        let image = try #require(ReelScoreboardRenderer.render(state, layout: layout))
        try ReelFrames.savePNG(image, name: file)
        let pixels = ReelPixels(image)
        let panel = layout.panelFrame(in: Self.hd)
        let columns = (0...1).map { row in
            layout.nameColumn(row: row, in: Self.hd).offsetBy(dx: -panel.minX, dy: -panel.minY)
        }
        let first = try #require(Self.inkBounds(pixels, in: columns[0]), "no name drawn in row 1")
        let second = try #require(Self.inkBounds(pixels, in: columns[1]), "no name drawn in row 2")
        let rowOffset = layout.rowHeight + layout.separatorHeight
        #expect(abs(first.height - second.height) <= 1, "cap heights \(first.height) and \(second.height)")
        #expect(abs(first.minY - (second.minY - rowOffset)) <= 1, "tops \(first.minY), \(second.minY - rowOffset)")
        #expect(abs(first.maxY - (second.maxY - rowOffset)) <= 1, "baselines \(first.maxY), \(second.maxY - rowOffset)")
        #expect(first.maxX <= columns[0].maxX && second.maxX <= columns[1].maxX, "names stay in their column")
    }

    /// Bounding box of the white name glyphs inside `rect` (top-left coordinates of the board image).
    private static func inkBounds(_ pixels: ReelPixels, in rect: CGRect) -> CGRect? {
        func isInk(_ colour: (r: Int, g: Int, b: Int)) -> Bool {
            colour.r > 160 && colour.g > 160 && colour.b > 160
        }
        var bounds: CGRect?
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where isInk(pixels.rgb(at: CGPoint(x: x, y: y))) {
                bounds = (bounds ?? CGRect(x: x, y: y, width: 1, height: 1))
                    .union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return bounds
    }
}
