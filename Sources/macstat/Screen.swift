import Foundation

struct Style: Equatable {
    var foreground: RGB
    var background: RGB?
    var bold: Bool

    init(_ foreground: RGB, background: RGB? = nil, bold: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
    }
}

struct Rect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var right: Int { x + width }
    var bottom: Int { y + height }

    func contains(column: Int, row: Int) -> Bool {
        column >= x && row >= y && column < right && row < bottom
    }

    var inset: Rect {
        Rect(x: x + 1, y: y + 1, width: max(0, width - 2), height: max(0, height - 2))
    }
}

final class Screen {
    let columns: Int
    let rows: Int
    private var characters: [Character]
    private var styles: [Style]
    private let blank: Style

    init(columns: Int, rows: Int, palette: Palette) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        blank = Style(palette.text)
        let count = self.columns * self.rows
        characters = Array(repeating: " ", count: count)
        styles = Array(repeating: blank, count: count)
    }

    func clear() {
        for index in characters.indices {
            characters[index] = " "
            styles[index] = blank
        }
    }

    func write(_ text: String, x: Int, y: Int, style: Style, clip: Rect? = nil) {
        var column = x
        for character in text {
            if let clip, !clip.contains(column: column, row: y) {
                column += 1
                continue
            }
            put(character, x: column, y: y, style: style)
            column += 1
        }
    }

    func put(_ character: Character, x: Int, y: Int, style: Style) {
        guard x >= 0, y >= 0, x < columns, y < rows else { return }
        let index = y * columns + x
        characters[index] = character
        styles[index] = style
    }

    func render() -> String {
        var output = ""
        output.reserveCapacity(rows * columns * 3)
        var active: Style?
        for row in 0..<rows {
            output += "\u{1b}[\(row + 1);1H"
            for column in 0..<columns {
                let index = row * columns + column
                let style = styles[index]
                if style != active {
                    output += sgr(style)
                    active = style
                }
                output.append(characters[index])
            }
        }
        output += "\u{1b}[0m\u{1b}[H"
        return output
    }

    private func sgr(_ style: Style) -> String {
        var parts = ["0"]
        if style.bold { parts.append("1") }
        parts.append("38;2;\(style.foreground.r);\(style.foreground.g);\(style.foreground.b)")
        if let background = style.background {
            parts.append("48;2;\(background.r);\(background.g);\(background.b)")
        }
        return "\u{1b}[" + parts.joined(separator: ";") + "m"
    }
}

struct Canvas {
    let screen: Screen
    let palette: Palette

    func text(_ value: String, x: Int, y: Int, color: RGB, bold: Bool = false, clip: Rect) {
        screen.write(value, x: x, y: y, style: Style(color, bold: bold), clip: clip)
    }

    func row(_ value: String, x: Int, y: Int, width: Int, color: RGB, bold: Bool = false, clip: Rect) {
        text(fit(value, width: width), x: x, y: y, color: color, bold: bold, clip: clip)
    }

    func box(_ rect: Rect, accent: RGB, title: String, trailing: String = "") -> Rect {
        let border = Style(palette.border)
        let width = rect.width
        let height = rect.height
        guard width >= 2, height >= 2 else { return rect.inset }
        screen.put("┌", x: rect.x, y: rect.y, style: border)
        screen.put("┐", x: rect.right - 1, y: rect.y, style: border)
        screen.put("└", x: rect.x, y: rect.bottom - 1, style: border)
        screen.put("┘", x: rect.right - 1, y: rect.bottom - 1, style: border)
        if width > 2 {
            for column in (rect.x + 1)..<(rect.right - 1) {
                screen.put("─", x: column, y: rect.y, style: border)
                screen.put("─", x: column, y: rect.bottom - 1, style: border)
            }
        }
        if height > 2 {
            for row in (rect.y + 1)..<(rect.bottom - 1) {
                screen.put("│", x: rect.x, y: row, style: border)
                screen.put("│", x: rect.right - 1, y: row, style: border)
            }
        }

        var column = rect.x + 1
        func piece(_ value: String, color: RGB, bold: Bool) {
            for character in value {
                guard column < rect.right - 1 else { return }
                screen.put(character, x: column, y: rect.y, style: Style(color, bold: bold))
                column += 1
            }
        }
        if !title.isEmpty, width > 6 {
            piece("─ ", color: palette.border, bold: false)
            piece(title, color: accent, bold: true)
            if !trailing.isEmpty, column + trailing.count + 2 < rect.right - 1 {
                piece(" ", color: palette.border, bold: false)
                piece(trailing, color: palette.text, bold: false)
            }
            if column < rect.right - 1 {
                piece(" ", color: palette.border, bold: false)
            }
        }
        return rect.inset
    }

    func bar(x: Int, y: Int, width: Int, fraction: Double, clip: Rect, color: RGB? = nil) {
        guard width > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let fill = color ?? meterColor(clamped, palette)
        let exact = clamped * Double(width)
        let full = Int(exact)
        let partialIndex = Int((exact - Double(full)) * 8)
        let partials: [Character] = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        for column in 0..<width {
            let character: Character
            let style: Style
            if column < full {
                character = "█"
                style = Style(fill)
            } else if column == full, partialIndex > 0 {
                character = partials[partialIndex]
                style = Style(fill)
            } else {
                character = "░"
                style = Style(palette.dim)
            }
            let pointX = x + column
            guard clip.contains(column: pointX, row: y) else { continue }
            screen.put(character, x: pointX, y: y, style: style)
        }
    }

    /// A column graph. Each sample is one column, drawn upward with block characters.
    func histogram(
        values: [Double],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        clip: Rect,
        floor: Double,
        ceiling: Double,
        color: (Double) -> RGB
    ) {
        guard width > 0, height > 0 else { return }
        let blocks: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let series = Array(values.suffix(width))
        let pad = width - series.count
        let span = max(ceiling - floor, 0.000_1)
        let levels = height * 8
        for column in 0..<width {
            let sample = column < pad ? floor : series[column - pad]
            let fraction = min(max((sample - floor) / span, 0), 1)
            var eighths = Int((fraction * Double(levels)).rounded())
            if fraction > 0, eighths == 0 { eighths = 1 }
            guard eighths > 0 else { continue }
            let ink = color(fraction)
            for line in 0..<height {
                let fromBottom = height - 1 - line
                let cell = eighths - fromBottom * 8
                let index = cell >= 8 ? 8 : max(cell, 0)
                guard index > 0 else { continue }
                let pointX = x + column
                let pointY = y + line
                guard clip.contains(column: pointX, row: pointY) else { continue }
                screen.put(blocks[index], x: pointX, y: pointY, style: Style(ink))
            }
        }
    }
}
