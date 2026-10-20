import Darwin
import Foundation
import IOKit
import IOKit.ps

struct ClusterInfo: Sendable {
    var name: String
    var prefix: String
    var start: Int
    var count: Int
}

struct SystemInfo: Sendable {
    var chip: String
    var model: String
    var osVersion: String
    var memoryBytes: UInt64
    var pageSize: UInt64
    var clusters: [ClusterInfo]
    var coreCount: Int

    static func load() -> SystemInfo {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        let model = sysctlString("hw.model") ?? ""
        let os = sysctlString("kern.osproductversion").map { "macOS \($0)" } ?? "macOS"
        let memory = sysctlUInt64("hw.memsize") ?? 0
        let page = sysctlUInt64("hw.pagesize") ?? 16384
        let logical = Int(sysctlUInt64("hw.logicalcpu") ?? 0)
        let levels = Int(sysctlUInt64("hw.nperflevels") ?? 0)
        var clusters: [ClusterInfo] = []
        var usedPrefixes = Set<String>()
        var cursor = 0
        if levels > 0 {
            for level in 0..<levels {
                let count = Int(sysctlUInt64("hw.perflevel\(level).logicalcpu") ?? 0)
                guard count > 0 else { continue }
                let name = sysctlString("hw.perflevel\(level).name") ?? "Core"
                let prefix = clusterPrefix(name, taken: &usedPrefixes)
                clusters.append(ClusterInfo(name: name, prefix: prefix, start: cursor, count: count))
                cursor += count
            }
        }
        let cores = max(logical, cursor)
        if clusters.isEmpty, cores > 0 {
            clusters = [ClusterInfo(name: "Core", prefix: "C", start: 0, count: cores)]
        }
        return SystemInfo(
            chip: chip,
            model: model,
            osVersion: os,
            memoryBytes: memory,
            pageSize: page == 0 ? 16384 : page,
            clusters: clusters,
            coreCount: cores
        )
    }
}

struct CoreSample: Sendable {
    var label: String
    var usage: Double
    var user: Double
    var system: Double
}

struct ClusterSample: Sendable {
    var name: String
    var usage: Double
    var coreCount: Int
}

struct CPUSample: Sendable {
    var total: Double
    var user: Double
    var system: Double
    var cores: [CoreSample]
    var clusters: [ClusterSample]
    var load: (Double, Double, Double)
}

struct MemorySample: Sendable {
    var total: UInt64
    var used: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: String

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

struct NetworkSample: Sendable {
    var bytesInPerSecond: Double?
    var bytesOutPerSecond: Double?
    var interfaceLabel: String
}

struct DiskSample: Sendable {
    var readPerSecond: Double?
    var writePerSecond: Double?
    var volumeFree: UInt64
    var volumeTotal: UInt64
}

struct GPUSample: Sendable {
    var device: Double?
    var renderer: Double?
    var tiler: Double?
}

struct BatterySample: Sendable {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var fullyCharged: Bool
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var watts: Double?
    var temperature: Double?
    var cycleCount: Int?

    var stateLabel: String {
        if charging { return "charging" }
        if fullyCharged { return "charged" }
        if onAC { return "on AC" }
        return "discharging"
    }
}

struct FanSample: Sendable {
    var name: String
    var rpm: Double
    var minimum: Double
    var maximum: Double
}

struct ThermalZone: Sendable {
    var key: String
    var celsius: Double
    var group: SensorGroup
}

struct ThermalSample: Sendable {
    var available: Bool
    var state: String
    var cpuAverage: Double?
    var cpuPeak: Double?
    var gpuAverage: Double?
    var gpuPeak: Double?
    var peak: ThermalZone?
    var boardPower: Double?
    var fans: [FanSample]
    var zones: [ThermalZone]
}

struct ProcessSample: Sendable {
    var pid: Int32
    var name: String
    var cpu: Double
    var resident: UInt64
    var memoryFraction: Double
    var threads: Int
    /// False when macOS hides this process's task info from the current user.
    var measured: Bool
}

struct Snapshot: Sendable {
    var takenAt: Date
    var uptime: TimeInterval
    var sampleSeconds: Double
    var cpu: CPUSample
    var memory: MemorySample
    var network: NetworkSample
    var disk: DiskSample
    var gpu: GPUSample
    var battery: BatterySample?
    var power: ComponentPower
    var thermal: ThermalSample
    var processes: [ProcessSample]
}

private struct CoreTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    var busy: UInt32 { user &+ system &+ nice }
    var total: UInt32 { busy &+ idle }
}

