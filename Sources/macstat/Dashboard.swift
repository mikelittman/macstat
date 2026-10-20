import Foundation

enum ProcessSort: Equatable {
    case cpu
    case memory
    case name
    case pid
}

struct UIState {
    var sort = ProcessSort.cpu
    var descending = true
    var selectedPID: Int32?
    var scroll = 0
    var paused = false
    var help = false
    var filter = ""
    var editingFilter = false
    var interval = 1.0
}

struct History {
    var cpu: [Double] = []
    var memory: [Double] = []
    var temperature: [Double] = []
    var networkIn: [Double] = []
    var networkOut: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []

    mutating func add(_ snapshot: Snapshot) {
        append(&cpu, snapshot.cpu.total)
        append(&memory, snapshot.memory.usedFraction)
        if let temperature = snapshot.thermal.cpuAverage ?? snapshot.thermal.peak?.celsius {
            append(&self.temperature, temperature)
        }
        if let value = snapshot.network.bytesInPerSecond { append(&networkIn, value) }
        if let value = snapshot.network.bytesOutPerSecond { append(&networkOut, value) }
        if let value = snapshot.disk.readPerSecond { append(&diskRead, value) }
        if let value = snapshot.disk.writePerSecond { append(&diskWrite, value) }
    }
}

/// Rows reserved for the CPU history graph. Memory and sensors use the space they have left.
private let historyRows = 4

private func append(_ series: inout [Double], _ value: Double) {
    series.append(value)
    if series.count > 300 {
        series.removeFirst(series.count - 300)
    }
}

struct Layout {
    var cpu: Rect
    var memory: Rect
    var thermal: Rect
    var network: Rect
    var disk: Rect?
    var power: Rect?
    var processes: Rect
}

func layout(columns: Int, rows: Int, coreCount: Int, clusterCount: Int) -> Layout? {
    let footer = 1
    let minimumTop = 7
    let minimumMiddle = 6
    let minimumProcesses = 6
    guard columns >= 70, rows >= minimumTop + minimumMiddle + minimumProcesses + footer else {
        return nil
    }
    let usable = rows - footer
    let left = min(max(42, columns * 58 / 100), columns - 28)
    // A power band needs two content rows. Shorter windows fold power into Sensors.
    let powerBand = usable >= 36 ? 4 : 0
    let coreColumns = max(1, (left - 2) / 16)
    let coreRows = coreCount > 0 ? (coreCount + coreColumns - 1) / coreColumns : 0
    let clusterTop = 2 + 2 + historyRows + max(clusterCount, 1)
    let coreTop = clusterTop + coreRows
    let topLimit = max(minimumTop, usable - minimumMiddle - powerBand - minimumProcesses)
    // A clamped box that cannot hold the core grid would just be empty rows.
    // Eight rows still leave room for the memory breakdown and the swap line.
    let fitted = coreRows > 0 && coreTop <= topLimit
        ? coreTop
        : min(max(minimumTop, clusterTop), topLimit)
    let top = min(topLimit, max(fitted, 8))
    // 13 rows splits the right column into a network box and a disk box.
    let preferredMiddle = usable >= 36 ? 13 : usable * 30 / 100
    var middle = max(minimumMiddle, min(13, preferredMiddle))
    var processes = usable - top - middle - powerBand
    if processes < minimumProcesses {
        middle = max(minimumMiddle, usable - top - powerBand - minimumProcesses)
        processes = usable - top - middle - powerBand
    }
    guard middle >= minimumMiddle, processes >= minimumProcesses else { return nil }
    let splitIO = middle >= 12
    let networkHeight = splitIO ? 6 : middle
    let disk = splitIO
        ? Rect(x: left, y: top + networkHeight, width: columns - left, height: middle - networkHeight)
        : nil
    let power = powerBand > 0
        ? Rect(x: 0, y: top + middle, width: columns, height: powerBand)
        : nil
    return Layout(
        cpu: Rect(x: 0, y: 0, width: left, height: top),
        memory: Rect(x: left, y: 0, width: columns - left, height: top),
        thermal: Rect(x: 0, y: top, width: left, height: middle),
        network: Rect(x: left, y: top, width: columns - left, height: networkHeight),
        disk: disk,
        power: power,
        processes: Rect(x: 0, y: top + middle + powerBand, width: columns, height: processes)
    )
}

