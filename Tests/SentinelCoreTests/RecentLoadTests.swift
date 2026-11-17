import Foundation
import Testing
@testable import SentinelCore

@Suite struct RecentLoadTests {
    func p(_ pid: Int32, _ path: String, _ cpu: Double) -> ProcessSample { ProcessSample(pid: pid, uid: 501, cpu: cpu, path: path) }
    func ticks(user: UInt64, system: UInt64, idle: UInt64) -> [CoreLoad.Ticks] {
        [CoreLoad.Ticks(user: user, system: system, idle: idle, nice: 0)]
    }

    @Test func familiesAddUpShortLivedRuns() {
        let r = RecentLoad(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // A new ccusage pid in every sample, each at 120%: no single row stays, the family does.
        for i in 0..<10 {
            r.record([p(Int32(100 + i), "/opt/homebrew/lib/node_modules/ccusage/bin/ccusage", 120),
                      p(5, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 10)],
                     ticks: [], at: t0.addingTimeInterval(Double(i) * 5))
        }
        let rep = r.report(cores: 10, at: t0.addingTimeInterval(45))
        #expect(rep.families.first?.name == LoadFamily.claude)
        #expect(rep.families.first?.processes == 10)
        #expect(abs((rep.families.first?.cpu ?? 0) - 120) < 0.01)
        #expect(rep.families.contains { $0.name == "Google Chrome" })
    }

    @Test func unseenIsBusyMinusRows() {
        let r = RecentLoad(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        r.record([p(1, "/usr/libexec/nsurlsessiond", 50)], ticks: ticks(user: 0, system: 0, idle: 0), at: t0)
        // One core's worth of ticks, 30% user and 20% system: on 1 core that is 50% busy, 20% kernel.
        r.record([p(1, "/usr/libexec/nsurlsessiond", 10)], ticks: ticks(user: 30, system: 20, idle: 50), at: t0.addingTimeInterval(5))
        let rep = r.report(cores: 1, at: t0.addingTimeInterval(5))
        #expect(rep.busy == 50)
        #expect(rep.system == 20)
        #expect(rep.families.first?.name == LoadFamily.updates)
        #expect(rep.unseen == 20) // 50 busy, rows average 30
    }

    @Test func oldReadingsDrop() {
        let r = RecentLoad(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        r.record([p(1, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", 90)], ticks: [], at: t0)
        r.record([p(2, "/usr/bin/true", 0)], ticks: [], at: t0.addingTimeInterval(120))
        #expect(r.report(cores: 4, at: t0.addingTimeInterval(120)).families.isEmpty)
    }

    @Test func startsCountPidAdvanceAndStarterThroughShells() {
        let r = RecentLoad(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let claude = p(10, "/Users/a/.local/share/claude/versions/2.1.323", 5)
        let shell = p(20, "/bin/bash", 0)
        // bash (20) runs under claude (10); sleep 500 runs under bash.
        let parents: [Int32: Int32] = [20: 10, 100: 20, 500: 20, 10: 1]
        // An old process with a high pid must not hide the advance.
        let old = p(99_000, "/usr/sbin/old", 0)
        r.record([old, claude, shell], ticks: [], parent: { parents[$0] }, at: t0)
        r.record([old, claude, shell, p(100, "/bin/sleep", 0)], ticks: [], parent: { parents[$0] }, at: t0.addingTimeInterval(5))
        r.record([old, claude, shell, p(500, "/bin/sleep", 0)], ticks: [], parent: { parents[$0] }, at: t0.addingTimeInterval(10))
        let rep = r.report(cores: 4, at: t0.addingTimeInterval(10))
        #expect(rep.started == 400) // pids 101 to 500 were handed out, most never sampled
        #expect(rep.startedBy.first?.family == LoadFamily.claude)
        #expect(rep.startsPerSecond == 40)
    }

    @Test func startsAcrossThePidWrap() {
        let r = RecentLoad(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = p(5, "/bin/a", 0)
        r.record([a], ticks: [], parent: { _ in nil }, at: t0)
        r.record([a, p(99_990, "/bin/sleep", 0)], ticks: [], parent: { _ in nil }, at: t0.addingTimeInterval(5))
        r.record([a, p(20, "/bin/sleep", 0)], ticks: [], parent: { _ in nil }, at: t0.addingTimeInterval(10))
        #expect(r.report(cores: 4, at: t0.addingTimeInterval(10)).started == 29)
    }

    @Test func starterNamesTheLoopingScript() {
        let r = RecentLoad(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let term = p(10, "/Applications/Ghostty.app/Contents/MacOS/ghostty", 1)
        let panel = ProcessSample(pid: 20, uid: 501, cpu: 0, path: "/bin/bash", ppid: 10)
        let inline = ProcessSample(pid: 30, uid: 501, cpu: 0, path: "/bin/zsh", ppid: 10)
        let args: [Int32: [String]] = [20: ["bash", "/Users/a/.local/bin/ccusage-panel.sh", "10"], 30: ["zsh", "-c", "sleep 1"]]
        r.record([term, panel, inline], ticks: [], parent: { _ in nil }, arguments: { args[$0] ?? [] }, at: t0)
        r.record([term, panel, inline, ProcessSample(pid: 40, uid: 501, cpu: 0, path: "/bin/sleep", ppid: 20),
                  ProcessSample(pid: 41, uid: 501, cpu: 0, path: "/bin/sleep", ppid: 20),
                  ProcessSample(pid: 42, uid: 501, cpu: 0, path: "/bin/sleep", ppid: 30)],
                 ticks: [], parent: { _ in nil }, arguments: { args[$0] ?? [] }, at: t0.addingTimeInterval(5))
        let by = r.report(cores: 4, at: t0.addingTimeInterval(5)).startedBy
        #expect(by.first?.family == "ccusage-panel.sh")
        #expect(by.first?.count == 2)
        #expect(by.contains { $0.family == "Ghostty" }) // a -c shell passes on to its parent
    }

    @Test func levels() {
        func rep(busy: Double, sys: Double, started: Int = 0) -> RecentLoad.Report {
            RecentLoad.Report(span: 60, busy: busy, system: sys, families: [], unseen: 0, capacity: 1000, started: started, startedBy: [])
        }
        #expect(rep(busy: 200, sys: 50).level == .normal)
        #expect(rep(busy: 430, sys: 110, started: 39 * 60).level == .someWhatSlow)
        #expect(rep(busy: 710, sys: 190).level == .slow)
        #expect(rep(busy: 200, sys: 50, started: 174 * 60).level == .slow)
    }

    @Test func scriptFromArguments() {
        #expect(RecentLoad.script(["/bin/zsh", "/usr/local/libexec/x/lid-awake-root.sh", "watch"]) == "lid-awake-root.sh")
        #expect(RecentLoad.script(["bash", "-e", "run.sh"]) == "run.sh")
        #expect(RecentLoad.script(["zsh", "-c", "source x"]) == nil)
        #expect(RecentLoad.script(["-zsh"]) == nil)
    }

    @Test func classification() {
        #expect(LoadFamily.of(p(1, "/Users/a/.local/share/claude/versions/2.1.323", 1)).name == LoadFamily.claude)
        #expect(LoadFamily.of(p(1, "/Users/a/.local/bin/claude-burst", 1)).name == LoadFamily.claude)
        #expect(LoadFamily.of(p(1, "/System/Library/PrivateFrameworks/X/com.apple.StreamingUnzipService.privileged", 1)).name == LoadFamily.updates)
        #expect(LoadFamily.of(p(1, "/System/Library/Frameworks/CoreServices.framework/mdworker_shared", 1)).name == LoadFamily.indexing)
        #expect(LoadFamily.of(p(0, "kernel_task", 1)).name == LoadFamily.kernel)
    }
}

@Suite struct SwapActivityTests {
    func point(_ t: Int, inn: Double, out: Double, pressure: Int = 0) -> MemoryHistory.Point {
        MemoryHistory.Point(t: t, used: 0, compressed: 0, swap: 0, pressure: pressure, swapIn: inn, swapOut: out)
    }

    @Test func averagesAndLevels() {
        #expect(SwapActivity.of([]) == nil)
        let calm = SwapActivity.of([point(0, inn: 0, out: 1_000_000), point(60, inn: 1_000_000, out: 0)])
        #expect(calm?.rate == 1_000_000)
        #expect(calm?.level == .normal)
        #expect(SwapActivity.of([point(0, inn: 4_000_000, out: 4_000_000)])?.level == .someWhatSlow)
        #expect(SwapActivity.of([point(0, inn: 30_000_000, out: 0)])?.level == .slow)
        #expect(SwapActivity.of([point(0, inn: 0, out: 0, pressure: 2)])?.level == .slow)
    }
}
