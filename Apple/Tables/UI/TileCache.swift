import SwiftUI
import TablesEngine

/// What the tiles of each sheet draw, kept for as long as the sheet, its line
/// sizes and the zoom stay as they are.
///
/// The grid's body runs again on every scroll frame, for the sheet and for
/// each frozen pane and canvas table. What a tile draws depends only on the
/// sheet, its metrics and which tile it is, never on where the sheet is
/// scrolled to, so it is worked out the first time the tile shows and handed
/// back from then on. Being the same value as last time, it also compares
/// equal to it at once, so the tile is not redrawn either.
///
/// Nothing has to tell the cache that the sheet changed: each sheet's tiles
/// are kept with the `SheetDrawingKey` and metrics they were built from, and
/// a sheet that no longer matches them, after any edit, undo, restyle,
/// merge, comment, resize, hide or zoom, starts again from no tiles.
@MainActor
final class TileCache {
    /// One sheet's tiles, as drawn from one version of it at one size.
    @MainActor
    final class SheetTiles {
        /// The sheet's merges and comments, found without walking them.
        let lookup: SheetLookup
        fileprivate let key: SheetDrawingKey
        fileprivate let metrics: SheetMetrics
        private var tiles: [CellRange: TileContents] = [:]
        /// How many tiles a sheet keeps: several screenfuls at any zoom.
        private static let tileLimit = 512

        fileprivate init(sheet: Worksheet, key: SheetDrawingKey, metrics: SheetMetrics) {
            lookup = SheetLookup(sheet)
            self.key = key
            self.metrics = metrics
        }

        /// The appearance the sheet's colours adapt to, for a viewer's.
        func scheme(for viewer: ColorScheme) -> ColorScheme {
            lookup.colorScheme(for: viewer)
        }

        /// What the tile covering `range` draws, built by `build` the first
        /// time it is asked for.
        func contents(of range: CellRange, build: () -> TileContents) -> TileContents {
            if let contents = tiles[range] { return contents }
            let contents = build()
            // A long scroll through a big sheet visits far more tiles than a
            // screen shows. Past this many, start over rather than keep them all.
            if tiles.count >= Self.tileLimit { tiles.removeAll(keepingCapacity: true) }
            tiles[range] = contents
            return contents
        }
    }

    private var sheets: [Worksheet.ID: SheetTiles] = [:]
    /// The metrics of the canvas's other tables, by sheet.
    private var metrics: [Worksheet.ID: (geometry: Geometry, metrics: SheetMetrics)] = [:]

    /// The tiles of `sheet` drawn at `metrics`: the ones kept from before, if
    /// neither has changed since.
    func tiles(of sheet: Worksheet, metrics: SheetMetrics) -> SheetTiles {
        let key = SheetDrawingKey(sheet)
        if let kept = sheets[sheet.id], kept.key == key, kept.metrics == metrics { return kept }
        let tiles = SheetTiles(sheet: sheet, key: key, metrics: metrics)
        // Sheets come and go with the workbook, and there are never many.
        if sheets.count >= 32 { sheets.removeAll() }
        sheets[sheet.id] = tiles
        return tiles
    }

    /// A sheet's metrics at `zoom` on a display of `pixelScale`, measured
    /// again only once its lines, the zoom or the display change.
    ///
    /// For the tables on a canvas other than the one being worked on, which
    /// have no metrics kept for them elsewhere. Measuring a sheet with sized
    /// lines walks all of them, and the new offsets would not compare equal
    /// to the old ones without a walk of their own.
    func metrics(of sheet: Worksheet, zoom: Double, pixelScale: Double? = nil) -> SheetMetrics {
        let geometry = Geometry(sheet, zoom: zoom, pixelScale: pixelScale)
        if let kept = metrics[sheet.id], kept.geometry == geometry { return kept.metrics }
        let measured = SheetMetrics(sheet: sheet, zoom: zoom, pixelScale: pixelScale)
        if metrics.count >= 32 { metrics.removeAll() }
        metrics[sheet.id] = (geometry, measured)
        return measured
    }

    /// What a sheet's metrics are measured from.
    private struct Geometry: Equatable {
        let columnWidths: [Int: Double]
        let rowHeights: [Int: Double]
        let hiddenRows: Set<Int>
        let hiddenColumns: Set<Int>
        let standardRowHeight: Double
        let rowCount: Int
        let columnCount: Int
        let zoom: Double
        let pixelScale: Double?

        init(_ sheet: Worksheet, zoom: Double, pixelScale: Double?) {
            columnWidths = sheet.columnWidths
            rowHeights = sheet.rowHeights
            hiddenRows = sheet.hiddenRows
            hiddenColumns = sheet.hiddenColumns
            standardRowHeight = sheet.standardRowHeight
            rowCount = sheet.rowCount
            columnCount = sheet.columnCount
            self.zoom = zoom
            self.pixelScale = pixelScale
        }
    }
}