final class Sampler {
    let system = SystemInfo.load()
    private let smc = SMC()
    private let energy = EnergyModel()
    private let hid = HIDTemperatures()
    private var temperatureKeys: [SMCSensorKey] = []
    private var hidNames: [String] = []
    private var discovered = false
    private var previousCores: [CoreTicks] = []
    private var previousNet: [String: (UInt64, UInt64)] = [:]
    private var previousDiskRead: UInt64?
    private var previousDiskWrite: UInt64?
    private var previousProcessTime: [Int32: UInt64] = [:]
    private var previousNanos: UInt64?
    private let timebase = MachTimebase.current()

    func sample() -> Snapshot {
        let started = monotonicNanos()
        if !discovered {
            discoverSensors()
            discovered = true
        }
        let now = monotonicNanos()
        let elapsed = previousNanos.map { Double(now &- $0) / 1_000_000_000 } ?? 0
        let cpu = readCPU()
        let memory = readMemory()
        let network = readNetwork(elapsed: elapsed)
        let disk = readDisk(elapsed: elapsed)
        let gpu = readGPU()
        let battery = readBattery()
        let power = energy?.read(now: now) ?? ComponentPower()
        let thermal = readThermal()
        let processes = readProcesses(elapsed: elapsed, memoryTotal: system.memoryBytes)
        previousNanos = now
        let uptime = readUptime()
        return Snapshot(
            takenAt: Date(),
            uptime: uptime,
            sampleSeconds: Double(monotonicNanos() &- started) / 1_000_000_000,
            cpu: cpu,
            memory: memory,
            network: network,
            disk: disk,
            gpu: gpu,
            battery: battery,
            power: power,
            thermal: thermal,
            processes: processes
        )
    }

    private func discoverSensors() {
        temperatureKeys = smc?.temperatureKeys() ?? []
        if temperatureKeys.isEmpty {
            hidNames = hid.read().map(\.name)
        }
    }

