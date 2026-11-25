import Foundation
import IOKit

/// The System Management Controller's sensors, read through AppleSMC's user client. No
/// password. On Apple silicon the CPU core sensors are "Tp…" (performance) and "Te…"
/// (efficiency), the graphics cores "Tg…", each a 32-bit float in °C.
public final class SMC: @unchecked Sendable {
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    /// SMCKeyData_t, laid out as the kernel expects: 80 bytes.
    private struct Param {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var pLimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        var info = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    }
    private static let readKey: UInt8 = 5, readIndex: UInt8 = 8, readInfo: UInt8 = 9
    private static let flt = fourcc("flt ")

    private var conn: io_connect_t = 0
    private let lock = NSLock()
    /// The float sensors found once at start: key to its size.
    private var cpuKeys: [UInt32] = [], gpuKeys: [UInt32] = []

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        findSensors()
        if cpuKeys.isEmpty && gpuKeys.isEmpty { IOServiceClose(conn); return nil }
    }

    deinit { IOServiceClose(conn) }

    static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func name(_ k: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((k >> $0) & 0xff) }, as: UTF8.self)
    }

    private func call(_ p: inout Param) -> Bool {
        var out = Param()
        var size = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(conn, 2, &p, MemoryLayout<Param>.stride, &out, &size)
        p = out
        return r == kIOReturnSuccess && out.result == 0
    }

    private func info(_ key: UInt32) -> KeyInfo? {
        var p = Param(); p.key = key; p.data8 = Self.readInfo
        return call(&p) ? p.info : nil
    }

    private func float(_ key: UInt32) -> Double? {
        var p = Param(); p.key = key; p.info.dataSize = 4; p.data8 = Self.readKey
        guard call(&p) else { return nil }
        let v = withUnsafeBytes(of: p.bytes) { $0.load(as: Float.self) }
        return v.isFinite ? Double(v) : nil
    }

    private func findSensors() {
        guard let countInfo = info(Self.fourcc("#KEY")) else { return }
        var p = Param(); p.key = Self.fourcc("#KEY"); p.info.dataSize = countInfo.dataSize; p.data8 = Self.readKey
        guard call(&p) else { return }
        let count = withUnsafeBytes(of: p.bytes) { b in UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) }
        for i in 0..<min(count, 10_000) {
            var k = Param(); k.data8 = Self.readIndex; k.data32 = i
            guard call(&k) else { continue }
            let n = Self.name(k.key)
            let cpu = n.hasPrefix("Tp") || n.hasPrefix("Te"), gpu = n.hasPrefix("Tg")
            guard cpu || gpu, let ki = info(k.key), ki.dataType == Self.flt, ki.dataSize == 4 else { continue }
            if cpu { cpuKeys.append(k.key) } else { gpuKeys.append(k.key) }
        }
    }

    /// The hottest CPU core and the hottest graphics core, in °C. Readings outside 1 to 150
    /// are unused sensors.
    public func temperatures() -> (cpu: Double?, gpu: Double?) {
        lock.lock(); defer { lock.unlock() }
        func hottest(_ keys: [UInt32]) -> Double? { keys.compactMap(float).filter { $0 > 1 && $0 < 150 }.max() }
        return (hottest(cpuKeys), hottest(gpuKeys))
    }
}
