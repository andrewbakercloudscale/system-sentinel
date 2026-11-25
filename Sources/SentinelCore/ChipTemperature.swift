import Foundation
import IOKit

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// Temperatures from the chip's own sensors, read the way Activity Monitor's tools do
/// (the HID event system): no password. Apple silicon only; nil where there are none.
public struct ChipTemperature: Equatable, Sendable {
    /// The CPU clusters' sensors (pACC/eACC on M1 to M4), hottest. nil where the chip
    /// does not label them (the M5 reports only unlabelled die sensors).
    public var cpu: Double?
    /// The graphics chip's sensor, where labelled.
    public var gpu: Double?
    /// The hottest sensor on the chip's die: always there on Apple silicon.
    public var die: Double?

    public init(cpu: Double? = nil, gpu: Double? = nil, die: Double? = nil) { self.cpu = cpu; self.gpu = gpu; self.die = die }

    /// Sorts sensor readings by name into CPU, GPU and die. Readings below 0 or above 150
    /// are calibration values, not temperatures.
    public static func of(_ readings: [(name: String, celsius: Double)]) -> ChipTemperature {
        var t = ChipTemperature()
        func up(_ v: inout Double?, _ c: Double) { v = max(v ?? c, c) }
        for r in readings where r.celsius > 0 && r.celsius < 150 {
            let n = r.name
            if n.contains("pACC") || n.contains("eACC") || n.hasPrefix("CPU") { up(&t.cpu, r.celsius) }
            else if n.hasPrefix("GPU") { up(&t.gpu, r.celsius) }
            if n.contains("tdie") || n.contains("MTR") || n.contains("SOC") { up(&t.die, r.celsius) }
        }
        if t.die == nil { t.die = [t.cpu, t.gpu].compactMap { $0 }.max() }
        return t
    }

    /// Opened once: finding the sensors walks every SMC key.
    nonisolated(unsafe) private static let smc = SMC()

    /// The SMC's CPU and graphics core sensors where it has them (M1 to M5), else the die
    /// sensors of the HID event system.
    public static func read() -> ChipTemperature? {
        var t = readHID() ?? ChipTemperature()
        if let s = smc?.temperatures() {
            if let c = s.cpu { t.cpu = c }
            if let g = s.gpu { t.gpu = g }
        }
        if t.die == nil { t.die = [t.cpu, t.gpu].compactMap { $0 }.max() }
        return t.die == nil ? nil : t
    }

    static func readHID() -> ChipTemperature? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Apple's vendor page, temperature sensors.
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }
        var readings: [(name: String, celsius: Double)] = []
        let temperature: Int64 = 15
        for s in services {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let e = IOHIDServiceClientCopyEvent(s, temperature, 0, 0)?.takeRetainedValue() else { continue }
            readings.append((name, IOHIDEventGetFloatValue(e, Int32(temperature << 16))))
        }
        let t = of(readings)
        return t.die == nil ? nil : t
    }
}
