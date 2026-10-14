import Darwin
import Foundation

let helpText = """
macstat — a terminal monitor for CPU, memory, sensors, network, disk, and processes.

Usage:
  macstat                  open the full-screen monitor
  macstat --once           print one snapshot and exit
  macstat --interval 0.5   refresh every half second
  macstat --help

Keys inside the monitor:
  q, ctrl-c       quit
  space           pause
  c m n p         sort processes by CPU, memory, name, or pid
  r               reverse sort
  j k, arrows     move the selection
  g G             top and bottom
  /               filter process names
  + -             change the refresh interval
  ?               help

Set MACSTAT_THEME=light for a light terminal background.
Temperatures are read from the SMC and shown in °F. They are thermal zones, not per-core temperatures.
"""

struct Options {
    var once = false
    var help = false
    var interval = 1.0

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--once", "-1":
                options.once = true
            case "--help", "-h":
                options.help = true
            case "--interval", "-i":
                index += 1
                if index < arguments.count, let value = Double(arguments[index]) {
                    options.interval = min(max(value, 0.25), 10)
                } else {
                    options.help = true
                }
            default:
                options.help = true
            }
            index += 1
        }
        return options
    }
}

@main
struct Macstat {
    static func main() {
        let options = Options.parse(CommandLine.arguments)
        if options.help {
            print(helpText)
            return
        }
        let interactive = isatty(STDOUT_FILENO) == 1 && isatty(STDIN_FILENO) == 1
        let sampler = Sampler()
        if options.once || !interactive {
            print(textReport(prime(sampler)))
            return
        }
        let terminal = Terminal()
        terminal.enter()
        defer { terminal.leave() }
        run(sampler: sampler, terminal: terminal, interval: options.interval)
    }
}

private func prime(_ sampler: Sampler) -> Snapshot {
    _ = sampler.sample()
    usleep(400_000)
    return sampler.sample()
}

private func run(sampler: Sampler, terminal: Terminal, interval: Double) {
    var state = UIState(interval: interval)
    var history = History()
    terminal.write(drawMessage("sampling sensors…", columns: terminal.size.columns, rows: terminal.size.rows))
    _ = sampler.sample()
    let primed = wait(terminal: terminal, milliseconds: 400)
    if primed.contains(where: isQuit) { return }
    var snapshot = sampler.sample()
    history.add(snapshot)
    var nextSample = monotonic() + state.interval
    var dirty = true

    while true {
        let resized = terminal.refreshSize()
        let processRows = layout(
            columns: terminal.size.columns,
            rows: terminal.size.rows,
            coreCount: sampler.system.coreCount,
            clusterCount: sampler.system.clusters.count
        ).map { max(1, $0.processes.inset.height - 1) } ?? 1
        reconcile(&state, processes: snapshot.processes, rows: processRows)
        if dirty || resized {
            terminal.write(drawDashboard(
                snapshot: snapshot,
                history: history,
                state: state,
                system: sampler.system,
                columns: terminal.size.columns,
                rows: terminal.size.rows
            ))
            dirty = false
        }

        let timeout = state.paused ? 250 : max(20, Int((nextSample - monotonic()) * 1000))
        let keys = terminal.poll(timeoutMilliseconds: timeout)
        if !keys.isEmpty {
            if handle(keys, state: &state, processes: snapshot.processes) {
                return
            }
            dirty = true
        }
        if !state.paused, monotonic() >= nextSample {
            snapshot = sampler.sample()
            history.add(snapshot)
            nextSample = monotonic() + state.interval
            dirty = true
        }
    }
}

private func handle(_ keys: [Key], state: inout UIState, processes: [ProcessSample]) -> Bool {
    let visible = visibleProcesses(processes, state: state)
    for key in keys {
        if key == .control(3) { return true }
        if state.editingFilter {
            switch key {
            case .escape:
                state.editingFilter = false
                state.filter = ""
            case .enter:
                state.editingFilter = false
            case .backspace:
                if !state.filter.isEmpty { state.filter.removeLast() }
            case let .character(character) where character.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }):
                if state.filter.count < 32 { state.filter.append(character) }
            default:
                break
            }
            state.scroll = 0
            continue
        }

        switch key {
        case .character("q"), .character("Q"):
            return true
        case .character(" "):
            state.paused.toggle()
        case .character("?"):
            state.help.toggle()
        case .escape:
            state.help = false
        case .character("c"):
            state.sort = .cpu
            state.descending = true
        case .character("m"):
            state.sort = .memory
            state.descending = true
        case .character("n"):
            state.sort = .name
            state.descending = false
        case .character("p"):
            state.sort = .pid
            state.descending = false
        case .character("r"):
            state.descending.toggle()
        case .character("/"):
            state.editingFilter = true
            state.help = false
        case .character("+"), .character("="):
            state.interval = min(10, state.interval + 0.25)
        case .character("-"), .character("_"):
            state.interval = max(0.25, state.interval - 0.25)
        case .character("j"), .down:
            moveSelection(1, state: &state, visible: visible)
        case .character("k"), .up:
            moveSelection(-1, state: &state, visible: visible)
        case .character("g"), .home:
            state.selectedPID = visible.first?.pid
            state.scroll = 0
        case .character("G"), .end:
            state.selectedPID = visible.last?.pid
        case .pageDown, .control(4):
            moveSelection(10, state: &state, visible: visible)
        case .pageUp, .control(21):
            moveSelection(-10, state: &state, visible: visible)
        case .control(12):
            break
        default:
            break
        }
    }
    return false
}

private func moveSelection(_ delta: Int, state: inout UIState, visible: [ProcessSample]) {
    guard !visible.isEmpty else { return }
    let current = visible.firstIndex { $0.pid == state.selectedPID } ?? 0
    let next = min(max(0, current + delta), visible.count - 1)
    state.selectedPID = visible[next].pid
}