func drawDashboard(
    snapshot: Snapshot,
    history: History,
    state: UIState,
    system: SystemInfo,
    columns: Int,
    rows: Int
) -> String {
    let palette = Palette.resolve()
    let screen = Screen(columns: columns, rows: rows, palette: palette)
    let canvas = Canvas(screen: screen, palette: palette)
    guard let layout = layout(
        columns: columns,
        rows: rows,
        coreCount: system.coreCount,
        clusterCount: system.clusters.count
    ) else {
        canvas.text(
            "macstat needs a terminal at least 70 columns by 20 rows",
            x: 1,
            y: 1,
            color: palette.text,
            clip: Rect(x: 0, y: 0, width: columns, height: rows)
        )
        return screen.render()
    }

    drawCPU(snapshot, history, system, layout.cpu, canvas)
    drawMemory(snapshot, history, layout.memory, canvas)
    drawThermal(snapshot, history, layout.thermal, canvas, embedPower: layout.power == nil)
    drawNetwork(snapshot, history, layout.network, canvas, includesDisk: layout.disk == nil)
    if let disk = layout.disk {
        drawDisk(snapshot, history, disk, canvas)
    }
    if let power = layout.power {
        drawPower(snapshot, power, canvas)
    }
    drawProcesses(snapshot, state, layout.processes, canvas)
    drawFooter(snapshot, state, rows - 1, columns, canvas)
    if state.help {
        drawHelp(columns: columns, rows: rows, canvas: canvas)
    }
    return screen.render()
}

private func drawCPU(_ snapshot: Snapshot, _ history: History, _ system: SystemInfo, _ rect: Rect, _ canvas: Canvas) {
    let cpu = snapshot.cpu
    let interior = canvas.box(
        rect,
        accent: canvas.palette.green,
        title: "CPU",
        trailing: formatPercent(cpu.total)
    )
    guard interior.height > 0, interior.width > 0 else { return }
    var row = interior.y
    let identity = [system.chip, system.coreCount > 0 ? "\(system.coreCount) cores" : nil, system.osVersion]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    let load = String(format: "%.2f %.2f %.2f", cpu.load.0, cpu.load.1, cpu.load.2)
    canvas.row(
        spread(left: identity, right: "load \(load)", width: interior.width),
        x: interior.x,
        y: row,
        width: interior.width,
        color: canvas.palette.text,
        clip: interior
    )
    row += 1
    guard row < interior.bottom else { return }

    let percent = formatPercent(cpu.total)
    var detailParts = [
        "user \(formatPercent(cpu.user))",
        "sys \(formatPercent(cpu.system))",
        "idle \(formatPercent(1 - cpu.total))",
    ]
    if let gpu = snapshot.gpu.device {
        detailParts.append("GPU \(formatPercent(gpu, decimals: 0))")
    }
    let minimumBar = 8
    while detailParts.count > 1 {
        let candidate = detailParts.joined(separator: "  ")
        if minimumBar + percent.count + candidate.count + 2 <= interior.width { break }
        detailParts.removeLast()
    }
    let detail = detailParts.joined(separator: "  ")
    let barWidth = max(minimumBar, interior.width - percent.count - detail.count - 2)
    canvas.bar(
        x: interior.x,
        y: row,
        width: barWidth,
        fraction: cpu.total,
        clip: interior
    )
    canvas.text(percent, x: interior.x + barWidth + 1, y: row, color: meterColor(cpu.total, canvas.palette), bold: true, clip: interior)
    let detailX = interior.x + barWidth + percent.count + 2
    if detailX < interior.right {
        canvas.text(detail, x: detailX, y: row, color: canvas.palette.dim, clip: interior)
    }
    row += 1
    guard row < interior.bottom else { return }
    let graph = cpuGraphRows(space: interior.bottom - row, clusters: cpu.clusters.count, cores: cpu.cores.count, width: interior.width)
    canvas.histogram(
        values: history.cpu,
        x: interior.x,
        y: row,
        width: interior.width,
        height: graph.height,
        clip: interior,
        floor: 0,
        ceiling: 1
    ) { meterColor($0, canvas.palette) }
    row += graph.height

    for cluster in cpu.clusters {
        guard row < interior.bottom else { return }
        let name = padRight(cluster.name, width: min(14, max(4, interior.width / 5)))
        let stats = "\(formatPercent(cluster.usage, decimals: 0))  \(cluster.coreCount)"
        let barWidth = max(0, interior.width - name.count - stats.count - 2)
        canvas.text(name, x: interior.x, y: row, color: canvas.palette.text, clip: interior)
        canvas.bar(x: interior.x + name.count + 1, y: row, width: barWidth, fraction: cluster.usage, clip: interior)
        canvas.text(
            stats,
            x: interior.x + name.count + 1 + barWidth + 1,
            y: row,
            color: meterColor(cluster.usage, canvas.palette),
            clip: interior
        )
        row += 1
    }

    guard graph.cores, !cpu.cores.isEmpty else { return }
    let remaining = interior.bottom - row
    let cellWidth = 16
    let columns = max(1, interior.width / cellWidth)
    let rowsNeeded = (cpu.cores.count + columns - 1) / columns
    let usedColumns = rowsNeeded <= remaining ? columns : 0
    guard usedColumns > 0 else { return }
    for (index, core) in cpu.cores.enumerated() {
        let column = index / rowsNeeded
        let line = index % rowsNeeded
        guard column < usedColumns else { continue }
        let x = interior.x + column * cellWidth
        let y = row + line
        let label = padRight(core.label, width: 4)
        let percent = padLeft(formatPercent(core.usage, decimals: 0), width: 4)
        canvas.text(label, x: x, y: y, color: canvas.palette.dim, clip: interior)
        canvas.text(percent, x: x + 4, y: y, color: meterColor(core.usage, canvas.palette), clip: interior)
        canvas.bar(x: x + 9, y: y, width: max(0, cellWidth - 10), fraction: core.usage, clip: interior)
    }
}

