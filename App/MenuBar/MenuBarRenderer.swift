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
            let text = Piece.stacked(
                caption: "CPU",
                value: Format.percent(engine.cpu.total).leftPadded(to: 4),
                width: stackedWidth(caption: "CPU", widest: "100%")
            )
            let trace = Piece.trace(primary: quantized(engine.cpuHistory.suffix(Int(traceWidth))), secondary: nil)
            groups.append(pieces(for: preferences.cpuStyle, text: text, trace: trace))
        }

        if preferences.showMemory {
            let memory = engine.memory
            let (value, widest) = switch preferences.memoryDisplay {
            case .percent: (Format.percent(memory.usedFraction).leftPadded(to: 4), "100%")
            case .gigabytes: (Format.gigabytesCompact(memory.used), digitTemplate(Format.gigabytesCompact(memory.physical)))
            }
            let text = Piece.stacked(caption: "MEM", value: value.leftPadded(to: widest.count), width: stackedWidth(caption: "MEM", widest: widest))
            let trace = Piece.trace(primary: quantized(engine.memoryHistory.suffix(Int(traceWidth))), secondary: nil)
            groups.append(pieces(for: preferences.memoryStyle, text: text, trace: trace))
        }

        if preferences.showNetwork {
            let bits = preferences.networkUnit == .bits
            let text = Piece.network(
                up: "↑ " + Format.rate(engine.network.bytesOutPerSecond, bits: bits).leftPadded(to: rateChars),
                down: "↓ " + Format.rate(engine.network.bytesInPerSecond, bits: bits).leftPadded(to: rateChars),
                width: textWidth("↑ " + String(repeating: "8", count: rateChars), font: networkFont)
            )
            let down = engine.networkInHistory.suffix(Int(traceWidth))
            let up = engine.networkOutHistory.suffix(Int(traceWidth))
            // Scale to the window's peak, but never below 10 KB/s so idle chatter stays flat.
            let peak = max(10_000, down.max() ?? 0, up.max() ?? 0)
            let trace = Piece.trace(primary: quantized(down.map { $0 / peak }), secondary: quantized(up.map { $0 / peak }))
            groups.append(pieces(for: preferences.networkStyle, text: text, trace: trace))
        }
        return Layout(groups: groups)
    }

    /// Renders `layout` at `scale` pixels per point, in the menu bar's own label
    /// color (resolved for `appearance`) so it can go straight into a layer.
    static func image(for layout: Layout, appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        let groups = layout.groups
        let widths = groups.map { group in
            group.map(width(of:)).reduce(0, +) + innerGap * CGFloat(max(0, group.count - 1))
        }
        let totalWidth = ceil(widths.reduce(0, +) + gap * CGFloat(max(0, groups.count - 1)))
        let height = NSStatusBar.system.thickness

        let size = NSSize(width: max(totalWidth, 1), height: height)

        // Rasterize here rather than handing AppKit a drawing-handler image: the
        // status bar's stylized drawing path crashes CoreText on macOS 27 when
        // it lays out text inside a handler.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.scaleBy(x: scale, y: -scale)
        context.cgContext.translateBy(x: 0, y: -size.height)
        // Resolves labelColor for the menu bar's current light/dark appearance.
        appearance.performAsCurrentDrawingAppearance {
            var x: CGFloat = 0
            for group in groups {
                for (index, piece) in group.enumerated() {
                    if index > 0 { x += innerGap }
                    draw(piece, at: x, height: height)
                    x += width(of: piece)
                }
                x += gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.cgImage
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

    private static func pieces(for style: DisplayStyle, text: Piece, trace: Piece) -> [Piece] {
        switch style {
        case .text: [text]
        case .trace: [trace]
        case .textAndTrace: [trace, text]
        }
    }

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

    private static func draw(_ piece: Piece, at x: CGFloat, height: CGFloat) {
        let mid = height / 2
        switch piece {
        case let .stacked(caption, value, width):
            drawText(caption, font: captionFont, color: NSColor.labelColor.withAlphaComponent(0.7), centeredIn: width, x: x, y: mid - 11)
            drawText(value, font: valueFont, color: .labelColor, centeredIn: width, x: x, y: mid - 2.5)

        case let .network(up, down, width):
            let font = networkFont
            let ink = NSColor.labelColor
            drawText(up, font: font, color: ink, centeredIn: width, x: x, y: mid - 11)
            drawText(down, font: font, color: ink, centeredIn: width, x: x, y: mid - 0.5)

        case let .trace(primary, secondary):
            let rect = NSRect(x: x, y: mid - 8, width: traceWidth, height: 16)
            let ink = NSColor.labelColor

            ink.withAlphaComponent(0.25).setFill()
            NSRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5).fill()

            if let secondary { stroke(secondary, in: rect, color: ink.withAlphaComponent(0.45)) }
            stroke(primary, in: rect, color: ink)
        }
    }

    /// Laid-out lines keyed by font size and text. The same few dozen strings
    /// ("23%", "1.2 MB/s", …) recur constantly, and layout is the expensive part
    /// of drawing text. Lines take their color from the context, so one entry
    /// serves both light and dark menu bars.
    private static var lineCache: [String: (line: CTLine, width: CGFloat)] = [:]

    private static func line(_ string: String, font: NSFont) -> (line: CTLine, width: CGFloat) {
        let key = "\(font.pointSize)|\(string)"
        if let cached = lineCache[key] { return cached }
        if lineCache.count >= 512 { lineCache.removeAll(keepingCapacity: true) }
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let entry = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        lineCache[key] = entry
        return entry
    }

    /// Draws `string` with its line box's top edge at `y`.
    private static func drawText(_ string: String, font: NSFont, color: NSColor, centeredIn width: CGFloat, x: CGFloat, y: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let (line, lineWidth) = line(string, font: font)
        context.saveGState()
        context.setFillColor(color.cgColor)
        // The context is flipped; flip glyphs back upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x + (width - lineWidth) / 2, y: y + font.ascender)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func stroke(_ values: [Double], in rect: NSRect, color: NSColor) {
        guard values.count > 1 else { return }
        let step = rect.width / CGFloat(values.count - 1)
        let path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let point = NSPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - 0.75 - CGFloat(max(0, min(1, value))) * (rect.height - 1.5)
            )
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = 1.25
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}