    private func readCPU() -> CPUSample {
        let ticks = readCoreTicks()
        var cores: [CoreSample] = []
        if !previousCores.isEmpty, previousCores.count == ticks.count {
            for index in ticks.indices {
                let current = ticks[index]
                let previous = previousCores[index]
                let total = current.total &- previous.total
                let user = current.user &- previous.user
                let system = current.system &- previous.system
                let busy = current.busy &- previous.busy
                let usage = total == 0 ? 0 : Double(busy) / Double(total)
                let userFraction = total == 0 ? 0 : Double(user) / Double(total)
                let systemFraction = total == 0 ? 0 : Double(system) / Double(total)
                cores.append(CoreSample(
                    label: coreLabel(index),
                    usage: min(max(usage, 0), 1),
                    user: userFraction,
                    system: systemFraction
                ))
            }
        } else {
            cores = ticks.indices.map {
                CoreSample(label: coreLabel($0), usage: 0, user: 0, system: 0)
            }
        }
        previousCores = ticks
        let count = Double(max(cores.count, 1))
        let clusters = system.clusters.map { cluster -> ClusterSample in
            let end = min(cluster.start + cluster.count, cores.count)
            let slice = cluster.start < end ? cores[cluster.start..<end] : []
            let usage = slice.isEmpty ? 0 : slice.reduce(0) { $0 + $1.usage } / Double(slice.count)
            return ClusterSample(name: cluster.name, usage: usage, coreCount: cluster.count)
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return CPUSample(
            total: cores.reduce(0) { $0 + $1.usage } / count,
            user: cores.reduce(0) { $0 + $1.user } / count,
            system: cores.reduce(0) { $0 + $1.system } / count,
            cores: cores,
            clusters: clusters,
            load: (load[0], load[1], load[2])
        )
    }

    private func coreLabel(_ index: Int) -> String {
        for cluster in system.clusters where index >= cluster.start && index < cluster.start + cluster.count {
            return "\(cluster.prefix)\(index - cluster.start)"
        }
        return "C\(index)"
    }

    private func readCoreTicks() -> [CoreTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &count,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
        }
        let coreCount = Int(count)
        return info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: coreCount) { pointer in
            (0..<coreCount).map { index in
                let ticks = pointer[index].cpu_ticks
                return CoreTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
            }
        }
    }

    private func readMemory() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = system.pageSize
        func pages(_ value: UInt64) -> UInt64 { value * page }
        let app: UInt64
        let wired: UInt64
        let compressed: UInt64
        let cached: UInt64
        if result == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            app = pages(internalPages > purgeable ? internalPages - purgeable : 0)
            wired = pages(UInt64(stats.wire_count))
            compressed = pages(UInt64(stats.compressor_page_count))
            cached = pages(UInt64(stats.external_page_count) + purgeable)
        } else {
            app = 0
            wired = 0
            compressed = 0
            cached = 0
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.stride
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        return MemorySample(
            total: system.memoryBytes,
            used: app &+ wired &+ compressed,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: pressureName(pressure)
        )
    }

    private func readNetwork(elapsed: Double) -> NetworkSample {
        let counters = interfaceCounters()
        var label = "all"
        var busiest: UInt64 = 0
        for (name, counts) in counters where counts.0 &+ counts.1 > busiest {
            busiest = counts.0 &+ counts.1
            label = name
        }
        if counters.count > 1 {
            label = "\(label)+"
        }
        var inbound = 0.0
        var outbound = 0.0
        var matched = false
        if elapsed > 0 {
            for (name, counts) in counters {
                guard let previous = previousNet[name] else { continue }
                inbound += Double(counts.0 &- previous.0)
                outbound += Double(counts.1 &- previous.1)
                matched = true
            }
        }
        previousNet = counters
        guard matched else {
            return NetworkSample(bytesInPerSecond: nil, bytesOutPerSecond: nil, interfaceLabel: label)
        }
        return NetworkSample(
            bytesInPerSecond: inbound / elapsed,
            bytesOutPerSecond: outbound / elapsed,
            interfaceLabel: label
        )
    }

    private func readDisk(elapsed: Double) -> DiskSample {
        let totals = diskBytes()
        let volume = volumeUsage()
        let readRate: Double?
        let writeRate: Double?
        if elapsed > 0, let previousRead = previousDiskRead, let previousWrite = previousDiskWrite {
            readRate = Double(totals.read &- previousRead) / elapsed
            writeRate = Double(totals.write &- previousWrite) / elapsed
        } else {
            readRate = nil
            writeRate = nil
        }
        previousDiskRead = totals.read
        previousDiskWrite = totals.write
        return DiskSample(
            readPerSecond: readRate,
            writePerSecond: writeRate,
            volumeFree: volume.free,
            volumeTotal: volume.total
        )
    }

    private func readGPU() -> GPUSample {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else {
            return GPUSample(device: nil, renderer: nil, tiler: nil)
        }
        defer { IOObjectRelease(iterator) }
        var device: Double?
        var renderer: Double?
        var tiler: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dictionary["PerformanceStatistics"] as? [String: Any] else {
                continue
            }
            device = maxOptional(device, percent(stats["Device Utilization %"]))
            renderer = maxOptional(renderer, percent(stats["Renderer Utilization %"]))
            tiler = maxOptional(tiler, percent(stats["Tiler Utilization %"]))
        }
        return GPUSample(device: device, renderer: renderer, tiler: tiler)
    }

    private func readBattery() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return readSmartBattery()
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let current = number(description[kIOPSCurrentCapacityKey as String])
            let maximum = number(description[kIOPSMaxCapacityKey as String])
            guard maximum > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let charging = boolValue(description[kIOPSIsChargingKey as String])
            let onBattery = state == kIOPSBatteryPowerValue as String
            let amperage = number(description["Amperage"])
            let voltage = number(description["Voltage"])
            var watts: Double?
            if amperage != 0, voltage != 0 {
                let computed = abs(amperage * voltage) / 1_000_000
                if computed > 0, computed < 250 { watts = computed }
            }
            var sample = BatterySample(
                percent: min(max(current / maximum, 0), 1),
                charging: charging,
                onAC: state == kIOPSACPowerValue as String,
                fullyCharged: boolValue(description[kIOPSIsChargedKey as String]),
                minutesToEmpty: onBattery ? powerMinutes(description[kIOPSTimeToEmptyKey as String]) : nil,
                minutesToFull: charging ? powerMinutes(description[kIOPSTimeToFullChargeKey as String]) : nil,
                watts: watts,
                temperature: batteryTemperature(description["Temperature"]),
                cycleCount: nil
            )
            if let smart = readSmartBattery() {
                sample = mergeBattery(sample, smart: smart)
            }
            return sample
        }
        return readSmartBattery()
    }

    /// AppleSmartBattery publishes cycle count and the charge and discharge estimates.
    private func readSmartBattery() -> BatterySample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let current = number(dictionary["CurrentCapacity"])
        let maximum = number(dictionary["MaxCapacity"])
        guard maximum > 0, maximum <= 100, current >= 0 else { return nil }
        let charging = boolValue(dictionary["IsCharging"])
        let onAC = boolValue(dictionary["ExternalConnected"])
        let data = dictionary["BatteryData"] as? [String: Any]
        let telemetry = dictionary["PowerTelemetryData"] as? [String: Any]
        let watts = packWatts(telemetry?["BatteryPower"]) ?? packWatts(data?["BatteryPower"]) ?? packWatts(amperage: dictionary["Amperage"], voltage: dictionary["Voltage"])
        let empty = powerMinutes(dictionary["AvgTimeToEmpty"])
            ?? ((charging || onAC) ? nil : powerMinutes(dictionary["TimeRemaining"]))
        return BatterySample(
            percent: min(current / maximum, 1),
            charging: charging,
            onAC: onAC,
            fullyCharged: boolValue(dictionary["FullyCharged"]),
            minutesToEmpty: charging ? nil : empty,
            minutesToFull: charging ? powerMinutes(dictionary["AvgTimeToFull"]) : nil,
            watts: watts,
            temperature: nil,
            cycleCount: integer(dictionary["CycleCount"])
        )
    }

    private func mergeBattery(_ sample: BatterySample, smart: BatterySample) -> BatterySample {
        var merged = sample
        merged.percent = smart.percent
        merged.charging = smart.charging
        merged.onAC = smart.onAC
        merged.fullyCharged = smart.fullyCharged
        merged.minutesToEmpty = smart.minutesToEmpty
        merged.minutesToFull = smart.minutesToFull
        if let watts = smart.watts, watts >= 0.05 || sample.watts == nil {
            merged.watts = watts
        }
        if smart.cycleCount != nil { merged.cycleCount = smart.cycleCount }
        return merged
    }

    private func readThermal() -> ThermalSample {
        let state = thermalStateName()
        var zones: [ThermalZone] = []
        if let smc {
            for sensor in temperatureKeys {
                guard let value = smc.readDouble(sensor), value > 1, value < 145 else { continue }
                zones.append(ThermalZone(key: sensor.name, celsius: value, group: sensorGroup(for: sensor.name)))
            }
        }
        if zones.isEmpty {
            for reading in hid.read() {
                zones.append(ThermalZone(key: reading.name, celsius: reading.celsius, group: hidGroup(reading.name)))
            }
        }
        zones.sort { $0.celsius > $1.celsius }
        let coreZones = zones.filter { isCoreTemperatureKey($0.key) }
        let cpuZones = coreZones.isEmpty ? zones.filter { $0.group == .cpu } : coreZones
        let gpuZones = zones.filter { $0.group == .gpu }
        // Keep every die sensor. A plain "hottest 48" cut drops them on Apple silicon,
        // because hundreds of warmer GPU and power zones sort above the ~40° cores.
        let others = zones.filter { !isCoreTemperatureKey($0.key) }
        let listedZones = coreZones + others.prefix(96)
        var fans: [FanSample] = []
        var board: Double?
        if let smc {
            let fanCount = Int(smc.readDouble(named: "FNum") ?? 0)
            for index in 0..<min(fanCount, 8) {
                guard let rpm = smc.readDouble(named: "F\(index)Ac") else { continue }
                fans.append(FanSample(
                    name: "Fan \(index + 1)",
                    rpm: rpm,
                    minimum: smc.readDouble(named: "F\(index)Mn") ?? 0,
                    maximum: smc.readDouble(named: "F\(index)Mx") ?? 0
                ))
            }
            if let power = smc.readDouble(named: "PSTR"), power >= 0, power < 500 {
                board = power
            }
        }
        return ThermalSample(
            available: !zones.isEmpty || !fans.isEmpty || board != nil,
            state: state,
            cpuAverage: average(cpuZones),
            cpuPeak: cpuZones.map(\.celsius).max(),
            gpuAverage: average(gpuZones),
            gpuPeak: gpuZones.map(\.celsius).max(),
            peak: zones.first,
            boardPower: board,
            fans: fans,
            zones: listedZones
        )
    }

    private func readProcesses(elapsed: Double, memoryTotal: UInt64) -> [ProcessSample] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let used = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard used > 0 else { return [] }
        let count = min(pids.count, Int(used) / MemoryLayout<pid_t>.stride)
        var rows: [ProcessSample] = []
        rows.reserveCapacity(count)
        var nextTimes: [Int32: UInt64] = [:]
        nextTimes.reserveCapacity(count)
        let taskStride = Int32(MemoryLayout<proc_taskinfo>.stride)
        for pid in pids.prefix(count) {
            var info = proc_taskinfo()
            let wrote = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, taskStride)
            let measured = wrote == taskStride
            // pid 0 is kernel_task. Unused buffer slots are also 0, so require a name.
            let hiddenName = measured ? nil : shortProcessName(pid)
            if !measured, hiddenName == nil { continue }
            let time = measured ? info.pti_total_user &+ info.pti_total_system : 0
            if measured { nextTimes[pid] = time }
            var cpu = 0.0
            if measured, elapsed > 0, let previous = previousProcessTime[pid], time >= previous {
                cpu = timebase.toSeconds(time &- previous) / elapsed * 100
            }
            let name = processName(pid, fallback: hiddenName)
            let resident = measured ? info.pti_resident_size : 0
            let fraction = measured && memoryTotal > 0 ? Double(resident) / Double(memoryTotal) : 0
            rows.append(ProcessSample(
                pid: pid,
                name: name,
                cpu: cpu,
                resident: resident,
                memoryFraction: fraction,
                threads: measured ? Int(info.pti_threadnum) : 0,
                measured: measured
            ))
        }
        previousProcessTime = nextTimes
        return rows
    }
}

