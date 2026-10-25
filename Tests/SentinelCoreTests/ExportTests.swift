import XCTest
@testable import SentinelCore

final class ExportTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_748_772_000) // 2025-06-01T10:00:00Z

    func testCSVQuotesCommasQuotesAndLineBreaks() {
        let s = DataExport.csv(header: ["a", "b"], rows: [["plain", "has, comma"], ["say \"hi\"", "two\nlines"]])
        XCTAssertEqual(s, "a,b\r\nplain,\"has, comma\"\r\n\"say \"\"hi\"\"\",\"two\nlines\"\r\n")
    }

    func testNumbersUseADotAndDropTrailingZeros() {
        XCTAssertEqual(DataExport.num(12.5), "12.5")
        XCTAssertEqual(DataExport.num(3), "3")
        XCTAssertEqual(DataExport.num(0.1234), "0.123")
        XCTAssertEqual(DataExport.num(-0.0001), "0")
        XCTAssertEqual(DataExport.num(.nan), "")
    }

    func testTimesAreUTC() {
        XCTAssertEqual(DataExport.time(t0), "2025-06-01T10:00:00Z")
    }

    func testFilename() {
        XCTAssertEqual(DataExport.filename("history", .csv, at: t0), "System Sentinel history 2025-06-01.csv")
    }

    func testEventsCSVIsOnTheWholeMacScale() {
        let e = HistoryEntry(date: t0, kind: .killed, pid: 42, name: "Bad, App", path: "/Applications/Bad.app", cpu: 250, detail: "over 90%")
        let csv = DataExport.eventsCSV(DataExport.events([e], cores: 10))
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "time,kind,pid,name,path,cpu_percent_of_mac,detail")
        XCTAssertEqual(lines[1], "2025-06-01T10:00:00Z,killed,42,\"Bad, App\",/Applications/Bad.app,25,over 90%")
    }

    func testProcessesBusiestFirstWithMemoryInBytes() {
        let list = DataExport.processes([ProcessSample(pid: 1, uid: 0, cpu: 10, path: "/usr/sbin/a", rssKB: 2),
                                         ProcessSample(pid: 2, uid: 501, cpu: 400, path: "/b", rssKB: 1)],
                                        cores: 8, average: { $0.pid == 2 ? 200 : nil }, gpu: { $0 == 2 ? 12 : nil })
        XCTAssertEqual(list.map(\.pid), [2, 1])
        XCTAssertEqual(list[0].cpuPercentOfMac, 50)
        XCTAssertEqual(list[0].cpu15MinPercentOfMac, 25)
        XCTAssertEqual(list[1].user, "root")
        XCTAssertEqual(list[1].memoryBytes, 2048)
        let rows = DataExport.processesCSV(list).components(separatedBy: "\r\n")
        XCTAssertEqual(rows[0], "pid,name,path,user,cpu_percent_of_mac,cpu_15min_percent_of_mac,memory_bytes,gpu_percent")
        XCTAssertEqual(rows[2], "1,a,/usr/sbin/a,root,1.25,,2048,")
    }

    func testCPUPointsFromUsage() {
        let u = DailyUsage(fileURL: nil, maxStep: 3600)
        let s = [ProcessSample(pid: 1, uid: 501, cpu: 200, path: "/x")]
        u.record(s, at: t0)
        u.record(s, at: t0.addingTimeInterval(10))
        let p = DataExport.cpuPoints(u, cores: 4)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].bucketSeconds, 3600)
        XCTAssertEqual(p[0].percentOfMac, 50, accuracy: 0.01)
    }

    func testHistoryCSVIsLongFormatSortedByTime() {
        let h = DataExport.HistoryData(cores: 8,
            memory: [.init(time: t0.addingTimeInterval(60), usedBytes: 1, compressedBytes: 2, swapBytes: 3, pressure: "under pressure",
                           swapInBytesPerSecond: 0, swapOutBytesPerSecond: 0.5)],
            power: [.init(time: t0, watts: 7.25, onBattery: true, batteryPercent: 80, drainingOnPower: nil)])
        let lines = DataExport.historyCSV(h).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines[0], "time,metric,value,unit")
        XCTAssertEqual(lines[1], "2025-06-01T10:00:00Z,power,7.25,W")
        XCTAssertEqual(lines[2], "2025-06-01T10:00:00Z,on_battery,1,\"1 yes, 0 no\"")
        XCTAssertTrue(lines.contains("2025-06-01T10:01:00Z,memory_pressure,1,\"0 normal, 1 under pressure, 2 critical\""))
        XCTAssertEqual(lines.count, 1 + 3 + 6)
    }

    func testReportJSONRoundTrips() throws {
        let h = DataExport.HistoryData(cores: 8,
                                       cpu: [.init(time: t0, bucketSeconds: 60, percentOfMac: 12.5)],
                                       storage: [.init(time: t0, usedBytes: 10, freeBytes: 20, purgeableBytes: 5)],
                                       network: [.init(time: t0, downloadBytesPerSecond: 1000, uploadBytesPerSecond: 10)])
        let doc = ReportDocument.build(machine: "Mac", weekly: WeeklyReport.build(usage: DailyUsage(fileURL: nil), power: [], events: [], at: t0),
                                       today: ["Quiet"], battery: nil, projection: nil, sleep: nil, memory: nil, at: t0)
        let r = DataExport.Report(generated: t0, app: "0.8.35", macOS: "15.5", mac: "Mac16,1", cores: 8, memoryBytes: 1 << 34,
                                  summary: doc, history: h, events: [],
                                  processes: [.init(pid: 5, name: "x", path: "/x", user: "you", cpuPercentOfMac: 1, memoryBytes: 4096)])
        let data = try DataExport.json(r)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"generated\" : \"2025-06-01T10:00:00Z\""))
        XCTAssertFalse(r.summary.isEmpty)
        XCTAssertEqual(try DataExport.decode(DataExport.Report.self, from: data), r)
    }
}
