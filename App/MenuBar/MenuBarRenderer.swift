import AppKit
import FlatlineKit

/// Draws the status item as one image: fixed-width segments for each enabled metric.
@MainActor
enum MenuBarRenderer {
    enum Piece: Sendable, Equatable {
        /// Small caption over a value, e.g. `CPU` / ` 23%`.
        case stacked(caption: String, value: String, width: CGFloat)
        /// Upload over download.
        case network(up: String, down: String, width: CGFloat)
        /// Mini line graph; values are already scaled to 0...1.
        case trace(primary: [Double], secondary: [Double]?)
    }

    static let traceWidth: CGFloat = 28
    static let gap: CGFloat = 8
    static let innerGap: CGFloat = 4
    private static let rateChars = 9 // "12.3 MB/s"

    /// Everything that determines the pixels. Equal layouts render identical images,
    /// so the status item can skip redraws when nothing visible changed.
    struct Layout: Equatable {
        var groups: [[Piece]]
    }

    static func layout(engine: MetricsEngine, preferences: Preferences) -> Layout {
        var groups: [[Piece]] = []

        if preferences.showCPU {
            groups.append(pieces(for: preferences.cpuStyle) {
                Piece.stacked(caption: "CPU", value: Format.percent(engine.cpu.total).leftPadded(to: 4), width: percentWidth)
            } trace: {
                Piece.trace(primary: quantized(engine.cpuHistory.suffix(Int(traceWidth))), secondary: nil)
            })
        }

        if preferences.showMemory {
            let memory = engine.memory
            let (value, widest) = switch preferences.memoryDisplay {
            case .percent: (Format.percent(memory.usedFraction).leftPadded(to: 4), "100%")
            case .gigabytes: (Format.gigabytesCompact(memory.used), digitTemplate(Format.gigabytesCompact(memory.physical)))
            }
            groups.append(pieces(for: preferences.memoryStyle) {
                Piece.stacked(
                    caption: "MEM",
                    value: value.leftPadded(to: widest.count),
                    width: preferences.memoryDisplay == .percent ? percentWidth : stackedWidth(caption: "MEM", widest: widest)
                )
            } trace: {
                Piece.trace(primary: quantized(engine.memoryHistory.suffix(Int(traceWidth))), secondary: nil)
            })
        }

        if preferences.showNetwork {
            let bits = preferences.networkUnit == .bits
            groups.append(pieces(for: preferences.networkStyle) {
                Piece.network(
                    up: "↑ " + Format.rate(engine.network.bytesOutPerSecond, bits: bits).leftPadded(to: rateChars),
                    down: "↓ " + Format.rate(engine.network.bytesInPerSecond, bits: bits).leftPadded(to: rateChars),
                    width: networkWidth
                )
            } trace: {
                let down = engine.networkInHistory.suffix(Int(traceWidth))
                let up = engine.networkOutHistory.suffix(Int(traceWidth))
                // Scale to the window's peak, but never below 10 KB/s so idle chatter stays flat.
                let peak = max(10_000, down.max() ?? 0, up.max() ?? 0)
                return Piece.trace(primary: quantized(down.map { $0 / peak }), secondary: quantized(up.map { $0 / peak }))
            })
        }
        return Layout(groups: groups)
    }