private func isQuit(_ key: Key) -> Bool {
    key == .character("q") || key == .character("Q") || key == .control(3)
}

private func wait(terminal: Terminal, milliseconds: Int) -> [Key] {
    var left = milliseconds
    var keys: [Key] = []
    while left > 0 {
        let slice = min(50, left)
        keys.append(contentsOf: terminal.poll(timeoutMilliseconds: slice))
        left -= slice
        if keys.contains(where: isQuit) { break }
    }
    return keys
}

private func drawMessage(_ message: String, columns: Int, rows: Int) -> String {
    let palette = Palette.resolve()
    let screen = Screen(columns: columns, rows: rows, palette: palette)
    let canvas = Canvas(screen: screen, palette: palette)
    canvas.text(message, x: 1, y: 1, color: palette.text, clip: Rect(x: 0, y: 0, width: columns, height: rows))
    canvas.text("q quit", x: 1, y: 2, color: palette.dim, clip: Rect(x: 0, y: 0, width: columns, height: rows))
    return screen.render()
}

private func monotonic() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
}

func textReport(_ snapshot: Snapshot) -> String {
    let system = SystemInfo.load()
    var lines: [String] = []
    let cpu = snapshot.cpu
    lines.append("\(system.chip)  \(system.model)  \(system.osVersion)  up \(formatUptime(snapshot.uptime))")
    lines.append(String(
        format: "CPU  %.1f%%  user %.1f%%  sys %.1f%%  idle %.1f%%  load %.2f %.2f %.2f  GPU %@",
        cpu.total * 100,
        cpu.user * 100,
        cpu.system * 100,
        (1 - cpu.total) * 100,
        cpu.load.0, cpu.load.1, cpu.load.2,
        snapshot.gpu.device.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
    ))
    for cluster in cpu.clusters {
        lines.append(String(format: "  %-14@ %2d cores  %5.1f%%", cluster.name as NSString, cluster.coreCount, cluster.usage * 100))
    }
    let coreLine = cpu.cores.map { String(format: "%@ %3.0f%%", $0.label, $0.usage * 100) }.joined(separator: "  ")
    if !coreLine.isEmpty { lines.append("  " + coreLine) }

    let memory = snapshot.memory
    lines.append("")
    lines.append("Memory  \(formatBytes(Double(memory.used))) / \(formatBytes(Double(memory.total)))  \(memory.pressure)")
    lines.append("  app \(formatBytes(Double(memory.app)))  wired \(formatBytes(Double(memory.wired)))  compressed \(formatBytes(Double(memory.compressed)))  cached \(formatBytes(Double(memory.cached)))")
    lines.append("  swap \(formatBytes(Double(memory.swapUsed))) / \(formatBytes(Double(memory.swapTotal)))")

    let thermal = snapshot.thermal
    lines.append("")
    lines.append("Sensors  \(thermal.state)  \(thermal.available ? "live" : "unavailable")")
    if let average = thermal.cpuAverage {
        lines.append("  CPU avg \(formatTemperature(average))  peak \(formatTemperature(thermal.cpuPeak ?? average))")
    }
    if let average = thermal.gpuAverage {
        lines.append("  GPU avg \(formatTemperature(average))  peak \(formatTemperature(thermal.gpuPeak ?? average))")
    }
    if let power = thermal.boardPower {
        lines.append(String(format: "  board %.2f W", power))
    }
    for fan in thermal.fans {
        let speed = fan.rpm < 1 ? "stopped" : String(format: "%.0f rpm", fan.rpm)
        lines.append("  \(fan.name)  \(speed)  (\(Int(fan.minimum))–\(Int(fan.maximum)))")
    }
    for zone in displayZones(thermal, limit: 12) {
        lines.append("  \(padRight(zone.key, width: 8)) \(padLeft(formatTemperature(zone.celsius), width: 7))  \(zone.group.rawValue)")
    }

    lines.append("")
    let down = snapshot.network.bytesInPerSecond.map(formatRate) ?? "n/a"
    let up = snapshot.network.bytesOutPerSecond.map(formatRate) ?? "n/a"
    lines.append("Network  \(snapshot.network.interfaceLabel)  down \(down)  up \(up)")
    let read = snapshot.disk.readPerSecond.map(formatRate) ?? "n/a"
    let write = snapshot.disk.writePerSecond.map(formatRate) ?? "n/a"
    lines.append("Disk     read \(read)  write \(write)  free \(formatBytes(Double(snapshot.disk.volumeFree))) / \(formatBytes(Double(snapshot.disk.volumeTotal)))")
    if let battery = snapshot.battery {
        let mode = battery.charging ? "charging" : (battery.onAC ? "AC" : "discharging")
        let remaining = battery.minutesRemaining.map { "  \(formatDuration(minutes: $0))" } ?? ""
        lines.append(String(format: "Battery  %.0f%%  %@%@", battery.percent * 100, mode, remaining))
    }

    lines.append("")
    let measured = snapshot.processes.filter(\.measured).count
    lines.append(String(
        format: "Processes  %d  (%d with CPU)   sample %.0f ms",
        snapshot.processes.count,
        measured,
        snapshot.sampleSeconds * 1000
    ))
    let ranked = snapshot.processes.filter(\.measured).sorted { $0.cpu > $1.cpu }
    for process in ranked.prefix(8) {
        lines.append(String(
            format: "  %6d  %6.1f%%  %6.1f%%  %8@  %@",
            process.pid,
            process.cpu,
            process.memoryFraction * 100,
            formatBytes(Double(process.resident)) as NSString,
            process.name
        ))
    }
    return lines.joined(separator: "\n")
}
