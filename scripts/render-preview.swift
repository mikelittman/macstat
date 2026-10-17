import AppKit
import Foundation

/// Rasterize `macstat --preview` into a PNG. The frame is the built-in fixture.

struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
}

struct Cell {
    var character: Character = " "
    var foreground = RGB(r: 205 / 255, g: 214 / 255, b: 228 / 255)
    var background: RGB?
    var bold = false
}

let terminalBackground = RGB(r: 30 / 255, g: 30 / 255, b: 46 / 255)
let columns = 120
let rows = 40

func parse(_ text: String) -> [[Cell]] {
    var grid = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
    var row = 0
    var column = 0
    var foreground = Cell().foreground
    var background: RGB?
    var bold = false
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if character == "\u{1b}", index + 1 < characters.count, characters[index + 1] == "[" {
            var cursor = index + 2
            while cursor < characters.count, !"ABCDEFGHJKSTfhlmnsu@".contains(characters[cursor]) {
                cursor += 1
            }
            if cursor >= characters.count { break }
            let command = characters[cursor]
            let params = String(characters[(index + 2)..<cursor])
            if command == "H" || command == "f" {
                let parts = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 1 }
                row = max(0, (parts.first ?? 1) - 1)
                column = max(0, (parts.count > 1 ? parts[1] : 1) - 1)
            } else if command == "m" {
                applySGR(params, foreground: &foreground, background: &background, bold: &bold)
            }
            index = cursor + 1
            continue
        }
        if row < rows, column < columns {
            grid[row][column] = Cell(character: character, foreground: foreground, background: background, bold: bold)
        }
        if character != "\n", character != "\r" { column += 1 }
        index += 1
    }
    return grid
}

func applySGR(_ params: String, foreground: inout RGB, background: inout RGB?, bold: inout Bool) {
    let parts = params.split(separator: ";").map { Int($0) ?? 0 }
    var index = 0
    while index < parts.count {
        let code = parts[index]
        if code == 0 {
            foreground = Cell().foreground
            background = nil
            bold = false
        } else if code == 1 {
            bold = true
        } else if code == 38, index + 4 < parts.count, parts[index + 1] == 2 {
            foreground = RGB(
                r: CGFloat(parts[index + 2]) / 255,
                g: CGFloat(parts[index + 3]) / 255,
                b: CGFloat(parts[index + 4]) / 255
            )
            index += 4
        } else if code == 48, index + 4 < parts.count, parts[index + 1] == 2 {
            background = RGB(
                r: CGFloat(parts[index + 2]) / 255,
                g: CGFloat(parts[index + 3]) / 255,
                b: CGFloat(parts[index + 4]) / 255
            )
            index += 4
        }
        index += 1
    }
}

func color(_ value: RGB) -> NSColor {
    NSColor(srgbRed: value.r, green: value.g, blue: value.b, alpha: 1)
}

func render(_ grid: [[Cell]], to url: URL) throws {
    let regular = NSFont(name: "SFMono-Regular", size: 16) ?? NSFont(name: "Menlo", size: 16)!
    let heavy = NSFont(name: "SFMono-Bold", size: 16) ?? NSFont(name: "Menlo-Bold", size: 16) ?? regular
    let cellWidth = ceil(regular.maximumAdvancement.width)
    let cellHeight = ceil(regular.ascender - regular.descender)
    let padding: CGFloat = 22
    let points = NSSize(
        width: padding * 2 + cellWidth * CGFloat(columns),
        height: padding * 2 + cellHeight * CGFloat(rows)
    )
    let scale: CGFloat = 2
    guard let context = CGContext(
        data: nil,
        width: Int(points.width * scale),
        height: Int(points.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "macstat", code: 1)
    }
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(true)
    context.interpolationQuality = .high
    context.setFillColor(color(terminalBackground).cgColor)
    context.fill(CGRect(origin: .zero, size: points))

    for row in 0..<rows {
        for column in 0..<columns {
            let cell = grid[row][column]
            let rect = CGRect(
                x: padding + CGFloat(column) * cellWidth,
                y: points.height - padding - CGFloat(row + 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            if let background = cell.background {
                context.setFillColor(color(background).cgColor)
                context.fill(rect)
            }
            guard cell.character != " " else { continue }
            let font = cell.bold ? heavy : regular
            let text = NSAttributedString(string: String(cell.character), attributes: [
                .font: font,
                .foregroundColor: color(cell.foreground),
            ])
            let line = CTLineCreateWithAttributedString(text)
            context.saveGState()
            context.clip(to: rect)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY - font.descender)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
    guard let image = context.makeImage() else {
        throw NSError(domain: "macstat", code: 3)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "macstat", code: 4)
    }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fputs("usage: render-preview <macstat> <dashboard.png> <help.png>\n", stderr)
    exit(1)
}

func capture(_ binary: String, help: Bool) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [help ? "--preview-help" : "--preview"]
    var environment = ProcessInfo.processInfo.environment
    environment["MACSTAT_THEME"] = "dark"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: data, as: UTF8.self)
}

let binary = arguments[1]
let dashboard = try capture(binary, help: false)
let help = try capture(binary, help: true)
try render(parse(dashboard), to: URL(fileURLWithPath: arguments[2]))
try render(parse(help), to: URL(fileURLWithPath: arguments[3]))
fputs("wrote \(arguments[2])\nwrote \(arguments[3])\n", stderr)
