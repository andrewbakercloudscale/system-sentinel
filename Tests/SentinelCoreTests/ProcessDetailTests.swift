import XCTest
@testable import SentinelCore

final class ProcessDetailTests: XCTestCase {
    func testDescribeNamesTheScriptNotTheInterpreter() {
        let py = "/opt/homebrew/bin/Python"
        XCTAssertEqual(ProcessDetail.describe([py, ".venv/bin/exitrisk", "serve", "--no-browser"]), "exitrisk serve")
        XCTAssertEqual(ProcessDetail.describe([py, "-m", "http.server", "8931", "--bind", "127.0.0.1"]), "http.server 8931")
        XCTAssertEqual(ProcessDetail.describe([py, "-B", "-m", "linkedin_relay.service"]), "linkedin_relay.service")
        XCTAssertEqual(ProcessDetail.describe([py, "-c", "from multiprocessing.spawn import spawn_main"]), "worker (multiprocessing)")
        XCTAssertEqual(ProcessDetail.describe([py, "-c", "print(1)"]), "inline code")
        XCTAssertEqual(ProcessDetail.describe([py]), "Python")
        XCTAssertEqual(ProcessDetail.describe([]), "unknown")
    }

    func testParseProcArgs() {
        var b: [UInt8] = [2, 0, 0, 0]
        for (s, pad) in [("/usr/bin/python3", 3), ("python3", 1), ("app.py", 1), ("PATH=/bin", 1)] {
            b.append(contentsOf: Array(s.utf8))
            b.append(contentsOf: [UInt8](repeating: 0, count: pad))
        }
        XCTAssertEqual(ProcessDetail.parseProcArgs(b), ["python3", "app.py"])
    }

    func testWorkersJoinTheirParentsJob() {
        let py = "/opt/homebrew/bin/Python"
        let r = [
            ProcessDetail.Reading(pid: 10, args: [py, ".venv/bin/exitrisk", "serve"], folder: "/Users/me/risk", bytes: 100, outOfRAM: 50),
            ProcessDetail.Reading(pid: 11, args: [py, "-c", "from multiprocessing.spawn import spawn_main"], folder: "/Users/me/risk", bytes: 900, outOfRAM: 800),
            ProcessDetail.Reading(pid: 20, args: [py, "-m", "http.server", "8931"], folder: "/tmp", bytes: 300, outOfRAM: 0),
        ]
        let jobs = ProcessDetail.jobs(r, parent: { $0 == 11 ? 10 : nil }, home: "/Users/me")
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs[0].what, "exitrisk serve")
        XCTAssertEqual(jobs[0].folder, "~/risk")
        XCTAssertEqual(jobs[0].pids, [10, 11])
        XCTAssertEqual(jobs[0].bytes, 1000)
        XCTAssertEqual(jobs[0].outOfRAM, 850)
        XCTAssertEqual(jobs[1].what, "http.server 8931")

        let mcp = (1...3).map { ProcessDetail.Reading(pid: Int32(30 + $0), args: [py, "-m", "relay.mcp"], folder: "/w/\($0)", bytes: 1, outOfRAM: 0) }
        XCTAssertEqual(ProcessDetail.jobs(mcp).map(\.folder), ["in 3 folders"])
    }

    func testReadsThisProcess() {
        XCTAssertFalse(ProcessDetail.arguments(getpid()).isEmpty)
        XCTAssertEqual(ProcessDetail.folder(getpid()), FileManager.default.currentDirectoryPath)
        XCTAssertEqual(ProcessDetail.parent(getpid()), getppid())
        XCTAssertNotNil(MemoryStatus.pageins(getpid()))
    }
}