private struct CPUGraph {
    var height: Int
    var cores: Bool
}

/// Keep a few rows of history, and the per-core grid when both fit.
private func cpuGraphRows(space: Int, clusters: Int, cores: Int, width: Int) -> CPUGraph {
    guard space > 0 else { return CPUGraph(height: 0, cores: false) }
    let coreColumns = max(1, width / 16)
    let coreRows = cores > 0 ? (cores + coreColumns - 1) / coreColumns : 0
    let clusterRows = min(clusters, max(space - 1, 0))
    if coreRows > 0, historyRows + clusterRows + coreRows <= space {
        return CPUGraph(height: historyRows, cores: true)
    }
    if coreRows > 0 {
        let room = space - clusterRows - coreRows
        if room >= 2 { return CPUGraph(height: room, cores: true) }
    }
    return CPUGraph(height: min(historyRows, max(0, space - clusterRows)), cores: false)
}

private func drawMemory(_ snapshot: Snapshot, _ history: History, _ rect: Rect, _ canvas: Canvas) {
    let memory = snapshot.memory
    let interior = canvas.box(
        rect,
        accent: canvas.palette.purple,
        title: "Memory",
        trailing: formatPercent(memory.usedFraction, decimals: 0)
    )
    guard interior.height > 0 else { return }
    var row = interior.y
    let headline = "\(formatBytes(Double(memory.used))) / \(formatBytes(Double(memory.total)))"
    canvas.row(
        spread(left: headline, right: formatPercent(memory.usedFraction), width: interior.width),
        x: interior.x,
        y: row,
        width: interior.width,
        color: canvas.palette.text,
        bold: true,
        clip: interior
    )
    row += 1
    let barsAndSwap = 5
    let graph = min(6, max(0, interior.bottom - row - barsAndSwap))
    if graph > 0 {
        canvas.histogram(
            values: history.memory,
            x: interior.x,
            y: row,
            width: interior.width,
            height: graph,
            clip: interior,
            floor: 0,
            ceiling: 1
        ) { _ in canvas.palette.purple }
        row += graph
    }
    let lines: [(String, UInt64, RGB)] = [
        ("App", memory.app, canvas.palette.text),
        ("Wired", memory.wired, canvas.palette.text),
        ("Compressed", memory.compressed, canvas.palette.text),
        ("Cached", memory.cached, canvas.palette.dim),
    ]
    let labelWidth = 11
    for line in lines {
        guard row < interior.bottom else { return }
        canvas.text(padRight(line.0, width: labelWidth), x: interior.x, y: row, color: canvas.palette.dim, clip: interior)
        let value = formatBytes(Double(line.1))
        let barWidth = max(0, interior.width - labelWidth - value.count - 2)
        let fraction = memory.total == 0 ? 0 : Double(line.1) / Double(memory.total)
        canvas.bar(x: interior.x + labelWidth, y: row, width: barWidth, fraction: fraction, clip: interior, color: canvas.palette.purple)
        canvas.text(value, x: interior.x + labelWidth + barWidth + 1, y: row, color: line.2, clip: interior)
        row += 1
    }
    guard row < interior.bottom else { return }
    let swap = "Swap  \(formatBytes(Double(memory.swapUsed))) / \(formatBytes(Double(memory.swapTotal)))"
    let pressureColor: RGB
    switch memory.pressure {
    case "normal": pressureColor = canvas.palette.green
    case "warning": pressureColor = canvas.palette.yellow
    default: pressureColor = canvas.palette.red
    }
    canvas.row(
        spread(left: swap, right: memory.pressure, width: interior.width),
        x: interior.x,
        y: row,
        width: interior.width,
        color: canvas.palette.text,
        clip: interior
    )
    let pressureX = interior.x + interior.width - memory.pressure.count
    canvas.text(memory.pressure, x: pressureX, y: row, color: pressureColor, bold: true, clip: interior)
}

