import XCTest
@testable import SentinelCore

final class SecurityAgentsTests: XCTestCase {
    // Real output from a work Mac, tabs as systemextensionsctl prints them.
    let list = """
    4 extension(s)
    --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.96.5/101.96.5)\tTailscale Network Extension\t[activated enabled]
    *\t*\tC489D5E8E8\tcom.forcepoint.ne (23.01.00/404)\tForcepoint Neo NE\t[activated enabled]
    --- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions > Endpoint Security Extensions' to modify these system extension(s))
    enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
    \t\tX9E956P446\tcom.crowdstrike.falcon.Agent (7.40/212.04)\tFalcon Sensor\t[terminated waiting to uninstall on reboot]
    *\t*\tX9E956P446\tcom.crowdstrike.falcon.Agent (8.10/213.07)\tFalcon Sensor\t[activated enabled]
    *\t*\tABCDE12345\tcom.example.unknownwatcher.es (1.0/1)\tAcme File Watcher\t[activated enabled]
    """

    func testFindsExtensionsAndProcesses() {
        let a = SecurityAgents.find(extensions: list, processes: [("/Applications/Zscaler/Zscaler.app/Contents/PlugIns/ZscalerTunnel", 3),
                                                                   ("/Library/CS/falcond", 60), ("/bin/zsh", 90)])
        XCTAssertEqual(a.map(\.name), ["Forcepoint", "CrowdStrike Falcon", "Acme File Watcher", "Zscaler", "Tailscale"])
        let cs = a.first { $0.name == "CrowdStrike Falcon" }!
        XCTAssertTrue(cs.endpointSecurity)
        XCTAssertEqual(cs.cpu, 60)
        XCTAssertTrue(a.first { $0.name == "Forcepoint" }!.networkFilter)
        XCTAssertTrue(a.first { $0.name == "Acme File Watcher" }!.suspect, "an unknown Endpoint Security client is still a suspect")
        XCTAssertFalse(a.first { $0.name == "Tailscale" }!.suspect)
        XCTAssertEqual(cs.line, "CrowdStrike Falcon: endpoint protection, sees every file and program opened, 60% CPU now")
    }

    func testNoFalseMatches() {
        let a = SecurityAgents.find(extensions: "", processes: [
            ("/System/Library/PrivateFrameworks/RemoteManagement.framework/XPCServices/PasscodeSettingsSubscriber.xpc/Contents/MacOS/PasscodeSettingsSubscriber", 1),
            ("/Applications/Reset Tool.app/Contents/MacOS/Reset Tool", 1), ("/Applications/ESET Endpoint.app/Contents/MacOS/esets_daemon", 2)])
        XCTAssertEqual(a.map(\.name), ["ESET"])
    }

    func testAvaRevealByProcess() {
        let a = SecurityAgents.find(extensions: "", processes: [("/Library/Application Support/AvaSecurity/RevealAgent", 5)])
        XCTAssertEqual(a.map(\.name), ["Ava Reveal"])
        XCTAssertNotNil(SecurityAgents.suspectNote(a))
        XCTAssertNil(SecurityAgents.suspectNote(SecurityAgents.find(extensions: "", processes: [("tailscaled", 1)])))
    }
}
