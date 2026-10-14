import Darwin
import Foundation

/// Apple Silicon temperature fallback for machines whose SMC does not publish
/// thermal keys. The HID event symbols are private, so they are resolved at
/// runtime and this reader stays quiet when they are missing.
final class HIDTemperatures {
    private typealias Client = OpaquePointer
    private typealias Service = OpaquePointer
    private typealias Event = OpaquePointer
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Client?
    private typealias MatchFn = @convention(c) (Client, CFDictionary) -> Int32
    private typealias ServicesFn = @convention(c) (Client) -> Unmanaged<CFArray>?
    private typealias PropertyFn = @convention(c) (Service, CFString) -> Unmanaged<CFTypeRef>?
    private typealias EventFn = @convention(c) (Service, Int64, Int32, Int64) -> Event?
    private typealias FloatFn = @convention(c) (Event, Int32) -> Double

    private let handle: UnsafeMutableRawPointer?
    private let create: CreateFn?
    private let match: MatchFn?
    private let services: ServicesFn?
    private let property: PropertyFn?
    private let event: EventFn?
    private let floatValue: FloatFn?

    init() {
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        create = HIDTemperatures.symbol(handle, "IOHIDEventSystemClientCreate")
        match = HIDTemperatures.symbol(handle, "IOHIDEventSystemClientSetMatching")
        services = HIDTemperatures.symbol(handle, "IOHIDEventSystemClientCopyServices")
        property = HIDTemperatures.symbol(handle, "IOHIDServiceClientCopyProperty")
        event = HIDTemperatures.symbol(handle, "IOHIDServiceClientCopyEvent")
        floatValue = HIDTemperatures.symbol(handle, "IOHIDEventGetFloatValue")
    }

    func read() -> [(name: String, celsius: Double)] {
        guard let create, let match, let services, let property, let event, let floatValue,
              let client = create(kCFAllocatorDefault) else {
            return []
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(client)).release() }

        let matching = [
            "PrimaryUsagePage": NSNumber(value: 0xff00),
            "PrimaryUsage": NSNumber(value: 5),
        ] as CFDictionary
        _ = match(client, matching)
        guard let copied = services(client)?.takeRetainedValue() else { return [] }

        var readings: [(String, Double)] = []
        let count = CFArrayGetCount(copied)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(copied, index) else { continue }
            let service = OpaquePointer(raw)
            let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "sensor"
            guard let temperatureEvent = event(service, 15, 0, 0) else { continue }
            let celsius = floatValue(temperatureEvent, 15 << 16)
            Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(temperatureEvent)).release()
            guard celsius > 0, celsius < 150 else { continue }
            readings.append((name, celsius))
        }
        return readings.sorted { $0.0 < $1.0 }
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