private func drawThermal(_ snapshot: Snapshot, _ history: History, _ rect: Rect, _ canvas: Canvas, embedPower: Bool) {
    let thermal = snapshot.thermal
    let trailing = thermal.cpuAverage.map { formatTemperature($0) } ?? thermal.state
    let interior = canvas.box(rect, accent: canvas.palette.orange, title: "Sensors", trailing: trailing)
    guard interior.height > 0 else { return }
    let extra = embedPower ? embeddedPowerLines(snapshot, width: interior.width) : []
    let reserved = min(extra.count, max(0, interior.height - 1))
    let sensorBottom = interior.bottom - reserved
    if !thermal.available {
        if interior.y < sensorBottom {
            canvas.row(
                "No temperature sensors from the SMC or HID",
                x: interior.x,
                y: interior.y,
                width: interior.width,
                color: canvas.palette.dim,
                clip: interior
            )
        }
    } else {
        var row = interior.y
        var summary: [String] = []
        if let average = thermal.cpuAverage {
            let peak = thermal.cpuPeak.map { " / \(formatTemperature($0))" } ?? ""
            summary.append("CPU \(formatTemperature(average))\(peak)")
        }
        if let average = thermal.gpuAverage {
            let peak = thermal.gpuPeak.map { " / \(formatTemperature($0))" } ?? ""
            summary.append("GPU \(formatTemperature(average))\(peak)")
        }
        if row < sensorBottom {
            canvas.row(summary.joined(separator: "   "), x: interior.x, y: row, width: interior.width, color: canvas.palette.text, bold: true, clip: interior)
            row += 1
        }

        if row < sensorBottom {
            var second: [String] = []
            if !thermal.fans.isEmpty {
                if thermal.fans.allSatisfy({ $0.rpm < 1 }) {
                    second.append(thermal.fans.count == 1 ? "Fan stopped" : "Fans stopped")
                } else {
                    let fans = thermal.fans.map { fan in
                        let speed = fan.rpm < 1 ? "stopped" : "\(Int(fan.rpm.rounded())) rpm"
                        return "\(fan.name) \(speed)"
                    }.joined(separator: "  ")
                    second.append(fans)
                }
            }
            second.append(thermal.state)
            let stateColor: RGB
            switch thermal.state {
            case "nominal": stateColor = canvas.palette.green
            case "fair": stateColor = canvas.palette.yellow
            case "serious", "critical": stateColor = canvas.palette.red
            default: stateColor = canvas.palette.dim
            }
            let line = second.joined(separator: "   ")
            canvas.row(line, x: interior.x, y: row, width: interior.width, color: canvas.palette.text, clip: interior)
            if let range = line.range(of: thermal.state, options: .backwards) {
                let prefix = line[..<range.lowerBound]
                canvas.text(thermal.state, x: interior.x + prefix.count, y: row, color: stateColor, bold: true, clip: interior)
            }
            row += 1
        }

        let room = sensorBottom - row
        let graph = room >= 6 ? 3 : (room >= 4 ? 2 : (room > 2 ? 1 : 0))
        if graph > 0, !history.temperature.isEmpty {
            canvas.histogram(
                values: history.temperature,
                x: interior.x,
                y: row,
                width: interior.width,
                height: graph,
                clip: interior,
                floor: 20,
                ceiling: 100
            ) { fraction in
                temperatureColor(20 + fraction * 80, canvas.palette)
            }
            row += graph
        }

        let zones = displayZones(thermal, limit: max(0, sensorBottom - row))
        let nameWidth = min(18, max(6, zones.map(\.key.count).max() ?? 6))
        for zone in zones {
            guard row < sensorBottom else { break }
            let name = padRight(fit(zone.key, width: nameWidth), width: nameWidth)
            let value = padLeft(formatTemperature(zone.celsius), width: 7)
            let group = zone.group.rawValue
            let barWidth = max(0, interior.width - nameWidth - value.count - group.count - 3)
            canvas.text(name, x: interior.x, y: row, color: canvas.palette.dim, clip: interior)
            canvas.text(value, x: interior.x + nameWidth + 1, y: row, color: temperatureColor(zone.celsius, canvas.palette), bold: true, clip: interior)
            canvas.bar(
                x: interior.x + nameWidth + value.count + 2,
                y: row,
                width: barWidth,
                fraction: min(max((zone.celsius - 20) / 80, 0), 1),
                clip: interior,
                color: temperatureColor(zone.celsius, canvas.palette)
            )
            canvas.text(group, x: interior.right - group.count, y: row, color: canvas.palette.dim, clip: interior)
            row += 1
        }
    }
    for (offset, line) in extra.prefix(reserved).enumerated() {
        let color = line.battery.map { batteryColor($0, canvas.palette) } ?? canvas.palette.text
        canvas.row(line.text, x: interior.x, y: sensorBottom + offset, width: interior.width, color: color, bold: true, clip: interior)
    }
}