    /// Renders `layout` at `scale` pixels per point, in the menu bar's own label
    /// color (resolved for `appearance`) so it can go straight into a layer.
    ///
    /// Plain Core Graphics into canvases kept between ticks. Rasterizing here,
    /// rather than handing AppKit a drawing-handler image, also avoids a CoreText
    /// crash in the status bar's stylized drawing path on macOS 27.
    static func image(for layout: Layout, appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        let groups = layout.groups
        let widths = groups.map { group in
            group.map(width(of:)).reduce(0, +) + innerGap * CGFloat(max(0, group.count - 1))
        }
        let size = CGSize(
            width: max(1, ceil(widths.reduce(0, +) + gap * CGFloat(max(0, groups.count - 1)))),
            height: NSStatusBar.system.thickness
        )
        guard let canvas = canvas(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let ink = colors(for: appearance, scale: scale)

        canvas.clear()
        drawingCanvas = canvas
        defer { drawingCanvas = nil }
        var x: CGFloat = 0
        for group in groups {
            for (index, piece) in group.enumerated() {
                if index > 0 { x += innerGap }
                draw(piece, at: x, height: size.height, ink: ink, in: context)
                x += width(of: piece)
            }
            x += gap
        }
        return canvas.image()
    }

    static func accessibilityLabel(engine: MetricsEngine, preferences: Preferences) -> String {
        var parts: [String] = []
        if preferences.showCPU { parts.append("CPU \(Format.percent(engine.cpu.total))") }
        if preferences.showMemory { parts.append("memory \(Format.percent(engine.memory.usedFraction))") }
        if preferences.showNetwork {
            let bits = preferences.networkUnit == .bits
            parts.append("download \(Format.rate(engine.network.bytesInPerSecond, bits: bits))")
            parts.append("upload \(Format.rate(engine.network.bytesOutPerSecond, bits: bits))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Layout

    /// Builds only the pieces the style shows; traces copy and scale history.
    private static func pieces(for style: DisplayStyle, text: () -> Piece, trace: () -> Piece) -> [Piece] {
        switch style {
        case .text: [text()]
        case .trace: [trace()]
        case .textAndTrace: [trace(), text()]
        }
    }

    // Segment widths that never change, measured once.
    private static let percentWidth = max(stackedWidth(caption: "CPU", widest: "100%"), stackedWidth(caption: "MEM", widest: "100%"))
    private static let networkWidth = textWidth("↑ " + String(repeating: "8", count: rateChars), font: networkFont)

    private static func width(of piece: Piece) -> CGFloat {
        switch piece {
        case let .stacked(_, _, width), let .network(_, _, width): width
        case .trace: traceWidth
        }
    }

    private static func stackedWidth(caption: String, widest: String) -> CGFloat {
        ceil(max(textWidth(caption, font: captionFont), textWidth(widest, font: valueFont)))
    }

    private static var widthCache: [String: CGFloat] = [:]

    private static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(string)"
        if let cached = widthCache[key] { return cached }
        let width = ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
        widthCache[key] = width
        return width
    }

    /// Rounds trace values to the trace's pixel grid so sub-pixel jitter doesn't force a redraw.
    private static func quantized(_ values: [Double]) -> [Double] {
        values.map { ($0 * 32).rounded() / 32 }
    }

    /// `"12.4G"` → `"88.8G"`: the widest string with the same shape.
    private static func digitTemplate(_ string: String) -> String {
        String(string.map { $0.isNumber ? "8" : $0 })
    }

    // MARK: - Drawing

    private static let captionFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let networkFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

    /// A bitmap drawn into on alternate ticks. Its CTM is flipped so y grows
    /// downward, like AppKit views. flatline owns the pixels so text can be
    /// copied straight in, and images are made from the same memory without a
    /// copy. Two canvases alternate: Core Animation copies an image's pixels
    /// when it commits the layer, so a canvas is free again two ticks later.
    private final class Canvas {
        let context: CGContext
        let buffer: UnsafeMutableRawPointer
        /// Owns `buffer`: frees it once the canvas and every image made from
        /// it are gone, so a resize can't free pixels an image still uses.
        let provider: CGDataProvider

        init?(pixelWidth: Int, pixelHeight: Int, scale: CGFloat, height: CGFloat) {
            let bytesPerRow = pixelWidth * 4
            let size = bytesPerRow * pixelHeight
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }) else {
                buffer.deallocate()
                return nil
            }
            guard let context = CGContext(
                data: buffer, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: 0, y: -height)
            self.context = context
            self.buffer = buffer
            self.provider = provider
        }

        func clear() {
            memset(buffer, 0, context.bytesPerRow * context.height)
        }

        /// Wraps the current pixels without copying them.
        func image() -> CGImage? {
            CGImage(
                width: context.width, height: context.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: context.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    private static var canvases: [Canvas] = []
    private static var nextCanvas = 0
    /// The canvas being drawn this tick; text is copied into its buffer.
    private static var drawingCanvas: Canvas?

    private static func canvas(size: CGSize, scale: CGFloat) -> Canvas? {
        let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
        if canvases.first.map({ $0.context.width != pixelWidth || $0.context.height != pixelHeight }) ?? true {
            canvases = (0..<2).compactMap { _ in Canvas(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, height: size.height) }
            guard canvases.count == 2 else { canvases = []; return nil }
        }
        nextCanvas = (nextCanvas + 1) % canvases.count
        return canvases[nextCanvas]
    }

    /// Label colors resolved for one appearance, plus that appearance's text images.
    private struct Ink {
        var key: String
        var text: CGColor
        var caption: CGColor
        var baseline: CGColor
        var secondary: CGColor
    }

    private static var currentInk: Ink?

    private static func colors(for appearance: NSAppearance, scale: CGFloat) -> Ink {
        let key = "\(appearance.name.rawValue)@\(scale)"
        if let currentInk, currentInk.key == key { return currentInk }
        var ink: Ink!
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            ink = Ink(
                key: key,
                text: label.cgColor,
                caption: label.withAlphaComponent(0.7).cgColor,
                baseline: label.withAlphaComponent(0.25).cgColor,
                secondary: label.withAlphaComponent(0.45).cgColor
            )
        }
        currentInk = ink
        glyphCells.removeAll()
        return ink
    }

    private static func draw(_ piece: Piece, at x: CGFloat, height: CGFloat, ink: Ink, in context: CGContext) {
        let mid = height / 2
        switch piece {
        case let .stacked(caption, value, width):
            drawText(caption, font: captionFont, color: ink.caption, centeredIn: width, x: x, y: mid - 11, in: context)
            drawText(value, font: valueFont, color: ink.text, centeredIn: width, x: x, y: mid - 2.5, in: context)

        case let .network(up, down, width):
            drawText(up, font: networkFont, color: ink.text, centeredIn: width, x: x, y: mid - 11, in: context)
            drawText(down, font: networkFont, color: ink.text, centeredIn: width, x: x, y: mid - 0.5, in: context)

        case let .trace(primary, secondary):
            let rect = CGRect(x: x, y: mid - 8, width: traceWidth, height: 16)
            context.setFillColor(ink.baseline)
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5))
            if let secondary { stroke(secondary, in: rect, color: ink.secondary, context: context) }
            stroke(primary, in: rect, color: ink.text, context: context)
        }
    }

    // MARK: Text
    //
    // Every menu bar font is monospaced, so a string is a row of equal cells.
    // Each character is rasterized once per font, color and scale; drawing a
    // string copies those cells into the canvas buffer. About 30 distinct
    // characters cover everything flatline shows, so after the first few ticks
    // drawing text never touches CoreText. (Caching whole strings missed on most
    // network rates, and each miss cost ~140 µs on an idle, clocked-down core.)

    private struct GlyphKey: Hashable {
        let fontSize: CGFloat
        let alpha: CGFloat
        let character: Character
    }

    /// Premultiplied RGBA pixels, top row first, `padding` px of margin each side
    /// so glyphs that overhang their advance aren't clipped. `ink` is the
    /// bounding box of non-transparent pixels; only that part is copied.
    private struct GlyphCell {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let ink: (columns: Range<Int>, rows: Range<Int>)
    }

    private static let padding = 2
    private static var glyphCells: [GlyphKey: GlyphCell] = [:]
    private static var advances: [CGFloat: CGFloat] = [:]

    private static func advance(of font: NSFont) -> CGFloat {
        if let cached = advances[font.pointSize] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        advances[font.pointSize] = advance
        return advance
    }

    /// Draws `string` with its line box's top edge at `y`, centered in `width`.
    private static func drawText(_ string: String, font: NSFont, color: CGColor, centeredIn width: CGFloat, x: CGFloat, y: CGFloat, in context: CGContext) {
        guard let buffer = drawingCanvas?.buffer else { return }
        let scale = context.ctm.a
        let advance = advance(of: font)
        let characters = Array(string)
        let start = x + (width - advance * CGFloat(characters.count)) / 2
        let top = Int((y * scale).rounded())
        let canvasWidth = context.width, canvasHeight = context.height, bytesPerRow = context.bytesPerRow
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)

        for (index, character) in characters.enumerated() where character != " " {
            let key = GlyphKey(fontSize: font.pointSize, alpha: color.alpha, character: character)
            let cell: GlyphCell
            if let cached = glyphCells[key] {
                cell = cached
            } else {
                guard let rendered = renderGlyph(character, font: font, color: color, advance: advance, scale: scale) else { continue }
                glyphCells[key] = rendered
                cell = rendered
            }
            let left = Int(((start + advance * CGFloat(index)) * scale).rounded()) - padding
            let firstColumn = max(cell.ink.columns.lowerBound, -left)
            let lastColumn = min(cell.ink.columns.upperBound, canvasWidth - left)
            let firstRow = max(cell.ink.rows.lowerBound, -top)
            let lastRow = min(cell.ink.rows.upperBound, canvasHeight - top)
            guard firstColumn < lastColumn, firstRow < lastRow else { continue }
            // Composite with a per-byte max: neighboring cells can overlap at
            // their edges, and two same-colored glyphs over a cleared canvas
            // merge correctly that way. 16 bytes at a time, then the remainder.
            let spanBytes = (lastColumn - firstColumn) * 4
            cell.pixels.withUnsafeBytes { source in
                for row in firstRow..<lastRow {
                    let destination = UnsafeMutableRawPointer(pixels + (top + row) * bytesPerRow + (left + firstColumn) * 4)
                    let sourceRow = source.baseAddress! + (row * cell.width + firstColumn) * 4
                    var byte = 0
                    while byte + 16 <= spanBytes {
                        let merged = pointwiseMax(
                            destination.loadUnaligned(fromByteOffset: byte, as: SIMD16<UInt8>.self),
                            sourceRow.loadUnaligned(fromByteOffset: byte, as: SIMD16<UInt8>.self)
                        )
                        destination.storeBytes(of: merged, toByteOffset: byte, as: SIMD16<UInt8>.self)
                        byte += 16
                    }
                    while byte < spanBytes {
                        let value = sourceRow.load(fromByteOffset: byte, as: UInt8.self)
                        if value > destination.load(fromByteOffset: byte, as: UInt8.self) {
                            destination.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
                        }
                        byte += 1
                    }
                }
            }
        }
    }

