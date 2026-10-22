import Foundation

/// Power drawn by the CPU, the graphics chip, the Neural Engine and memory, from the
/// "Energy Model" counters Apple silicon keeps in IOReport. Unlike powermetrics it needs
/// no password. Nil on Intel Macs, where there are no such counters.
public final class PartPower: @unchecked Sendable {
    public struct Watts: Equatable, Sendable {
        public var cpu: Double?
        public var gpu: Double?
        /// The Neural Engine, which Core ML models run on.
        public var ane: Double?
        public var dram: Double?
        public init(cpu: Double? = nil, gpu: Double? = nil, ane: Double? = nil, dram: Double? = nil) {
            self.cpu = cpu; self.gpu = gpu; self.ane = ane; self.dram = dram
        }
        /// The parts this can see, added up.
        public var total: Double { [cpu, gpu, ane, dram].compactMap { $0 }.reduce(0, +) }
    }

    /// One counter's energy since the last reading.
    public struct Channel: Sendable {
        public let name: String
        public let unit: String
        public let value: Int64
        public init(name: String, unit: String, value: Int64) {
            self.name = name; self.unit = unit; self.value = value
        }
    }

    /// Adds the counters up by part. Names differ by chip: "CPU Energy" on most,
    /// "DIE_0_CPU Energy" on Ultra; "ANE", "ANE0" or "ANE0_0"; "DRAM" or "DRAM0".
    public static func watts(_ channels: [Channel], seconds: Double) -> Watts {
        guard seconds > 0 else { return Watts() }
        var w = Watts()
        func add(_ part: inout Double?, _ c: Channel) {
            let scale: Double
            switch c.unit.trimmingCharacters(in: .whitespaces) {
            case "mJ": scale = 1e-3
            case "uJ", "µJ": scale = 1e-6
            case "nJ": scale = 1e-9
            default: return
            }
            part = (part ?? 0) + Double(c.value) * scale / seconds
        }
        for c in channels {
            if c.name == "GPU Energy" { add(&w.gpu, c) }
            else if c.name.hasSuffix("CPU Energy") { add(&w.cpu, c) }
            else if c.name.hasPrefix("ANE") { add(&w.ane, c) }
            else if c.name.hasPrefix("DRAM") { add(&w.dram, c) }
        }
        return w
    }

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetInteger = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: GetString
    private let unitLabel: GetString
    private let integerValue: GetInteger
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var last: (sample: CFDictionary, at: Date)?

    /// Nil where IOReport or its Energy Model is missing.
    public init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let subscribe = sym("IOReportCreateSubscription", CreateSubscription.self),
              let samples = sym("IOReportCreateSamples", CreateSamples.self),
              let delta = sym("IOReportCreateSamplesDelta", CreateDelta.self),
              let name = sym("IOReportChannelGetChannelName", GetString.self),
              let unit = sym("IOReportChannelGetUnitLabel", GetString.self),
              let value = sym("IOReportSimpleGetIntegerValue", GetInteger.self),
              let wanted = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              CFDictionaryGetCount(wanted) > 0 else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = subscribe(nil, wanted, &subscribed, 0, nil)?.takeRetainedValue(),
              let chans = subscribed?.takeRetainedValue() else { return nil }
        createSamples = samples
        createDelta = delta
        channelName = name
        unitLabel = unit
        integerValue = value
        subscription = sub
        channels = chans
    }

    /// Watts since the last call; nil on the first.
    public func read(now: Date = Date()) -> Watts? {
        guard let sample = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { last = (sample, now) }
        guard let (previous, at) = last,
              let delta = createDelta(previous, sample, nil)?.takeRetainedValue(),
              let list = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        let found: [Channel] = list.compactMap { item in
            let d = item as CFDictionary
            guard let n = channelName(d)?.takeUnretainedValue() as String? else { return nil }
            return Channel(name: n, unit: (unitLabel(d)?.takeUnretainedValue() as String?) ?? "", value: integerValue(d, 0))
        }
        return Self.watts(found, seconds: now.timeIntervalSince(at))
    }
}
