import XCTest
@testable import SentinelCore

final class TweaksTests: XCTestCase {
    func testValues() {
        XCTAssertEqual(Tweak.Value.bool(true).args, ["-bool", "true"])
        XCTAssertEqual(Tweak.Value.double(0.1).args, ["-float", "0.1"])
        XCTAssertEqual(Tweak.Value.parse("1\n", like: .bool(false)), .bool(true))
        XCTAssertEqual(Tweak.Value.parse("0", like: .bool(true)), .bool(false))
        XCTAssertEqual(Tweak.Value.parse("scale\n", like: .string("")), .string("scale"))
        XCTAssertEqual(Tweak.Value.parse("6", like: .int(0)), .int(6))
        XCTAssertNil(Tweak.Value.parse("2026-10-19 defaults[1:2]\nThe domain/default pair of (com.apple.dock, x) does not exist\n", like: .bool(true)))
        XCTAssertNil(Tweak.Value.parse("", like: .int(0)))
    }

    func testOptimisedAndUndo() {
        let stage = Tweaks.named("stage")!
        XCTAssertTrue(stage.isOptimised(nil), "Stage Manager is off unless turned on")
        XCTAssertFalse(stage.isOptimised(.bool(true)))
        let transparency = Tweaks.named("transparency")!
        XCTAssertFalse(transparency.isOptimised(nil))
        XCTAssertTrue(transparency.isOptimised(.bool(true)))
        XCTAssertEqual(Tweaks.named("menuSpacing")?.hostArgs, ["-currentHost"])
        XCTAssertEqual(Set(Tweaks.all.map(\.id)).count, Tweaks.all.count, "ids are unique")

        var b = TweakBackup()
        b.save("minimise", was: .string("genie"), at: Date())
        b.save("minimise", was: .string("scale"), at: Date())
        XCTAssertEqual(b.original("minimise"), .some(.string("genie")), "a second apply never overwrites the original")
        b.save("exposeSpeed", was: nil, at: Date())
        XCTAssertTrue(b.has("exposeSpeed"))
        XCTAssertEqual(TweakUndo.plan(b.original("exposeSpeed") ?? nil), .delete, "a key we added is deleted, not set to a guess")
        XCTAssertEqual(TweakUndo.plan(b.original("minimise") ?? nil), .write(.string("genie")))
        let back = try? JSONDecoder().decode(TweakBackup.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        b.forget("minimise")
        XCTAssertFalse(b.has("minimise"))
    }

    func testDisplays() {
        let json = """
        {"SPDisplaysDataType":[{"spdisplays_ndrvs":[
          {"_name":"Color LCD","_spdisplays_pixels":"3420 x 2214","_spdisplays_resolution":"1710 x 1107 @ 60.00Hz",
           "spdisplays_connection_type":"spdisplays_internal","spdisplays_pixelresolution":"spdisplays_2880x1864Retina"},
          {"_name":"DELL U2723QE","_spdisplays_pixels":"3840 x 2160","_spdisplays_resolution":"1920 x 1080 @ 120.00Hz",
           "spdisplays_pixelresolution":"3840 x 2160"}]}]}
        """
        let d = DisplayPixels.parse(Data(json.utf8))
        XCTAssertEqual(d.count, 2)
        XCTAssertTrue(d[0].builtIn)
        XCTAssertEqual(d[0].overdraw ?? 0, 1.411, accuracy: 0.01, "More Space on the built-in screen")
        XCTAssertEqual(d[0].hz, 60)
        XCTAssertEqual(d[1].overdraw ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(d[1].hz, 120)
        XCTAssertEqual(DisplayPixels.parse(Data("{}".utf8)), [])
    }

    func testCandidates() {
        XCTAssertNotNil(BackgroundCandidates.note("swift-frontend")?.contains("compiler"))
        XCTAssertNil(BackgroundCandidates.note("Safari"))
    }

    func testExactMode() {
        let modes = [ModeSize(w: 1440, h: 900, pixelW: 2880, pixelH: 1800), ModeSize(w: 1440, h: 932, pixelW: 2880, pixelH: 1864),
                     ModeSize(w: 1710, h: 1107, pixelW: 3420, pixelH: 2214), ModeSize(w: 2880, h: 1864, pixelW: 2880, pixelH: 1864)]
        let i = ModeSize.exact(in: modes, native: (2880, 1864))
        XCTAssertEqual(i, 1, "the sharp Retina mode, not the tiny 1:1 one")
        XCTAssertEqual(modes[2].growth(to: modes[1]), 0.1875, accuracy: 0.001)
        XCTAssertNil(ModeSize.exact(in: [modes[2]], native: (2880, 1864)))
    }
}