private func drawNetwork(_ snapshot: Snapshot, _ history: History, _ rect: Rect, _ canvas: Canvas, includesDisk: Bool) {
    let interior = canvas.box(rect, accent: canvas.palette.cyan, title: "Network", trailing: snapshot.network.interfaceLabel)
    guard interior.height > 0 else { return }
    var row = interior.y
    let rowsLeft = interior.bottom - interior.y
    let tallGraphs = includesDisk && rowsLeft >= 12
    let inlineGraphs = includesDisk && !tallGraphs && rowsLeft >= 7
    rateLine("Down", snapshot.network.bytesInPerSecond, history.networkIn, canvas.palette.cyan, row: &row, interior: interior, inline: inlineGraphs, canvas: canvas)
    rateLine("Up", snapshot.network.bytesOutPerSecond, history.networkOut, canvas.palette.yellow, row: &row, interior: interior, inline: inlineGraphs, canvas: canvas)
    if !includesDisk {
        splitGraph(history.networkIn, history.networkOut, canvas.palette.cyan, canvas.palette.yellow, height: interior.bottom - row, row: &row, interior: interior, canvas: canvas)
        return
    }
    if tallGraphs {
        splitGraph(history.networkIn, history.networkOut, canvas.palette.cyan, canvas.palette.yellow, height: 2, row: &row, interior: interior, canvas: canvas)
    }
    guard row < interior.bottom else { return }
    canvas.text("Disk", x: interior.x, y: row, color: canvas.palette.orange, bold: true, clip: interior)
    row += 1
    rateLine("Read", snapshot.disk.readPerSecond, history.diskRead, canvas.palette.green, row: &row, interior: interior, inline: inlineGraphs, canvas: canvas)
    rateLine("Write", snapshot.disk.writePerSecond, history.diskWrite, canvas.palette.orange, row: &row, interior: interior, inline: inlineGraphs, canvas: canvas)
    if tallGraphs {
        splitGraph(history.diskRead, history.diskWrite, canvas.palette.green, canvas.palette.orange, height: 2, row: &row, interior: interior, canvas: canvas)
    }
    drawVolume(snapshot.disk, row: &row, interior: interior, canvas: canvas, inlineBar: false)
}

private func drawDisk(_ snapshot: Snapshot, _ history: History, _ rect: Rect, _ canvas: Canvas) {
    let interior = canvas.box(rect, accent: canvas.palette.orange, title: "Disk")
    guard interior.height > 0 else { return }
    var row = interior.y
    rateLine("Read", snapshot.disk.readPerSecond, history.diskRead, canvas.palette.green, row: &row, interior: interior, inline: false, canvas: canvas)
    rateLine("Write", snapshot.disk.writePerSecond, history.diskWrite, canvas.palette.orange, row: &row, interior: interior, inline: false, canvas: canvas)
    let volume = snapshot.disk.volumeTotal > 0 && interior.bottom - row >= 3 ? 1 : 0
    splitGraph(
        history.diskRead,
        history.diskWrite,
        canvas.palette.green,
        canvas.palette.orange,
        height: interior.bottom - row - volume,
        row: &row,
        interior: interior,
        canvas: canvas
    )
    if volume > 0 {
        drawVolume(snapshot.disk, row: &row, interior: interior, canvas: canvas, inlineBar: true)
    }
}

private func drawPower(_ snapshot: Snapshot, _ rect: Rect, _ canvas: Canvas) {
    let interior = canvas.box(rect, accent: canvas.palette.yellow, title: "Power")
    guard interior.height > 0 else { return }
    var row = interior.y
    if let battery = snapshot.battery, row < interior.bottom {
        canvas.row(
            batteryLine(battery, width: interior.width, compact: false),
            x: interior.x,
            y: row,
            width: interior.width,
            color: batteryColor(battery, canvas.palette),
            bold: true,
            clip: interior
        )
        row += 1
    }
    if row < interior.bottom {
        let line = powerMixLine(snapshot, width: interior.width)
        if !line.isEmpty {
            canvas.row(line, x: interior.x, y: row, width: interior.width, color: canvas.palette.text, bold: true, clip: interior)
        }
    }
}

private struct PowerLine {
    var text: String
    var battery: BatterySample?
}

private func embeddedPowerLines(_ snapshot: Snapshot, width: Int) -> [PowerLine] {
    var lines: [PowerLine] = []
    if let battery = snapshot.battery {
        lines.append(PowerLine(text: batteryLine(battery, width: width, compact: true), battery: battery))
    }
    let mix = powerMixLine(snapshot, width: width)
    if !mix.isEmpty {
        lines.append(PowerLine(text: mix, battery: nil))
    }
    return lines
}

private func batteryColor(_ battery: BatterySample, _ palette: Palette) -> RGB {
    if battery.percent < 0.2 { return palette.red }
    if battery.charging { return palette.green }
    return palette.text
}

