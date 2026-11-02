import XCTest
@testable import AIMeter

final class UpdateDownloadIntegrationTests: XCTestCase {
    /// Opt-in public release reads only; no GitHub login is used.
    /// Never install or launch the fetched app.
    func testReleaseDownloadMatchesPublishedDigest() async throws {
        guard ProcessInfo.processInfo.environment["AIMETER_UPDATE_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Set AIMETER_UPDATE_NETWORK_TEST=1 to verify the GitHub release download.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = try await UpdateService.latest(channel: .stable)
        let archive = directory.appendingPathComponent("update.zip")
        let result = try await UpdateService.download(release, to: archive)
        XCTAssertEqual(result.count, release.asset.size)
        XCTAssertEqual(result.sha256, release.asset.digest)
        XCTAssertTrue(result.data.isEmpty, "The download must stream to disk.")
        try UpdateArchive.validate(archive)
    }
}