func displayZones(_ thermal: ThermalSample, limit: Int) -> [ThermalZone] {
    guard limit > 0 else { return [] }
    var picked: [ThermalZone] = []
    let cpu = thermal.zones.filter { isCoreTemperatureKey($0.key) || ($0.group == .cpu && thermal.zones.allSatisfy { !isCoreTemperatureKey($0.key) }) }
    let cpuSorted = cpu.sorted { $0.celsius > $1.celsius }
    let gpuSorted = thermal.zones.filter { $0.group == .gpu }.sorted { $0.celsius > $1.celsius }
    let rest = thermal.zones.filter { zone in
        !cpuSorted.contains { $0.key == zone.key } && zone.group != .gpu
    }.sorted { $0.celsius > $1.celsius }

    let cpuSlots = min(cpuSorted.count, max(1, limit * 3 / 5))
    picked.append(contentsOf: cpuSorted.prefix(cpuSlots))
    var lastGPU: Double?
    for zone in gpuSorted {
        if picked.count >= limit { break }
        if let lastGPU, abs(zone.celsius - lastGPU) < 0.4 { continue }
        picked.append(zone)
        lastGPU = zone.celsius
        if picked.filter({ $0.group == .gpu }).count >= 2 { break }
    }
    for zone in rest {
        if picked.count >= limit { break }
        if picked.contains(where: { $0.group == zone.group && abs($0.celsius - zone.celsius) < 0.6 }) {
            continue
        }
        picked.append(zone)
    }
    return picked
}