private func batteryLine(_ battery: BatterySample, width: Int, compact: Bool) -> String {
    let percent = formatPercent(battery.percent, decimals: 0)
    var parts = [compact ? "Batt \(percent) \(battery.stateLabel)" : "\(percent)  \(battery.stateLabel)"]
    if battery.charging, let minutes = battery.minutesToFull {
        parts.append("\(formatDuration(minutes: minutes)) to full")
    } else if let minutes = battery.minutesToEmpty {
        parts.append("\(formatDuration(minutes: minutes)) left")
    }
    if let watts = battery.watts, watts >= 0.05 {
        parts.append(formatWatts(watts))
    }
    if let cycles = battery.cycleCount {
        parts.append(compact ? "\(cycles) cyc" : "\(cycles) cycles")
    }
    if let temperature = battery.temperature {
        parts.append(formatTemperature(temperature))
    }
    return joinedToFit(parts, width: width)
}

private func powerMixLine(_ snapshot: Snapshot, width: Int) -> String {
    var parts: [String] = []
    if let power = snapshot.thermal.boardPower {
        parts.append("System \(formatWatts(power))")
    }
    parts.append(contentsOf: componentParts(snapshot.power))
    return joinedToFit(parts, width: width)
}

private func rateLine(
    _ label: String,
    _ rate: Double?,
    _ series: [Double],
    _ color: RGB,
    row: inout Int,
    interior: Rect,
    inline: Bool,
    canvas: Canvas
) {
    guard row < interior.bottom else { return }
    let value = rate.map(formatRate) ?? "—"
    let text = padRight(label, width: 5) + padLeft(value, width: 10)
    canvas.text(text, x: interior.x, y: row, color: color, bold: true, clip: interior)
    if inline {
        let graphX = interior.x + text.count + 1
        canvas.histogram(
            values: series,
            x: graphX,
            y: row,
            width: max(0, interior.right - graphX),
            height: 1,
            clip: interior,
            floor: 0,
            ceiling: max(series.max() ?? 0, 1)
        ) { _ in color }
    }
    row += 1
}

private func splitGraph(
    _ left: [Double],
    _ right: [Double],
    _ leftColor: RGB,
    _ rightColor: RGB,
    height: Int,
    row: inout Int,
    interior: Rect,
    canvas: Canvas
) {
    guard height > 0, row + height <= interior.bottom else { return }
    let gap = interior.width > 4 ? 1 : 0
    let leftWidth = max(1, (interior.width - gap) / 2)
    let rightX = interior.x + leftWidth + gap
    canvas.histogram(
        values: left,
        x: interior.x,
        y: row,
        width: leftWidth,
        height: height,
        clip: interior,
        floor: 0,
        ceiling: max(left.max() ?? 0, 1)
    ) { _ in leftColor }
    canvas.histogram(
        values: right,
        x: rightX,
        y: row,
        width: max(0, interior.right - rightX),
        height: height,
        clip: interior,
        floor: 0,
        ceiling: max(right.max() ?? 0, 1)
    ) { _ in rightColor }
    row += height
}

private func drawVolume(_ disk: DiskSample, row: inout Int, interior: Rect, canvas: Canvas, inlineBar: Bool) {
    guard row < interior.bottom, disk.volumeTotal > 0 else { return }
    let free = formatBytes(Double(disk.volumeFree))
    let total = formatBytes(Double(disk.volumeTotal))
    let used = disk.volumeTotal > disk.volumeFree ? disk.volumeTotal - disk.volumeFree : 0
    let fraction = Double(used) / Double(disk.volumeTotal)
    let leftText = "Volume \(free) free"
    let gap = interior.width - leftText.count - total.count
    if inlineBar, gap >= 6 {
        canvas.text(leftText, x: interior.x, y: row, color: canvas.palette.text, clip: interior)
        canvas.bar(
            x: interior.x + leftText.count + 1,
            y: row,
            width: gap - 2,
            fraction: fraction,
            clip: interior,
            color: canvas.palette.orange
        )
        canvas.text(total, x: interior.right - total.count, y: row, color: canvas.palette.text, clip: interior)
        row += 1
        return
    }
    canvas.row(
        spread(left: leftText, right: total, width: interior.width),
        x: interior.x,
        y: row,
        width: interior.width,
        color: canvas.palette.text,
        clip: interior
    )
    row += 1
    if row < interior.bottom {
        canvas.bar(x: interior.x, y: row, width: interior.width, fraction: fraction, clip: interior, color: canvas.palette.orange)
        row += 1
    }
}

func componentLine(_ power: ComponentPower, width: Int) -> String {
    joinedToFit(componentParts(power), width: width)
}

private func componentParts(_ power: ComponentPower) -> [String] {
    let parts: [(String, Double?)] = [
        ("CPU", power.cpu),
        ("GPU", power.gpu),
        ("DRAM", power.dram),
        ("ANE", power.ane),
        ("Disp", power.display),
    ]
    return parts.compactMap { name, watts -> String? in
        guard let watts else { return nil }
        return "\(name) \(formatWatts(watts))"
    }
}

