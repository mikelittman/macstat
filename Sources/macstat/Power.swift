import Darwin
import Foundation

/// CPU, GPU, memory, display, and Neural Engine power from the energy model.
///
/// libIOReport is a private system library. The counters are cumulative energy.
/// On Apple silicon they can sit still for a long time, then jump. A flat
/// counter has no new sample, so it is not shown as zero watts. The first jump
/// is ignored because it can include energy from before this process started.
/// Later jumps are averaged over the gap since the previous jump, and that
/// rate stays on screen until the next one.
struct ComponentPower: Sendable {
    var cpu: Double?
    var gpu: Double?
    var dram: Double?
    var ane: Double?
    var display: Double?

    var isEmpty: Bool {
        cpu == nil && gpu == nil && dram == nil && ane == nil && display == nil
    }
}

final class EnergyModel {
    private struct Mark {
        var joules: Double
        var nanos: UInt64
        /// Set after one real increase has been seen and discarded.
        var primed: Bool
    }

    private let subscription: UnsafeMutableRawPointer
    private let channels: CFMutableDictionary
    private let samples: @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, CFTypeRef?) -> CFDictionary?
    private let iterate: @convention(c) (CFDictionary?, @convention(block) (CFDictionary) -> Int32) -> Void
    private let channelName: @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private let unitLabel: @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
    private let simple: @convention(c) (CFDictionary?, Int32) -> Int64
    private var marks: [String: Mark] = [:]
    private var watts: [String: Double] = [:]
    private var names = Set<String>()

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        typealias CopyFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> CFMutableDictionary?
        typealias SubFn = @convention(c) (
            UnsafeMutableRawPointer?,
            CFMutableDictionary?,
            UnsafeMutablePointer<CFMutableDictionary?>?,
            UInt64,
            CFTypeRef?
        ) -> UnsafeMutableRawPointer?
        typealias SamplesFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary?, CFTypeRef?) -> CFDictionary?
        typealias IterateFn = @convention(c) (CFDictionary?, @convention(block) (CFDictionary) -> Int32) -> Void
        typealias NameFn = @convention(c) (CFDictionary?) -> Unmanaged<CFString>?
        typealias IntFn = @convention(c) (CFDictionary?, Int32) -> Int64

        func load<T>(_ symbol: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, symbol) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let copy: CopyFn = load("IOReportCopyChannelsInGroup", as: CopyFn.self),
              let subscribe: SubFn = load("IOReportCreateSubscription", as: SubFn.self),
              let samples: SamplesFn = load("IOReportCreateSamples", as: SamplesFn.self),
              let iterate: IterateFn = load("IOReportIterate", as: IterateFn.self),
              let channelName: NameFn = load("IOReportChannelGetChannelName", as: NameFn.self),
              let unitLabel: NameFn = load("IOReportChannelGetUnitLabel", as: NameFn.self),
              let simple: IntFn = load("IOReportSimpleGetIntegerValue", as: IntFn.self),
              let found = copy("Energy Model" as CFString, nil, 0, 0, 0) else {
            return nil
        }
        var subscribed: CFMutableDictionary?
        guard let subscription = subscribe(nil, found, &subscribed, 0, nil), let subscribed else { return nil }
        self.subscription = subscription
        self.channels = subscribed
        self.samples = samples
        self.iterate = iterate
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.simple = simple
    }

    func read(now: UInt64) -> ComponentPower {
        guard let sample = samples(subscription, channels, nil) else { return current }
        let readings = joules(in: sample)
        names.formUnion(readings.keys)
        for (name, joules) in readings {
            guard joules >= 0 else { continue }
            if let mark = marks[name] {
                if joules + 0.000_000_1 < mark.joules {
                    marks[name] = Mark(joules: joules, nanos: now, primed: false)
                    continue
                }
                let elapsed = Double(now &- mark.nanos) / 1_000_000_000
                if joules > mark.joules, elapsed >= 0.5 {
                    if mark.primed {
                        let rate = (joules - mark.joules) / elapsed
                        if rate >= 0, rate < 250 { watts[name] = rate }
                    }
                    marks[name] = Mark(joules: joules, nanos: now, primed: true)
                }
            } else {
                marks[name] = Mark(joules: joules, nanos: now, primed: false)
            }
        }
        return current
    }

    private var current: ComponentPower {
        let gpu = names.contains("GPU0") ? watts["GPU0"] : watts["GPU Energy"]
        return ComponentPower(
            cpu: watts["CPU Energy"],
            gpu: gpu,
            dram: watts["DRAM0"],
            ane: watts["ANE0"],
            display: watts["DISP0"]
        )
    }

    private func joules(in sample: CFDictionary) -> [String: Double] {
        let wanted: Set<String> = ["CPU Energy", "GPU0", "GPU Energy", "DRAM0", "ANE0", "DISP0"]
        let found = ReadingBucket()
        iterate(sample) { channel in
            guard let name = self.text(self.channelName(channel)), wanted.contains(name) else { return 0 }
            guard let unit = self.text(self.unitLabel(channel)),
                  let joules = Self.joules(raw: self.simple(channel, 0), unit: unit) else {
                return 0
            }
            found.values[name] = joules
            return 0
        }
        return found.values
    }

    private func text(_ value: Unmanaged<CFString>?) -> String? {
        guard let value else { return nil }
        let string = value.takeUnretainedValue()
        if let pointer = CFStringGetCStringPtr(string, CFStringBuiltInEncodings.UTF8.rawValue) {
            return String(cString: pointer)
        }
        var buffer = [CChar](repeating: 0, count: 128)
        guard CFStringGetCString(string, &buffer, buffer.count, CFStringBuiltInEncodings.UTF8.rawValue) else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func joules(raw: Int64, unit: String) -> Double? {
        guard raw >= 0 else { return nil }
        let scale: Double
        switch unit {
        case "J": scale = 1
        case "mJ": scale = 1_000
        case "uJ": scale = 1_000_000
        case "nJ": scale = 1_000_000_000
        default: return nil
        }
        return Double(raw) / scale
    }
}

private final class ReadingBucket {
    var values: [String: Double] = [:]
}