    /// Rasterizes one character into a cell whose top edge is the font's line
    /// top, matching where NSString drawing places text.
    private static func renderGlyph(_ character: Character, font: NSFont, color: CGColor, advance: CGFloat, scale: CGFloat) -> GlyphCell? {
        let width = Int(ceil(advance * scale)) + 2 * padding
        let lineHeight = font.ascender - font.descender + font.leading
        let height = Int(ceil(lineHeight * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        let attributed = NSAttributedString(string: String(character), attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        context.textPosition = CGPoint(x: CGFloat(padding) / scale, y: CGFloat(height) / scale - font.ascender)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        // Ink bounds: rows and columns with any non-zero alpha.
        var minColumn = width, maxColumn = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where bytes[(row * width + column) * 4 + 3] != 0 {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        let ink = maxColumn < 0 ? (0..<0, 0..<0) : (minColumn..<maxColumn + 1, minRow..<maxRow + 1)
        return GlyphCell(pixels: bytes, width: width, height: height, ink: ink)
    }

    private static func stroke(_ values: [Double], in rect: CGRect, color: CGColor, context: CGContext) {
        guard values.count > 1 else { return }
        let step = rect.width / CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - 0.75 - CGFloat(max(0, min(1, value))) * (rect.height - 1.5))
        }
        context.beginPath()
        context.addLines(between: points)
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.strokePath()
    }
}