private func joinedToFit(_ parts: [String], width: Int) -> String {
    let nonempty = parts.filter { !$0.isEmpty }
    let wide = fitted(nonempty, separator: "  ", width: width)
    let tight = fitted(nonempty, separator: " ", width: width)
    // A single space is used only when it keeps a part the wide gap would drop.
    if tight.count > wide.count { return tight.text }
    return wide.text
}

private func fitted(_ parts: [String], separator: String, width: Int) -> (count: Int, text: String) {
    var kept: [String] = []
    for part in parts {
        let next = (kept + [part]).joined(separator: separator)
        if next.count > width {
            if kept.isEmpty { return (1, fit(part, width: width)) }
            break
        }
        kept.append(part)
    }
    return (kept.count, kept.joined(separator: separator))
}

private func drawProcesses(_ snapshot: Snapshot, _ state: UIState, _ rect: Rect, _ canvas: Canvas) {
    let rows = visibleProcesses(snapshot.processes, state: state)
    let running = snapshot.processes.filter { $0.cpu >= 0.1 }.count
    var trailing = "\(running)/\(snapshot.processes.count)"
    if !state.filter.isEmpty {
        trailing = "/\(state.filter)  \(rows.count)"
    }
    let interior = canvas.box(rect, accent: canvas.palette.accent, title: "Processes", trailing: trailing)
    guard interior.height > 0, interior.width > 8 else { return }
    let showThreads = interior.width >= 64
    let showMemory = interior.width >= 52
    let header = processHeader(width: interior.width, showMemory: showMemory, showThreads: showThreads)
    canvas.row(header, x: interior.x, y: interior.y, width: interior.width, color: canvas.palette.dim, bold: true, clip: interior)
    let visible = interior.height - 1
    guard visible > 0 else { return }
    let start = min(state.scroll, max(0, rows.count))
    if rows.isEmpty {
        let message = state.filter.isEmpty ? "No processes" : "No processes match /\(state.filter)"
        canvas.row(message, x: interior.x, y: interior.y + 1, width: interior.width, color: canvas.palette.dim, clip: interior)
        return
    }
    for line in 0..<visible {
        let index = start + line
        guard index < rows.count else { return }
        let process = rows[index]
        let selected = process.pid == state.selectedPID
        let y = interior.y + 1 + line
        if selected {
            for column in interior.x..<interior.right {
                canvas.screen.put(" ", x: column, y: y, style: Style(canvas.palette.text, background: canvas.palette.selected))
            }
        }
        var text = processLine(process, width: interior.width, showMemory: showMemory, showThreads: showThreads)
        if selected, !text.isEmpty {
            text = "▸" + text.dropFirst()
        }
        let style = Style(
            canvas.palette.text,
            background: selected ? canvas.palette.selected : nil,
            bold: selected
        )
        canvas.screen.write(text, x: interior.x, y: y, style: style, clip: interior)
        if !selected {
            paintProcessCPU(text, process: process, x: interior.x, y: y, clip: interior, canvas: canvas)
        }
    }
}

private func drawFooter(_ snapshot: Snapshot, _ state: UIState, _ row: Int, _ columns: Int, _ canvas: Canvas) {
    let interval = state.interval < 1
        ? String(format: "%.2gs", state.interval)
        : String(format: "%g s", state.interval)
    var left = "macstat  \(interval)  up \(formatUptime(snapshot.uptime))"
    if state.paused { left += "  paused" }
    if state.editingFilter {
        left += "  /\(state.filter)_"
    }
    let sample = String(format: "%.0fms", snapshot.sampleSeconds * 1000)
    let help = state.help ? "? close" : "? help"
    let right = "\(sample)  \(help)  q quit"
    let clip = Rect(x: 0, y: row, width: columns, height: 1)
    canvas.row(spread(left: left, right: right, width: columns), x: 0, y: row, width: columns, color: canvas.palette.dim, clip: clip)
    if state.paused, let range = left.range(of: "paused") {
        canvas.text("paused", x: left.distance(from: left.startIndex, to: range.lowerBound), y: row, color: canvas.palette.yellow, bold: true, clip: clip)
    }
}

