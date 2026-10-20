import Darwin
import Foundation

/// Invented machine used by `macstat --preview`. Nothing here is read from the host.
enum Fixture {
    static let columns = 120
    static let rows = 40

    static func frame(help: Bool) -> String {
        let snapshot = makeSnapshot()
        var state = UIState()
        state.selectedPID = 902
        state.interval = 1
        state.help = help
        return drawDashboard(
            snapshot: snapshot,
            history: makeHistory(snapshot),
            state: state,
            system: makeSystem(),
            columns: columns,
            rows: rows
        )
    }

    private static func makeSystem() -> SystemInfo {
        SystemInfo(
            chip: "Apple M4 Pro",
            model: "Demo",
            osVersion: "macOS 15.5",
            memoryBytes: gib(24),
            pageSize: 16384,
            clusters: [
                ClusterInfo(name: "Performance", prefix: "P", start: 0, count: 8),
                ClusterInfo(name: "Efficiency", prefix: "E", start: 8, count: 4),
            ],
            coreCount: 12
        )
    }

    private static func makeSnapshot() -> Snapshot {
        let performance: [Double] = [0.62, 0.48, 0.41, 0.33, 0.22, 0.18, 0.11, 0.05]
        let efficiency: [Double] = [0.28, 0.16, 0.09, 0.04]
        let usages = performance + efficiency
        let total = usages.reduce(0, +) / Double(usages.count)
        let cores = usages.enumerated().map { index, usage in
            let label = index < performance.count ? "P\(index)" : "E\(index - performance.count)"
            return CoreSample(label: label, usage: usage, user: usage * 0.7, system: usage * 0.3)
        }
        let memoryTotal = gib(24)
        return Snapshot(
            takenAt: Date(timeIntervalSince1970: 1_750_000_000),
            uptime: 2 * 86_400 + 6 * 3_600,
            sampleSeconds: 0.012,
            cpu: CPUSample(
                total: total,
                user: total * 0.68,
                system: total * 0.32,
                cores: cores,
                clusters: [
                    ClusterSample(name: "Performance", usage: average(performance), coreCount: 8),
                    ClusterSample(name: "Efficiency", usage: average(efficiency), coreCount: 4),
                ],
                load: (1.84, 1.62, 1.41)
            ),
            memory: MemorySample(
                total: memoryTotal,
                used: gib(16),
                app: gib(11.5),
                wired: gib(2.8),
                compressed: gib(1.7),
                cached: gib(5.2),
                swapUsed: gib(1.5),
                swapTotal: gib(4),
                pressure: "normal"
            ),
            network: NetworkSample(
                bytesInPerSecond: 14.6 * 1024 * 1024,
                bytesOutPerSecond: 1.25 * 1024 * 1024,
                interfaceLabel: "en0"
            ),
            disk: DiskSample(
                readPerSecond: 2.4 * 1024 * 1024,
                writePerSecond: 18.2 * 1024 * 1024,
                volumeFree: gib(410),
                volumeTotal: gib(926)
            ),
            gpu: GPUSample(device: 0.31, renderer: 0.22, tiler: 0.08),
            battery: BatterySample(
                percent: 0.81,
                charging: false,
                onAC: false,
                fullyCharged: false,
                minutesToEmpty: 5 * 60 + 40,
                minutesToFull: nil,
                watts: 11.4,
                temperature: 31.2,
                cycleCount: 186
            ),
            power: ComponentPower(cpu: 6.4, gpu: 2.1, dram: 1.4, ane: 0.2, display: 3.1),
            thermal: ThermalSample(
                available: true,
                state: "nominal",
                cpuAverage: 47.6,
                cpuPeak: 51.2,
                gpuAverage: 41.8,
                gpuPeak: 42.6,
                peak: ThermalZone(key: "Tp0C", celsius: 51.2, group: .cpu),
                boardPower: 18.4,
                fans: [
                    FanSample(name: "Fan 1", rpm: 2410, minimum: 1200, maximum: 6000),
                    FanSample(name: "Fan 2", rpm: 2280, minimum: 1200, maximum: 6000),
                ],
                zones: [
                    ThermalZone(key: "Tp0C", celsius: 51.2, group: .cpu),
                    ThermalZone(key: "Tp00", celsius: 49.4, group: .cpu),
                    ThermalZone(key: "Tp01", celsius: 48.1, group: .cpu),
                    ThermalZone(key: "Tp02", celsius: 46.8, group: .cpu),
                    ThermalZone(key: "Te00", celsius: 44.2, group: .cpu),
                    ThermalZone(key: "Tg00", celsius: 42.6, group: .gpu),
                    ThermalZone(key: "Tg01", celsius: 41.0, group: .gpu),
                    ThermalZone(key: "TVM0", celsius: 64.5, group: .power),
                    ThermalZone(key: "Ts0P", celsius: 33.8, group: .skin),
                    ThermalZone(key: "TB0T", celsius: 30.4, group: .battery),
                ]
            ),
            processes: processes(memoryTotal: memoryTotal)
        )
    }

