import XCTest
@testable import SentinelCore

final class CompanyAgentTests: XCTestCase {
    func sample(_ path: String, uid: UInt32 = getuid()) -> ProcessSample { ProcessSample(pid: 4242, uid: uid, cpu: 90, path: path) }

    func testSecurityAndMDMAgentsAreNeverStopped() {
        for path in ["/Library/Intune/Microsoft Intune Agent.app/Contents/MacOS/IntuneMdmAgent",
                     "/Applications/Zscaler/Zscaler.app/Contents/MacOS/Zscaler",
                     "/Applications/Falcon.app/Contents/Resources/Falcon Notifications.app/Contents/MacOS/Falcon Notifications",
                     "/Library/Application Support/Forcepoint/Neo/fpneo",
                     "/usr/local/jamf/bin/jamf",
                     "/Applications/Company Portal.app/Contents/MacOS/Company Portal",
                     "/Library/Elastic/Agent/elastic-agent",
                     "/opt/rapid7/ir_agent/components/insight_agent/common/ir_agent",
                     "/Applications/QualysCloudAgent.app/Contents/MacOS/qualys-cloud-agent",
                     "/opt/osquery/lib/osquery.app/Contents/MacOS/osqueryd",
                     "/Applications/Cloudflare WARP.app/Contents/MacOS/CloudflareWARP",
                     "/Applications/Okta Verify.app/Contents/MacOS/Okta Verify"] {
            let s = sample(path)
            XCTAssertTrue(Safety.isCompanyAgent(s), path)
            XCTAssertFalse(Safety.canKillManually(s), path)
            XCTAssertFalse(Safety.canAutoKill(s), path)
            if case .refused = Killer.forceKill(s) {} else { XCTFail("force kill not refused: \(path)") }
            if case .refused = Killer.killProtectedAsAdmin(s) {} else { XCTFail("admin kill not refused: \(path)") }
        }
    }

    func testOrdinaryAppsAreNotCompanyAgents() {
        for path in ["/Applications/Slack.app/Contents/MacOS/Slack", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                     "/System/Library/CoreServices/PasscodeSettingsSubscriber"] {
            XCTAssertFalse(Safety.isCompanyAgent(sample(path)), path)
        }
    }
}

final class InternalNameTests: XCTestCase {
    func testInternalNamesStayInside() {
        let vpn = Resolver(domain: "corp.example.com", servers: ["10.0.0.1"], supplemental: true)
        var main = Resolver(domain: nil, servers: ["192.168.1.1"])
        main.searchDomains = ["bank.example"]
        let rs = [main, vpn]
        for n in ["jira", "jira.corp.example.com", "corp.example.com", "wiki.bank.example", "printer.local", "build.internal", "host.home.arpa"] {
            XCTAssertTrue(NetParse.isInternalName(n, resolvers: rs), n)
        }
        for n in ["www.apple.com", "example.com", "notcorp.example.com", "github.com"] {
            XCTAssertFalse(NetParse.isInternalName(n, resolvers: rs), n)
        }
    }

    func testTheOrganisationsOwnDomainsStayInsideOffTheVPN() {
        let main = Resolver(domain: nil, servers: ["192.168.1.1"])
        XCTAssertFalse(NetParse.isInternalName("jira.example.com", resolvers: [main]))
        for n in ["jira.example.com", "example.com", "JIRA.Example.com."] {
            XCTAssertTrue(NetParse.isInternalName(n, resolvers: [main], extra: ["example.com"]), n)
        }
        XCTAssertFalse(NetParse.isInternalName("notexample.com", resolvers: [main], extra: ["example.com"]))
    }
}