private func drawHelp(columns: Int, rows: Int, canvas: Canvas) {
    let width = min(62, columns - 4)
    let height = min(18, rows - 2)
    guard width >= 40, height >= 12 else { return }
    let rect = Rect(x: (columns - width) / 2, y: (rows - height) / 2, width: width, height: height)
    for y in rect.y..<rect.bottom {
        for x in rect.x..<rect.right {
            canvas.screen.put(" ", x: x, y: y, style: Style(canvas.palette.text, background: canvas.palette.selected))
        }
    }
    let interior = canvas.box(rect, accent: canvas.palette.accent, title: "Help")
    let lines = [
        ("q, ctrl-c", "quit"),
        ("space", "pause and resume"),
        ("c  m  n  p", "sort by CPU, memory, name, pid"),
        ("r", "reverse the sort"),
        ("j k arrows", "move the selection"),
        ("g  G", "top and bottom"),
        ("/", "filter by process name"),
        ("+  -", "faster or slower refresh"),
        ("?", "close help"),
    ]
    var row = interior.y
    for line in lines {
        guard row < interior.bottom else { return }
        canvas.text(padRight(line.0, width: 16), x: interior.x, y: row, color: canvas.palette.accent, bold: true, clip: interior)
        canvas.row(line.1, x: interior.x + 16, y: row, width: interior.width - 16, color: canvas.palette.text, clip: interior)
        row += 1
    }
    row += 1
    let notes = [
        "Process CPU% counts one core as 100%.",
        "The CPU box is the average of every core.",
        "Sensor values are SMC thermal zones, in °F.",
        "They are not a temperature for each core.",
        "Some system processes hide CPU and memory.",
        "Component watts appear once the energy counters move.",
    ]
    for note in notes {
        guard row < interior.bottom else { return }
        canvas.row(note, x: interior.x, y: row, width: interior.width, color: canvas.palette.dim, clip: interior)
        row += 1
    }
}

func visibleProcesses(_ processes: [ProcessSample], state: UIState) -> [ProcessSample] {
    let filtered = processes.filter { process in
        state.filter.isEmpty || process.name.localizedCaseInsensitiveContains(state.filter)
    }
    return filtered.sorted { lhs, rhs in
        switch state.sort {
        case .cpu:
            if lhs.measured != rhs.measured { return lhs.measured }
            if lhs.cpu != rhs.cpu {
                return state.descending ? lhs.cpu > rhs.cpu : lhs.cpu < rhs.cpu
            }
        case .memory:
            if lhs.measured != rhs.measured { return lhs.measured }
            if lhs.resident != rhs.resident {
                return state.descending ? lhs.resident > rhs.resident : lhs.resident < rhs.resident
            }
        case .name:
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame {
                return state.descending ? order == .orderedDescending : order == .orderedAscending
            }
        case .pid where lhs.pid != rhs.pid:
            return state.descending ? lhs.pid > rhs.pid : lhs.pid < rhs.pid
        default:
            break
        }
        return lhs.pid < rhs.pid
    }
}

func reconcile(_ state: inout UIState, processes: [ProcessSample], rows: Int) {
    let visible = visibleProcesses(processes, state: state)
    let window = max(1, rows)
    if visible.isEmpty {
        state.selectedPID = nil
        state.scroll = 0
        return
    }
    let selected = visible.firstIndex { $0.pid == state.selectedPID } ?? 0
    state.selectedPID = visible[selected].pid
    if selected < state.scroll { state.scroll = selected }
    if selected >= state.scroll + window { state.scroll = selected - window + 1 }
    let maxScroll = max(0, visible.count - window)
    if state.scroll > maxScroll { state.scroll = maxScroll }
    if state.scroll < 0 { state.scroll = 0 }
}

private func processHeader(width: Int, showMemory: Bool, showThreads: Bool) -> String {
    var parts = ["PID".padded(7), "CPU%".padded(7)]
    if showMemory { parts.append("MEM%".padded(6)) }
    parts.append("RES".padded(8))
    if showThreads { parts.append("THR".padded(4)) }
    parts.append("NAME")
    return fit(parts.joined(separator: " "), width: width)
}

private func processLine(_ process: ProcessSample, width: Int, showMemory: Bool, showThreads: Bool) -> String {
    let cpu = process.measured ? String(format: "%6.1f", process.cpu) : "—"
    var parts = [
        String(process.pid).padded(7),
        cpu.padded(7),
    ]
    if showMemory {
        let memory = process.measured ? String(format: "%5.1f", process.memoryFraction * 100) : "—"
        parts.append(memory.padded(6))
    }
    let resident = process.measured ? formatBytes(Double(process.resident)) : "—"
    parts.append(resident.padded(8))
    if showThreads {
        let threads = process.measured ? String(process.threads) : "—"
        parts.append(threads.padded(4))
    }
    parts.append(process.name)
    return fit(parts.joined(separator: " "), width: width)
}

private func paintProcessCPU(_ text: String, process: ProcessSample, x: Int, y: Int, clip: Rect, canvas: Canvas) {
    guard let range = text.range(of: String(format: "%6.1f", process.cpu)) else { return }
    let prefix = text[..<range.lowerBound].count
    canvas.text(
        String(text[range]),
        x: x + prefix,
        y: y,
        color: meterColor(process.cpu / 100, canvas.palette),
        bold: process.cpu >= 50,
        clip: clip
    )
}

private extension String {
    func padded(_ width: Int) -> String {
        padLeft(self, width: width)
    }
}
