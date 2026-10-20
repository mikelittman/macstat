import Foundation

struct RGB: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

struct Palette: Sendable {
    var text: RGB
    var dim: RGB
    var border: RGB
    var accent: RGB
    var green: RGB
    var yellow: RGB
    var orange: RGB
    var red: RGB
    var purple: RGB
    var cyan: RGB
    var pink: RGB
    var selected: RGB

    static let dark = Palette(
        text: RGB(r: 205, g: 214, b: 228),
        dim: RGB(r: 108, g: 112, b: 134),
        border: RGB(r: 88, g: 91, b: 112),
        accent: RGB(r: 137, g: 180, b: 250),
        green: RGB(r: 166, g: 227, b: 161),
        yellow: RGB(r: 249, g: 226, b: 175),
        orange: RGB(r: 250, g: 179, b: 135),
        red: RGB(r: 243, g: 139, b: 168),
        purple: RGB(r: 203, g: 166, b: 247),
        cyan: RGB(r: 137, g: 220, b: 235),
        pink: RGB(r: 245, g: 194, b: 231),
        selected: RGB(r: 49, g: 50, b: 68)
    )

    static let light = Palette(
        text: RGB(r: 36, g: 39, b: 58),
        dim: RGB(r: 108, g: 112, b: 134),
        border: RGB(r: 140, g: 143, b: 161),
        accent: RGB(r: 30, g: 102, b: 245),
        green: RGB(r: 40, g: 130, b: 55),
        yellow: RGB(r: 150, g: 100, b: 0),
        orange: RGB(r: 180, g: 80, b: 10),
        red: RGB(r: 175, g: 30, b: 60),
        purple: RGB(r: 120, g: 50, b: 190),
        cyan: RGB(r: 8, g: 120, b: 140),
        pink: RGB(r: 160, g: 60, b: 130),
        selected: RGB(r: 220, g: 224, b: 232)
    )

    static func resolve() -> Palette {
        let choice = ProcessInfo.processInfo.environment["MACSTAT_THEME"]?.lowercased()
        if choice == "light" { return .light }
        if choice == "dark" { return .dark }
        if let fgbg = ProcessInfo.processInfo.environment["COLORFGBG"] {
            let bg = fgbg.split(separator: ";").last
            if bg == "7" || bg == "15" { return .light }
        }
        return .dark
    }
}

func meterColor(_ fraction: Double, _ palette: Palette) -> RGB {
    let value = min(max(fraction, 0), 1)
    if value < 0.5 { return palette.green }
    if value < 0.75 { return palette.yellow }
    if value < 0.9 { return palette.orange }
    return palette.red
}

func temperatureColor(_ celsius: Double, _ palette: Palette) -> RGB {
    if celsius < 55 { return palette.green }
    if celsius < 75 { return palette.yellow }
    if celsius < 90 { return palette.orange }
    return palette.red
}

func fit(_ text: String, width: Int) -> String {
    if width <= 0 { return "" }
    if text.count <= width { return text }
    if width == 1 { return "…" }
    return String(text.prefix(width - 1)) + "…"
}

func padLeft(_ text: String, width: Int) -> String {
    if text.count >= width { return fit(text, width: width) }
    return String(repeating: " ", count: width - text.count) + text
}

func padRight(_ text: String, width: Int) -> String {
    if text.count >= width { return fit(text, width: width) }
    return text + String(repeating: " ", count: width - text.count)
}

func spread(left: String, right: String, width: Int) -> String {
    if width <= 0 { return "" }
    if right.isEmpty { return fit(left, width: width) }
    if left.isEmpty { return padLeft(fit(right, width: width), width: width) }
    let gap = width - left.count - right.count
    if gap >= 1 {
        return left + String(repeating: " ", count: gap) + right
    }
    let room = width - min(right.count, width)
    if room <= 0 { return fit(right, width: width) }
    let trimmedRight = fit(right, width: width - room)
    let trimmedLeft = fit(left, width: max(0, width - trimmedRight.count - 1))
    if trimmedLeft.isEmpty { return padLeft(trimmedRight, width: width) }
    let filler = width - trimmedLeft.count - trimmedRight.count
    return trimmedLeft + String(repeating: " ", count: max(1, filler)) + trimmedRight
}

func formatBytes(_ bytes: Double) -> String {
    let sign = bytes < 0 ? "-" : ""
    var value = abs(bytes)
    let units = ["B", "K", "M", "G", "T", "P"]
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    let number: String
    if index == 0 {
        number = String(Int(value))
    } else if value >= 100 {
        number = String(format: "%.0f", value)
    } else if value >= 10 {
        number = String(format: "%.1f", value)
    } else {
        number = String(format: "%.2f", value)
    }
    return sign + number + units[index]
}

func formatRate(_ bytesPerSecond: Double) -> String {
    formatBytes(bytesPerSecond) + "/s"
}

func formatWatts(_ watts: Double) -> String {
    if watts >= 100 { return String(format: "%.0fW", watts) }
    return String(format: "%.1fW", watts)
}

func formatPercent(_ fraction: Double, decimals: Int = 1) -> String {
    let clamped = min(max(fraction, 0), 9.99)
    return String(format: "%.\(decimals)f%%", clamped * 100)
}

func formatUptime(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

func formatDuration(minutes: Int) -> String {
    if minutes < 0 { return "calculating" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

func fahrenheit(from celsius: Double) -> Double {
    celsius * 9 / 5 + 32
}

func formatTemperature(_ celsius: Double) -> String {
    String(format: "%.1f°F", fahrenheit(from: celsius))
}

enum SensorGroup: String, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "MEM"
    case skin = "SKIN"
    case battery = "BATT"
    case ambient = "AIR"
    case storage = "DISK"
    case power = "VRM"
    case other = "OTHER"
}

func sensorGroup(for key: String) -> SensorGroup {
    if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TC") { return .cpu }
    if key.hasPrefix("Tg") || key.hasPrefix("TG") { return .gpu }
    if key.hasPrefix("Tm") || key.hasPrefix("TM") { return .memory }
    if key.hasPrefix("Ts") || key.hasPrefix("TS") { return .skin }
    if key.hasPrefix("TB") || key.hasPrefix("Tb") { return .battery }
    if key.hasPrefix("Ta") || key.hasPrefix("TA") { return .ambient }
    if key.hasPrefix("TH") { return .storage }
    if key.hasPrefix("TV") || key.hasPrefix("Tv") { return .power }
    return .other
}

func isCoreTemperatureKey(_ key: String) -> Bool {
    key.hasPrefix("Tp") || key.hasPrefix("Te")
}
