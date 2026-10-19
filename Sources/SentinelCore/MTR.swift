import Foundation

/// One hop of an mtr-style route test: pinged once a round, so loss and delay build up over
/// time instead of a single traceroute's one guess.
public struct MTRHop: Equatable, Sendable, Identifiable {
    public let n: Int
    /// Nil when nothing at that distance answered the trace.
    public let address: String?
    public private(set) var sent = 0
    public private(set) var received = 0
    public private(set) var last: Double?
    public private(set) var best: Double?
    public private(set) var worst: Double?
    private var sum = 0.0
    private var sumSquares = 0.0

    public var id: Int { n }

    public init(n: Int, address: String?) { self.n = n; self.address = address }

    /// One ping's result: its round trip in ms, or nil when it got no answer.
    public mutating func record(_ ms: Double?) {
        sent += 1
        last = ms
        guard let ms else { return }
        received += 1
        sum += ms
        sumSquares += ms * ms
        best = min(best ?? ms, ms)
        worst = max(worst ?? ms, ms)
    }

    /// Share of pings lost, 0 to 100.
    public var loss: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }
    public var average: Double? { received == 0 ? nil : sum / Double(received) }
    /// How much the round trip varies (standard deviation), which is what makes calls choppy.
    public var jitter: Double? {
        guard received >= 2, let avg = average else { return nil }
        return (max(0, sumSquares / Double(received) - avg * avg)).squareRoot()
    }
}

public enum MTR {
    /// The round trip from one `ping -c 1`: "64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=4.625 ms".
    public static func pingMS(_ out: String) -> Double? {
        guard let r = out.range(of: #"time[=<]([0-9.]+) ?ms"#, options: .regularExpression) else { return nil }
        let s = out[r].drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        return Double(s)
    }

    /// The hops from a trace, without the run of silent hops at the end of one that never
    /// reached the target (all but the first, which shows where it stopped).
    public static func hops(from trace: [Hop]) -> [MTRHop] {
        var hops = trace
        while hops.count >= 2, hops[hops.count - 1].address == nil, hops[hops.count - 2].address == nil { hops.removeLast() }
        return hops.map { MTRHop(n: $0.n, address: $0.address) }
    }

    public struct Verdict: Equatable, Sendable {
        public enum Tone: Int, Sendable { case good, info, warning, bad }
        public let tone: Tone
        public let title: String
        public let detail: String
    }

    /// What the numbers mean, in a sentence. Loss only counts when it carries on to the end:
    /// routers often answer pings last, so loss at one hop that the hops after it do not
    /// share is the router being busy, not traffic being dropped.
    public static func verdict(_ hops: [MTRHop], isPrivate: (String) -> Bool = { _ in false }) -> Verdict? {
        let answering = hops.filter { $0.address != nil && $0.sent > 0 }
        guard let end = answering.last, end.sent >= 5 else { return nil }
        if end.received == 0 {
            return Verdict(tone: .bad, title: "The target never answered",
                           detail: "None of \(end.sent) pings came back. It may block pings, or the route breaks before it.")
        }
        if end.loss >= 2 {
            // The first hop from which every hop after it loses at least half as much.
            let from = answering.firstIndex { h in
                answering.drop { $0.n < h.n }.allSatisfy { $0.loss >= end.loss * 0.5 }
            } ?? answering.count - 1
            let h = answering[from]
            let local = h.address.map(isPrivate) ?? false || h.n == 1
            return Verdict(tone: end.loss >= 10 ? .bad : .warning,
                           title: String(format: "%.0f%% of packets lost, starting at hop %d", end.loss, h.n),
                           detail: local ? "It starts inside your own network: Wi-Fi, a cable or the router. Try a cable, or move closer to the router."
                                         : "It starts outside your network, at your provider or beyond. If it lasts, send the copied report to your provider.")
        }
        // A jump in delay that the hops after it keep.
        var prev: MTRHop?
        for h in answering {
            if let p = prev, let a = h.average, let b = p.average, a - b >= 60,
               answering.drop(while: { $0.n <= h.n }).allSatisfy({ ($0.average ?? 0) >= b + 50 }) {
                return Verdict(tone: .warning, title: String(format: "Delay jumps by %.0f ms at hop %d", a - b, h.n),
                               detail: "Everything after it is that much slower. Often a long distance link (another country or an undersea cable), sometimes a congested one.")
            }
            prev = h
        }
        if let j = end.jitter, j >= 30 {
            return Verdict(tone: .warning, title: String(format: "No loss, but the delay varies by %.0f ms", j),
                           detail: "Uneven timing makes calls and games choppy even when nothing is lost.")
        }
        let lossy = answering.dropLast().filter { $0.loss >= 10 }
        return Verdict(tone: .good, title: "Clean: no loss to the end",
                       detail: lossy.isEmpty ? String(format: "Nothing lost on the way, %.0f ms to the target on average.", end.average ?? 0)
                                             : "Hop \(lossy.map { String($0.n) }.joined(separator: ", ")) drops some pings, but the hops after it do not: routers answer pings last when busy. Traffic is fine.")
    }

    /// The table as plain text, like `mtr --report`.
    public static func report(target: String, address: String?, hops: [MTRHop], owners: [String: NetOwner], at date: Date) -> String {
        var s = "Route test to \(target)" + (address.map { $0 == target ? "" : " (\($0))" } ?? "") + ", \(date.formatted(date: .abbreviated, time: .shortened))\n"
        s += "  #  Host                                      Loss%   Sent   Last    Avg   Best  Worst  Jitter\n"
        let f: (Double?) -> String = { $0.map { String(format: "%6.1f", $0) } ?? "     -" }
        for h in hops {
            var host = h.address ?? "???"
            if let a = h.address, let o = owners[a] { host += " " + o.label }
            host = String(host.prefix(40)).padding(toLength: 40, withPad: " ", startingAt: 0)
            s += String(format: "%3d  ", h.n) + host + String(format: "  %5.1f  %5d ", h.loss, h.sent) + [f(h.last), f(h.average), f(h.best), f(h.worst), f(h.jitter)].joined(separator: " ") + "\n"
        }
        return s
    }
}
