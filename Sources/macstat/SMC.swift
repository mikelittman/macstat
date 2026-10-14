import Darwin
import Foundation
import IOKit

/// Userspace view of the AppleSMC parameter block.
///
/// The kernel expects this exact 80-byte layout, including the padding that
/// keeps `result` aligned with the C struct. A size mismatch makes every read
/// fail, so the connection refuses to open when the layout drifts.
struct SMCKeyData {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct Limit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    var key: UInt32 = 0
    var version = Version()
    var limit = Limit()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

struct SMCSensorKey: Sendable {
    var name: String
    var code: UInt32
    var size: UInt32
    var type: String
}

final class SMC {
    private var connection: io_connect_t = 0

    init?() {
        guard MemoryLayout<SMCKeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { return nil }
        connection = opened
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func temperatureKeys() -> [SMCSensorKey] {
        guard let total = keyCount() else { return [] }
        var found: [SMCSensorKey] = []
        found.reserveCapacity(64)
        for index in 0..<total {
            guard let name = keyName(at: index), name.first == "T" else { continue }
            guard let sensor = sensorKey(named: name) else { continue }
            guard let value = readDouble(sensor), value > 0, value < 150 else { continue }
            found.append(sensor)
        }
        return found
    }

    func sensorKey(named name: String) -> SMCSensorKey? {
        guard name.utf8.count == 4 else { return nil }
        var input = SMCKeyData()
        input.key = fourCC(name)
        input.data8 = 9
        guard let output = call(&input), output.result == 0 else { return nil }
        let size = output.info.dataSize
        guard size > 0, size <= 32 else { return nil }
        let type = fourCCString(output.info.dataType)
        guard !type.isEmpty else { return nil }
        return SMCSensorKey(name: name, code: input.key, size: size, type: type)
    }

    func readDouble(_ sensor: SMCSensorKey) -> Double? {
        guard let bytes = readBytes(sensor) else { return nil }
        return SMC.decode(type: sensor.type, bytes: bytes)
    }

    func readDouble(named name: String) -> Double? {
        guard let sensor = sensorKey(named: name) else { return nil }
        return readDouble(sensor)
    }

    private func keyCount() -> Int? {
        guard let value = readDouble(named: "#KEY") else { return nil }
        let count = Int(value)
        return count > 0 ? count : nil
    }

    private func keyName(at index: Int) -> String? {
        var input = SMCKeyData()
        input.data8 = 8
        input.data32 = UInt32(index)
        guard let output = call(&input), output.result == 0, output.key != 0 else { return nil }
        let name = fourCCString(output.key)
        return name.utf8.count == 4 ? name : nil
    }

    private func readBytes(_ sensor: SMCSensorKey) -> [UInt8]? {
        var input = SMCKeyData()
        input.key = sensor.code
        input.data8 = 5
        input.info.dataSize = sensor.size
        guard let output = call(&input), output.result == 0 else { return nil }
        let count = Int(sensor.size)
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(count)) }
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess else { return nil }
        return output
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let value: Float = bytes.withUnsafeBytes { $0.load(as: Float.self) }
            guard value.isFinite else { return nil }
            return Double(value)
        case "sp78":
            return fixed(bytes, divisor: 256)
        case "sp87":
            return fixed(bytes, divisor: 128)
        case "sp96":
            return fixed(bytes, divisor: 64)
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "ui8 ", "ui8":
            guard let byte = bytes.first else { return nil }
            return Double(byte)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let value = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(value)
        default:
            return nil
        }
    }

    private static func fixed(_ bytes: [UInt8], divisor: Double) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Double(raw) / divisor
    }
}

func fourCC(_ text: String) -> UInt32 {
    text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func fourCCString(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}
