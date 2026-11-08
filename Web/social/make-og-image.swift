// Draws social/og-image.png, the 1200 × 630 picture shown when a link to Tables
// is shared (Open Graph and Twitter cards). Run from Web/ on a Mac:
//
//   swift social/make-og-image.swift
//
// It's the top of the iPhone and iPad app's document picker
// (Apple/Tables/UI/DocumentLaunchView.swift) in light mode: the green wash
// ruled like a sheet, and the wall of things a workbook can hold, with the app
// icon and name over it. The card's only text is the name, so the wall leaves
// out the app's value, formula and macro tiles. Keep the two looking alike when either changes.

import AppKit
import SwiftUI

// MARK: - Colours, as in DocumentLaunch (light mode)

let topColor = Color(red: 0.86, green: 0.95, blue: 0.89)
let bottomColor = Color(red: 0.95, green: 0.98, blue: 0.96)
let ink = Color(red: 0.10, green: 0.56, blue: 0.31)
let tileFill = Color.white

// MARK: - The backdrop, as in DocumentLaunchBackground

struct Backdrop: View {
    let cellSize = CGSize(width: 64, height: 26)

    var body: some View {
        ZStack {
            LinearGradient(colors: [topColor, bottomColor], startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var lines = Path()
                var x = 0.0
                while x <= size.width {
                    lines.move(to: CGPoint(x: x, y: 0))
                    lines.addLine(to: CGPoint(x: x, y: size.height))
                    x += cellSize.width
                }
                var y = 0.0
                while y <= size.height {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                    y += cellSize.height
                }
                context.stroke(lines, with: .color(ink.opacity(0.12)), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - The feature wall, as in DocumentLaunchFeatureWall

enum Tile {
    case value(String), formula(String), macro(String)
    case columnChart, barChart, lineChart, areaChart, pieChart, doughnutChart, scatterChart
    case table, dataBar, colorScale
    case comment, note, checkBox, optionButton, dropDown, picture
}

struct FeatureWall: View {
    /// The app's rows without the tiles that hold values, formulas or code, so
    /// the name is the card's only text.
    let rows: [[Tile]] = [
        [.columnChart, .comment, .doughnutChart, .colorScale, .table, .checkBox, .lineChart, .picture],
        [.checkBox, .table, .scatterChart, .picture, .areaChart, .note, .lineChart, .colorScale],
        [.areaChart, .colorScale, .pieChart, .optionButton, .barChart, .comment, .scatterChart, .table],
        [.note, .barChart, .columnChart, .optionButton, .doughnutChart, .picture, .colorScale, .checkBox],
    ]
    let rowOffsets: [Double] = [-16, -44, -28, -8, -36]
    let tileHeight = 40.0
    let spacing = 8.0
    let rowCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<rowCount, id: \.self) { index in
                let pattern = rows[index % rows.count]
                let shift = (index / rows.count * 3) % pattern.count
                let rotated = Array(pattern[shift...] + pattern[..<shift])
                let tiles = Array(repeating: rotated, count: 3).flatMap { $0 }
                HStack(spacing: spacing) {
                    ForEach(tiles.indices, id: \.self) { position in
                        tile(tiles[position])
                    }
                }
                .fixedSize()
                .offset(x: rowOffsets[index % rowOffsets.count])
            }
        }
        .padding(.top, spacing)
    }

    @ViewBuilder
    func tile(_ tile: Tile) -> some View {
        switch tile {
        case .value(let value): valueTile(value)
        case .formula(let formula): formulaTile(formula)
        case .macro(let line): macroTile(line)
        case .columnChart: columnChartTile
        case .barChart: barChartTile
        case .lineChart: lineChartTile
        case .areaChart: areaChartTile
        case .pieChart: pieChartTile(lineWidth: 10, diameter: 10)
        case .doughnutChart: pieChartTile(lineWidth: 5, diameter: 15)
        case .scatterChart: scatterChartTile
        case .table: tableTile
        case .dataBar: dataBarTile
        case .colorScale: colorScaleTile
        case .comment: symbolTile("text.bubble.fill", color: .orange)
        case .note: symbolTile("note.text", color: .yellow)
        case .checkBox: symbolTile("checkmark.square.fill", color: .blue)
        case .optionButton: symbolTile("largecircle.fill.circle", color: .blue)
        case .dropDown: dropDownTile
        case .picture: symbolTile("photo.fill", color: .cyan)
        }
    }

    func tile(width: CGFloat? = nil, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width, height: tileHeight)
            .background(tileFill, in: .rect(cornerRadius: 12))
    }

    func symbolTile(_ name: String, color: Color) -> some View {
        tile(width: tileHeight) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    func valueTile(_ value: String) -> some View {
        tile {
            Text(verbatim: value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    func formulaTile(_ formula: String) -> some View {
        tile {
            HStack(spacing: 6) {
                Text(verbatim: "fx")
                    .font(.system(size: 12, weight: .semibold, design: .serif).italic())
                    .foregroundStyle(.secondary)
                Text(verbatim: formula)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
    }

    func macroTile(_ line: String) -> some View {
        tile {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.indigo)
                Text(verbatim: line)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
    }

    var columnChartTile: some View {
        tile(width: 60) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(zip([0.45, 0.8, 0.6, 1.0], [Color.blue, .orange, .pink, .purple])), id: \.0) { height, color in
                    Capsule().fill(color).frame(width: 6, height: 20 * height)
                }
            }
        }
    }

    var lineChartTile: some View {
        tile(width: 60) {
            Path { path in
                let points = [0.2, 0.55, 0.35, 0.8, 0.6, 1.0]
                for (index, value) in points.enumerated() {
                    let point = CGPoint(x: Double(index) * 7, y: 20 * (1 - value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .frame(width: 35, height: 20)
        }
    }

    func pieChartTile(lineWidth: Double, diameter: Double) -> some View {
        tile(width: tileHeight) {
            ZStack {
                ForEach(Array(zip([(0.0, 0.45), (0.45, 0.75), (0.75, 1.0)], [Color.orange, .pink, .purple])), id: \.0.0) { slice, color in
                    Circle()
                        .trim(from: slice.0, to: slice.1)
                        .stroke(color, lineWidth: lineWidth)
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: diameter, height: diameter)
        }
    }

    var barChartTile: some View {
        tile(width: 60) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(zip([0.6, 1.0, 0.4, 0.75], [Color.blue, .orange, .pink, .purple])), id: \.0) { length, color in
                    Capsule().fill(color).frame(width: 34 * length, height: 4)
                }
            }
            .frame(width: 34, alignment: .leading)
        }
    }

    var areaChartTile: some View {
        tile(width: 60) {
            let values = [0.3, 0.5, 0.4, 0.75, 0.6, 0.9]
            let step = 7.0
            let curve = Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: Double(index) * step, y: 20 * (1 - value))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            ZStack {
                Path { path in
                    path.addPath(curve)
                    path.addLine(to: CGPoint(x: Double(values.count - 1) * step, y: 20))
                    path.addLine(to: CGPoint(x: 0, y: 20))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.purple.opacity(0.5), .purple.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                curve.stroke(.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 35, height: 20)
        }
    }

    var scatterChartTile: some View {
        tile(width: 60) {
            let points: [(Double, Double, Color)] = [
                (0.05, 0.8, .blue), (0.25, 0.55, .orange), (0.4, 0.7, .blue), (0.55, 0.3, .pink),
                (0.7, 0.45, .orange), (0.85, 0.15, .blue), (0.95, 0.35, .pink),
            ]
            ZStack(alignment: .topLeading) {
                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(points[index].2)
                        .frame(width: 5, height: 5)
                        .offset(x: 34 * points[index].0 - 2.5, y: 22 * points[index].1 - 2.5)
                }
            }
            .frame(width: 34, height: 22, alignment: .topLeading)
        }
    }

    var tableTile: some View {
        tile(width: 60) {
            VStack(spacing: 1.5) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 1.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Rectangle()
                                .fill(row == 0 ? Color.blue : Color.blue.opacity(row.isMultiple(of: 2) ? 0.3 : 0.12))
                                .frame(width: 11, height: 5)
                        }
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 2))
        }
    }

    var dataBarTile: some View {
        tile {
            Text(verbatim: "842")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 56, alignment: .trailing)
                .padding(.trailing, 4)
                .background(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.blue.opacity(0.6), .blue.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 42, height: 20)
                }
        }
    }

    var colorScaleTile: some View {
        tile {
            HStack(spacing: 2) {
                ForEach([Color.red, .orange, .yellow, .mint], id: \.self) { color in
                    RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.75)).frame(width: 14, height: 20)
                }
            }
        }
    }

    var dropDownTile: some View {
        tile {
            HStack(spacing: 8) {
                Text(verbatim: "Q4")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The card

/// 600 × 315 points, drawn at 2× for 1200 × 630 pixels.
struct Card: View {
    let icon: NSImage
    let size = CGSize(width: 600, height: 315)

    var body: some View {
        ZStack {
            Backdrop()
            // The wall, faded as one layer as in the app, and cleared around the name.
            FeatureWall(rowCount: Int(size.height / 48) + 1)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
                .compositingGroup()
                .opacity(0.35)
                .mask {
                    EllipticalGradient(
                        stops: [.init(color: .clear, location: 0.32), .init(color: .black, location: 0.8)],
                        center: .center
                    )
                }
            HStack(spacing: 22) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .shadow(color: ink.opacity(0.25), radius: 12, y: 6)
                Text(verbatim: "Tables")
                    .font(.system(size: 80, weight: .semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.09, blue: 0.09))
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .light)
    }
}

let icon = NSImage(contentsOfFile: "app/icons/icon.svg")!
let renderer = await MainActor.run { () -> NSImage? in
    let renderer = ImageRenderer(content: Card(icon: icon))
    renderer.scale = 2
    return renderer.nsImage
}
guard let image = renderer,
      let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
    fatalError("Couldn't draw the image")
}
try png.write(to: URL(fileURLWithPath: "social/og-image.png"))
print("Wrote social/og-image.png (\(Int(image.size.width * 2)) × \(Int(image.size.height * 2)))")