private func processName(_ pid: pid_t, fallback: String? = nil) -> String {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &path, UInt32(path.count))
    if length > 0 {
        let full = decodeCString(path)
        if let leaf = full.split(separator: "/").last, !leaf.isEmpty {
            return String(leaf)
        }
    }
    var buffer = [CChar](repeating: 0, count: 256)
    if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
        let name = decodeCString(buffer)
        if !name.isEmpty { return name }
    }
    if let fallback, !fallback.isEmpty { return fallback }
    return "pid \(pid)"
}

/// Name macOS still exposes when task info is hidden. Empty when the pid is not real.
private func shortProcessName(_ pid: pid_t) -> String? {
    var info = proc_bsdshortinfo()
    let wrote = proc_pidinfo(
        pid,
        PROC_PIDT_SHORTBSDINFO,
        0,
        &info,
        Int32(MemoryLayout<proc_bsdshortinfo>.stride)
    )
    guard wrote == Int32(MemoryLayout<proc_bsdshortinfo>.stride) else { return nil }
    var bytes = [CChar](repeating: 0, count: MemoryLayout.size(ofValue: info.pbsi_comm) + 1)
    withUnsafeBytes(of: info.pbsi_comm) { raw in
        for (index, byte) in raw.enumerated() where index < bytes.count - 1 {
            bytes[index] = CChar(bitPattern: byte)
        }
    }
    let name = decodeCString(bytes)
    return name.isEmpty ? nil : name
}

