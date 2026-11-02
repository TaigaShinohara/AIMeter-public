import XCTest
@testable import AIMeter

final class AntigravityQuotaClientTests: XCTestCase {
    func testDiscoveryUsesOnlySameOwnerPositiveProcessIdentifiers() {
        let listing = " 12 501\n13 502\n0 501\n-1 501\n14 501 unexpected\n15 501\n"
        XCTAssertEqual(AntigravityQuotaClient.processIdentifiers(in: listing, uid: 501), [12, 15])
    }

    func testPortOwnershipAndLoopbackAddressesAreRequired() {
        let listing = """
        p12
        f7
        tIPv4
        n127.0.0.1:1234
        f8
        tIPv6
        n[::1]:1234
        f9
        tIPv4
        n*:2345
        n192.168.1.2:3456
        n127.0.0.1:0
        n127.0.0.1:65536
        p99
        n127.0.0.1:4567
        """
        XCTAssertEqual(AntigravityQuotaClient.ownedListeningPorts(in: listing, pid: 12), [1234, 2345])
        XCTAssertTrue(AntigravityQuotaClient.ownedListeningPorts(in: listing, pid: 13).isEmpty)
    }

    func testPortDiscoveryHasAFiniteCandidateBudget() {
        let listing = "p12\n" + (1...20).map { "f\($0)\ntIPv4\nn127.0.0.1:\($0)" }.joined(separator: "\n")
        XCTAssertEqual(AntigravityQuotaClient.ownedListeningPorts(in: listing, pid: 12).count, 8)
    }

    func testIPv6AndUnknownFamilyCannotAuthorizeAnIPv4Request() {
        for listener in ["f1\ntIPv6\nn[::1]:1234", "f1\ntIPv6\nn*:1234",
                         "f1\ntIPv6\nn[::]:1234", "f1\nn127.0.0.1:1234",
                         "f1\ntIPv4\nn[::ffff:127.0.0.1]:1234",
                         "f1\ntIPv4\nn127.0.0.2:1234",
                         "f1\ntIPv4\nn127.0.0.1:1\nf2\nn*:1234"] {
            XCTAssertFalse(AntigravityQuotaClient.ownedListeningPorts(in: "p12\n" + listener, pid: 12).contains(1234))
        }
        XCTAssertEqual(AntigravityQuotaClient.ownedListeningPorts(in: "p12\nf1\ntIPv4\nn0.0.0.0:1234", pid: 12), [1234])
    }

    func testFlagsAcceptBothSpellingsButRejectAmbiguousOrSimilarNames() {
        XCTAssertEqual(AntigravityQuotaClient.flag("csrf_token", in: "app --csrf_token synthetic-token"), "synthetic-token")
        XCTAssertEqual(AntigravityQuotaClient.flag("csrf_token", in: "app --csrf_token=synthetic-token"), "synthetic-token")
        XCTAssertNil(AntigravityQuotaClient.flag("csrf_token", in: "app --other_csrf_token synthetic-token"))
        XCTAssertNil(AntigravityQuotaClient.flag("csrf_token", in: "app --csrf_token"))
        XCTAssertNil(AntigravityQuotaClient.flag("csrf_token", in: "app --csrf_token one --csrf_token=two"))
    }

    func testCredentialsCannotInjectHeadersAndAreBounded() {
        XCTAssertTrue(AntigravityQuotaClient.isSafeToken("synthetic-token_0123.abcd="))
        for invalid in ["", "a\r\nInjected: yes", "a b", "日本語", String(repeating: "a", count: 4097)] {
            XCTAssertFalse(AntigravityQuotaClient.isSafeToken(invalid))
        }
    }

    func testErrorsExposeOnlyFixedActionableDescriptions() {
        let failures: [AntigravityQuotaClient.Failure] = [
            .notRunning, .untrustedProcess, .missingToken, .unavailable, .connection, .invalidResponse, .limit
        ]
        for failure in failures {
            XCTAssertFalse(failure.localizedDescription.isEmpty)
            XCTAssertFalse(failure.localizedDescription.contains("http"))
            XCTAssertFalse(failure.localizedDescription.contains("csrf"))
        }
    }
}