    private static func processes(memoryTotal: UInt64) -> [ProcessSample] {
        let rows: [(Int32, String, Double, Double, Int)] = [
            (412, "swift-frontend", 186.4, 1.84, 8),
            (388, "Xcode", 42.1, 2.46, 24),
            (902, "Safari", 18.6, 0.64, 12),
            (210, "WindowServer", 11.2, 0.18, 6),
            (540, "com.apple.WebKit.WebContent", 9.4, 0.72, 14),
            (118, "Finder", 4.2, 0.09, 5),
            (776, "Terminal", 3.1, 0.05, 3),
            (331, "Spotlight", 2.4, 0.07, 4),
            (144, "ControlCenter", 1.6, 0.04, 4),
            (88, "coreaudiod", 1.1, 0.02, 5),
            (64, "bluetoothd", 0.6, 0.01, 3),
            (51, "loginwindow", 0.4, 0.02, 3),
            (22, "distnoted", 0.2, 0.01, 2),
            (17, "sysmond", 0.1, 0.01, 2),
        ]
        var samples = rows.map { pid, name, cpu, gigabytes, threads in
            let resident = gib(gigabytes)
            return ProcessSample(
                pid: pid,
                name: name,
                cpu: cpu,
                resident: resident,
                memoryFraction: Double(resident) / Double(memoryTotal),
                threads: threads,
                measured: true
            )
        }
        samples.append(ProcessSample(
            pid: 0,
            name: "kernel_task",
            cpu: 0,
            resident: 0,
            memoryFraction: 0,
            threads: 0,
            measured: false
        ))
        return samples
    }

    private static func makeHistory(_ snapshot: Snapshot) -> History {
        History(
            cpu: series(count: 96, current: snapshot.cpu.total, low: 0.08, high: 0.55),
            memory: series(count: 96, current: snapshot.memory.usedFraction, low: 0.58, high: 0.72),
            temperature: series(count: 96, current: snapshot.thermal.cpuAverage ?? 47, low: 42, high: 58),
            networkIn: series(count: 96, current: snapshot.network.bytesInPerSecond ?? 0, low: 2_000_000, high: 22_000_000),
            networkOut: series(count: 96, current: snapshot.network.bytesOutPerSecond ?? 0, low: 200_000, high: 3_000_000),
            diskRead: series(count: 96, current: snapshot.disk.readPerSecond ?? 0, low: 0, high: 12_000_000),
            diskWrite: series(count: 96, current: snapshot.disk.writePerSecond ?? 0, low: 1_000_000, high: 40_000_000)
        )
    }

    private static func series(count: Int, current: Double, low: Double, high: Double) -> [Double] {
        guard count > 1 else { return [current] }
        let mid = (low + high) / 2
        let amplitude = (high - low) / 2
        return (0..<count).map { index in
            if index == count - 1 { return current }
            let t = Double(index) / Double(count - 1)
            let wave = sin(t * .pi * 4) * 0.7 + sin(t * .pi * 11 + 0.6) * 0.3
            return min(max(mid + amplitude * wave, low), high)
        }
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func gib(_ value: Double) -> UInt64 {
        UInt64(value * 1024 * 1024 * 1024)
    }
}