private func interfaceCounters() -> [String: (UInt64, UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var needed: size_t = 0
    guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [:] }
    var buffer = [UInt8](repeating: 0, count: needed)
    let result = buffer.withUnsafeMutableBytes { raw in
        sysctl(&mib, 6, raw.baseAddress, &needed, nil, 0)
    }
    guard result == 0 else { return [:] }
    var counters: [String: (UInt64, UInt64)] = [:]
    var offset = 0
    let limit = min(needed, buffer.count)
    while offset + MemoryLayout<if_msghdr>.stride < limit {
        let length: Int = buffer.withUnsafeBytes { raw in
            Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
        if length <= 0 || offset + length > limit { break }
        let type = buffer[offset + 3]
        if type == UInt8(RTM_IFINFO2) {
            let header: if_msghdr2? = buffer.withUnsafeBytes { raw in
                guard offset + MemoryLayout<if_msghdr2>.size <= limit else { return nil }
                return raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            }
            if let header {
                let nameOffset = offset + MemoryLayout<if_msghdr2>.size
                if let name = interfaceName(buffer, offset: nameOffset, limit: offset + length),
                   !name.hasPrefix("lo") {
                    counters[name] = (header.ifm_data.ifi_ibytes, header.ifm_data.ifi_obytes)
                }
            }
        }
        offset += length
    }
    return counters
}

private func interfaceName(_ buffer: [UInt8], offset: Int, limit: Int) -> String? {
    guard offset + 8 <= limit else { return nil }
    let nameLength = Int(buffer[offset + 5])
    let start = offset + 8
    guard nameLength > 0, start + nameLength <= limit else { return nil }
    let bytes = buffer[start..<(start + nameLength)]
    return String(bytes: bytes, encoding: .utf8)
}

private func diskBytes() -> (read: UInt64, write: UInt64) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOBlockStorageDriver"),
        &iterator
    ) == kIOReturnSuccess else {
        return (0, 0)
    }
    defer { IOObjectRelease(iterator) }
    var read: UInt64 = 0
    var write: UInt64 = 0
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let stats = dictionary["Statistics"] as? [String: Any] else {
            continue
        }
        read &+= integer(stats["Bytes (Read)"])
        write &+= integer(stats["Bytes (Write)"])
    }
    return (read, write)
}

private func volumeUsage() -> (free: UInt64, total: UInt64) {
    guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
        return (0, 0)
    }
    let total = (attributes[.systemSize] as? NSNumber)?.uint64Value ?? 0
    let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
    return (free, total)
}

private func integer(_ value: Any?) -> UInt64 {
    switch value {
    case let number as NSNumber:
        return number.uint64Value
    case let number as UInt64:
        return number
    case let number as Int64:
        return UInt64(clamping: number)
    case let number as Int:
        return UInt64(clamping: number)
    default:
        return 0
    }
}

private func number(_ value: Any?) -> Double {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let number as Double:
        return number
    case let number as Int:
        return Double(number)
    default:
        return 0
    }
}

private func boolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let flag = value as? Bool { return flag }
    return false
}

private func optionalMinutes(_ value: Any?) -> Int? {
    let minutes = Int(number(value))
    guard minutes >= 0 else { return nil }
    return minutes
}

private func powerMinutes(_ value: Any?) -> Int? {
    let minutes = Int(number(value).rounded())
    guard minutes > 0, minutes < 65535 else { return nil }
    return minutes
}

private func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let parsed = number.intValue
    guard parsed >= 0, parsed < 20_000 else { return nil }
    return parsed
}

/// Battery pack power. The registry sometimes stores a negative milliwatt
/// reading as an unsigned 64-bit value.
private func packWatts(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    let bits = number.uint64Value
    let signed: Int64
    if number.doubleValue < 0 {
        signed = number.int64Value
    } else if bits > UInt64(Int64.max) {
        signed = Int64(bitPattern: bits)
    } else {
        signed = number.int64Value
    }
    let watts = abs(Double(signed)) / 1000
    guard watts.isFinite, watts < 250 else { return nil }
    return watts
}

private func packWatts(amperage: Any?, voltage: Any?) -> Double? {
    let amps = number(amperage)
    let volts = number(voltage)
    guard amps != 0, volts != 0 else { return nil }
    let watts = abs(amps * volts) / 1_000_000
    guard watts > 0, watts < 250 else { return nil }
    return watts
}

private func batteryTemperature(_ value: Any?) -> Double? {
    let raw = number(value)
    guard raw > 0 else { return nil }
    let celsius = raw > 200 ? raw / 100 : raw
    guard celsius > 0, celsius < 90 else { return nil }
    return celsius
}

private func percent(_ value: Any?) -> Double? {
    guard let value else { return nil }
    let parsed = number(value)
    guard parsed >= 0, parsed <= 100 else { return nil }
    return parsed / 100
}

private func maxOptional(_ current: Double?, _ next: Double?) -> Double? {
    switch (current, next) {
    case let (lhs?, rhs?):
        return max(lhs, rhs)
    case (nil, let rhs?):
        return rhs
    default:
        return current
    }
}

private func average(_ zones: [ThermalZone]) -> Double? {
    guard !zones.isEmpty else { return nil }
    return zones.reduce(0) { $0 + $1.celsius } / Double(zones.count)
}

private func pressureName(_ level: Int32) -> String {
    switch level {
    case 0, 1: "normal"
    case 2: "warning"
    case 4: "urgent"
    case 8: "critical"
    default: "level \(level)"
    }
}

private func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    default: "unknown"
    }
}

private func hidGroup(_ name: String) -> SensorGroup {
    let lower = name.lowercased()
    if lower.contains("gpu") { return .gpu }
    if lower.contains("battery") || lower.contains("batt") { return .battery }
    if lower.contains("nand") || lower.contains("ssd") { return .storage }
    if lower.contains("air") || lower.contains("skin") { return .skin }
    return .cpu
}

private func readUptime() -> TimeInterval {
    var boot = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
    return Date().timeIntervalSince1970 - Double(boot.tv_sec) - Double(boot.tv_usec) / 1_000_000
}

private func clusterPrefix(_ name: String, taken: inout Set<String>) -> String {
    let letters = name.uppercased().filter(\.isLetter)
    let first = letters.first.map(String.init) ?? "C"
    if taken.insert(first).inserted { return first }
    let two = String(letters.prefix(2))
    if two.count == 2, taken.insert(two).inserted { return two }
    var suffix = 2
    while true {
        let candidate = first + String(suffix)
        if taken.insert(candidate).inserted { return candidate }
        suffix += 1
    }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size + 1)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return decodeCString(buffer)
}

private func decodeCString(_ bytes: [CChar]) -> String {
    let data = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: data, as: UTF8.self)
}

private func sysctlUInt64(_ name: String) -> UInt64? {
    var wide: UInt64 = 0
    var wideSize = MemoryLayout<UInt64>.stride
    if sysctlbyname(name, &wide, &wideSize, nil, 0) == 0, wideSize == MemoryLayout<UInt64>.stride {
        return wide
    }
    var narrow: Int32 = 0
    var narrowSize = MemoryLayout<Int32>.stride
    guard sysctlbyname(name, &narrow, &narrowSize, nil, 0) == 0 else { return nil }
    return UInt64(narrow)
}

private struct MachTimebase {
    var numer: UInt32
    var denom: UInt32

    static func current() -> MachTimebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTimebase(numer: info.numer, denom: max(info.denom, 1))
    }

    func toSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numer) / Double(denom) / 1_000_000_000
    }
}

private func monotonicNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}
