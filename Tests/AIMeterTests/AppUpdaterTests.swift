import XCTest
@testable import AIMeter

final class AppUpdaterTests: XCTestCase {
    private func release(tag: String = "v1.2.0", prerelease: Bool = false,
                         url: String? = nil, digest: String? = "sha256:" + String(repeating: "a", count: 64), size: Int = 500) -> [String: Any] {
        var asset: [String: Any] = ["id": 12345, "name": "AIMeter-1.2.0-macos-universal.zip", "size": size,
            "browser_download_url": url ?? "https://github.com/TaigaShinohara/AIMeter-public/releases/download/\(tag)/AIMeter-1.2.0-macos-universal.zip"]
        if let digest { asset["digest"] = digest }
        return ["tag_name": tag, "draft": false, "prerelease": prerelease, "assets": [asset]]
    }
    private func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testStableReleaseUsesExactRepositoryAssetAndDigest() throws {
        let parsed = try UpdateService.parse(encoded(release(digest: "sha256:" + String(repeating: "a", count: 64))), channel: .stable)
        XCTAssertEqual(parsed.version, "1.2.0")
        XCTAssertNil(parsed.build)
        XCTAssertEqual(parsed.asset.digest, String(repeating: "a", count: 64))
        XCTAssertEqual(parsed.asset.size, 500)
        XCTAssertEqual(parsed.asset.id, 12345)
    }

    func testDevelopmentDoesNotSelectStableAndValidatesBuildTag() throws {
        let parsed = try UpdateService.parse(encoded([release(), release(tag: "v1.2.0-dev.22", prerelease: true)]), channel: .development)
        XCTAssertEqual(parsed.build, "22")
        XCTAssertThrowsError(try UpdateService.parse(encoded([release()]), channel: .development))
        for tag in ["v1.2.0-beta", "v1.2.0-dev.0", "v1.2.0-dev.22/other"] {
            XCTAssertThrowsError(try UpdateService.parse(encoded([release(tag: tag, prerelease: true)]), channel: .development))
        }
    }

    func testReleaseMetadataRefusesDraftsUnexpectedURLsAndUnboundedAssets() throws {
        for url in ["http://github.com/TaigaShinohara/AIMeter-public/releases/download/v1.2.0/AIMeter-1.2.0-macos-universal.zip",
                    "https://github.com.evil.invalid/TaigaShinohara/AIMeter-public/releases/download/v1.2.0/AIMeter-1.2.0-macos-universal.zip",
                    "https://github.com/Someone/AIMeter/releases/download/v1.2.0/AIMeter-1.2.0-macos-universal.zip",
                    "https://user:password@github.com/TaigaShinohara/AIMeter-public/releases/download/v1.2.0/AIMeter-1.2.0-macos-universal.zip",
                    "https://github.com/TaigaShinohara/AIMeter-public/releases/download/v1.2.0/AIMeter-1.2.0-macos-universal.zip?token=unexpected"] {
            XCTAssertThrowsError(try UpdateService.parse(encoded(release(url: url)), channel: .stable), url)
        }
        for size in [0, -1, UpdateService.maximumArchiveBytes + 1] {
            XCTAssertThrowsError(try UpdateService.parse(encoded(release(size: size)), channel: .stable))
        }
        for digest in [nil, "sha256:123", "md5:" + String(repeating: "a", count: 32)] {
            XCTAssertThrowsError(try UpdateService.parse(encoded(release(digest: digest)), channel: .stable))
        }
        var draft = release(); draft["draft"] = true
        XCTAssertThrowsError(try UpdateService.parse(encoded(draft), channel: .stable))
        XCTAssertThrowsError(try UpdateService.parse(encoded(release(prerelease: true)), channel: .stable))
    }

    func testChannelSwitchAllowsStableReturnFromNewerDevelopmentBuild() throws {
        let candidate = try UpdateService.parse(encoded(release()), channel: .stable)
        var info: [String: Any] = ["AIMeterBuildProfile": "distribution", "AIMeterUpdateChannel": "development",
                                  "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "40"]
        XCTAssertTrue(candidate.needsInstallation(over: info, channel: .stable))
        info["AIMeterUpdateChannel"] = "stable"
        XCTAssertFalse(candidate.needsInstallation(over: info, channel: .stable))
        info["AIMeterBuildProfile"] = "local"
        XCTAssertTrue(candidate.needsInstallation(over: info, channel: .stable))
    }

    func testSameDevelopmentVersionComparesBuildNumbersNumerically() throws {
        let candidate = try UpdateService.parse(encoded([release(tag: "v1.2.0-dev.22", prerelease: true)]), channel: .development)
        var info: [String: Any] = ["AIMeterBuildProfile": "distribution", "AIMeterUpdateChannel": "development",
                                  "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "9"]
        XCTAssertTrue(candidate.needsInstallation(over: info, channel: .development))
        info["CFBundleVersion"] = "22"
        XCTAssertFalse(candidate.needsInstallation(over: info, channel: .development))
        info["CFBundleVersion"] = "23"
        XCTAssertFalse(candidate.needsInstallation(over: info, channel: .development))
    }

    func testDowngradePromptIncludesSameVersionLowerBuildAndVersionRollback() {
        let current: [String: Any] = ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "22"]
        XCTAssertTrue(UpdateInstallation.isDowngrade(["CFBundleShortVersionString": "1.1.1", "CFBundleVersion": "100"], from: current))
        XCTAssertTrue(UpdateInstallation.isDowngrade(["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "3"], from: current))
        XCTAssertFalse(UpdateInstallation.isDowngrade(current, from: current))
        XCTAssertFalse(UpdateInstallation.isDowngrade(["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "23"], from: current))
    }

    func testMissingPublicReleaseReportsSelectedChannelWithoutAuthentication() async throws {
        for channel in [AppUpdater.Channel.stable, .development] {
            do {
                _ = try await UpdateService.latest(channel: channel) { url, limit in
                    let suffix = channel == .stable ? "/latest" : "?per_page=100"
                    XCTAssertEqual(url.absoluteString, "https://api.github.com/repos/TaigaShinohara/AIMeter-public/releases" + suffix)
                    XCTAssertEqual(limit, 2 * 1024 * 1024)
                    throw UpdateHTTPClient.Failure.status(404)
                }
                XCTFail("A missing release must not be treated as an update.")
            } catch let failure as UpdateFailure {
                let expected = channel == .stable ? "安定版" : "開発版"
                XCTAssertEqual(failure.localizedDescription, "公開された\(expected)が見つかりませんでした。現在のアプリは保持されています。")
                XCTAssertFalse(failure.localizedDescription.contains("ログイン"))
                XCTAssertFalse(failure.localizedDescription.contains("GitHub CLI"))
            }
        }
    }

    func testEmptyDevelopmentReleaseListReportsNoPublishedDevelopmentRelease() async throws {
        do {
            _ = try await UpdateService.latest(channel: .development) { _, _ in Data("[]".utf8) }
            XCTFail("An empty public release list cannot provide an update.")
        } catch let failure as UpdateFailure {
            XCTAssertEqual(failure.localizedDescription, "公開された開発版が見つかりませんでした。現在のアプリは保持されています。")
        }
    }

    func testMetadataFailuresOtherThanMissingReleaseArePreserved() async throws {
        for status in [403, 429, 500] {
            do {
                _ = try await UpdateService.latest(channel: .stable) { _, _ in
                    throw UpdateHTTPClient.Failure.status(status)
                }
                XCTFail("A failed metadata request must not provide an update.")
            } catch UpdateHTTPClient.Failure.status(let received) {
                XCTAssertEqual(received, status)
            }
        }
    }

    func testPublicMetadataParsesValidStableAndDevelopmentResponses() async throws {
        let stable = try encoded(release())
        let development = try encoded([release(), release(tag: "v1.2.0-dev.22", prerelease: true)])
        let stableRelease = try await UpdateService.latest(channel: .stable) { _, _ in stable }
        let developmentRelease = try await UpdateService.latest(channel: .development) { _, _ in development }
        XCTAssertEqual(stableRelease.tag, "v1.2.0")
        XCTAssertEqual(developmentRelease.tag, "v1.2.0-dev.22")
        XCTAssertEqual(developmentRelease.build, "22")
    }

    func testMissingPublicArchiveDoesNotRequestAuthentication() async throws {
        let candidate = try UpdateService.parse(encoded(release()), channel: .stable)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("AIMeter-should-not-create-" + UUID().uuidString)
        do {
            _ = try await UpdateService.download(candidate, to: destination) { url, limit, target in
                XCTAssertEqual(url, candidate.asset.url)
                XCTAssertEqual(limit, candidate.asset.size)
                XCTAssertEqual(target, destination)
                throw UpdateHTTPClient.Failure.status(404)
            }
            XCTFail("A missing archive cannot be installed.")
        } catch let failure as UpdateFailure {
            XCTAssertTrue(failure.localizedDescription.contains("公開された配布ファイルを取得できませんでした"))
            XCTAssertTrue(failure.localizedDescription.contains("現在のアプリは保持されています"))
            XCTAssertFalse(failure.localizedDescription.contains("ログイン"))
            XCTAssertFalse(failure.localizedDescription.contains("GitHub CLI"))
        }
    }

    func testPublicArchiveFailuresOtherThan404ArePreserved() async throws {
        let candidate = try UpdateService.parse(encoded(release()), channel: .stable)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("AIMeter-should-not-create-" + UUID().uuidString)
        do {
            _ = try await UpdateService.download(candidate, to: destination) { _, _, _ in
                throw UpdateHTTPClient.Failure.status(403)
            }
            XCTFail("A failed archive request cannot be installed.")
        } catch UpdateHTTPClient.Failure.status(let status) {
            XCTAssertEqual(status, 403)
        }
    }

    private struct Entry {
        var name: String
        var mode: UInt32 = 0o100644
        var size: UInt32 = 0
        var localName: String?
    }

    private func archive(_ entries: [Entry]) -> Data {
        var bytes = Data()
        var central = Data()
        func number(_ value: UInt32, count: Int = 4) -> Data {
            Data((0..<count).map { UInt8((value >> (8 * $0)) & 255) })
        }
        for entry in entries {
            let offset = UInt32(bytes.count)
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            bytes.append(number(0x04034b50)); bytes.append(number(20, count: 2))
            bytes.append(Data(repeating: 0, count: 8)) // flags, method and time
            bytes.append(Data(repeating: 0, count: 12)) // CRC and compressed/uncompressed sizes
            bytes.append(number(UInt32(localName.count), count: 2)); bytes.append(number(0, count: 2)); bytes.append(localName)
            central.append(number(0x02014b50)); central.append(number(0x0314, count: 2)); central.append(number(20, count: 2))
            central.append(Data(repeating: 0, count: 8)); central.append(number(0)); central.append(number(0)); central.append(number(entry.size))
            central.append(number(UInt32(name.count), count: 2)); central.append(Data(repeating: 0, count: 8))
            central.append(number(entry.mode << 16)); central.append(number(offset)); central.append(name)
        }
        let start = UInt32(bytes.count)
        bytes.append(central)
        bytes.append(number(0x06054b50)); bytes.append(Data(repeating: 0, count: 4))
        bytes.append(number(UInt32(entries.count), count: 2)); bytes.append(number(UInt32(entries.count), count: 2))
        bytes.append(number(UInt32(central.count))); bytes.append(number(start)); bytes.append(number(0, count: 2))
        return bytes
    }
    private var entries: [Entry] { UpdateArchive.payload.sorted().map { Entry(name: "AIMeter.app/" + $0) } }

    func testArchiveAcceptsOnlyCompleteKnownDistributionPayload() throws {
        XCTAssertNoThrow(try UpdateArchive.validate(archive(entries)))
        XCTAssertThrowsError(try UpdateArchive.validate(archive(Array(entries.dropLast()))))
        XCTAssertThrowsError(try UpdateArchive.validate(archive(entries + [Entry(name: "AIMeter.app/Contents/Resources/unexpected")])) )
    }

    func testArchiveRejectsSymlinksTraversalDuplicatesAndLocalHeaderMismatch() throws {
        var changed = entries
        changed[0].mode = 0o120777
        XCTAssertThrowsError(try UpdateArchive.validate(archive(changed)))
        for path in ["../outside", "/absolute", "AIMeter.app/../outside", "AIMeter.app/Contents/\nstrange"] {
            XCTAssertThrowsError(try UpdateArchive.validate(archive(entries + [Entry(name: path)])))
        }
        XCTAssertThrowsError(try UpdateArchive.validate(archive(entries + [entries[0]])))
        changed = entries
        changed[0].localName = String(repeating: "X", count: changed[0].name.count)
        XCTAssertThrowsError(try UpdateArchive.validate(archive(changed)))
    }

    func testArchiveRejectsExpansionBombAndTruncatedHeaders() throws {
        var changed = entries
        changed[0].size = 512 * 1024 * 1024 + 1
        XCTAssertThrowsError(try UpdateArchive.validate(archive(changed)))
        for count in [0, 21, 50] {
            XCTAssertThrowsError(try UpdateArchive.validate(Data(archive(entries).prefix(count))))
        }
    }

    func testPinnedRequirementUsesDeveloperIDAndExactAppIdentity() {
        let requirement = UpdateInstallation.requirement(identifier: "com.local.AIMeter")
        XCTAssertTrue(requirement.contains("MY4L8GVM2L"))
        XCTAssertTrue(requirement.contains("identifier \"com.local.AIMeter\""))
        XCTAssertTrue(requirement.contains("1.2.840.113635.100.6.1.13"))
    }

    func testPublishedArchiveAndSignatureWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let archive = environment["AIMETER_UPDATE_TEST_ARCHIVE"], let app = environment["AIMETER_UPDATE_TEST_APP"] else {
            throw XCTSkip("Set AIMETER_UPDATE_TEST_ARCHIVE and AIMETER_UPDATE_TEST_APP to a compatible signed v1.1.1 fixture; no network or install occurs in this test.")
        }
        let entries = try UpdateArchive.validate(URL(fileURLWithPath: archive))
        let release = UpdateRelease(version: "1.1.1", build: nil, tag: "v1.1.1",
                                    asset: .init(url: URL(string: "https://github.com/TaigaShinohara/AIMeter-public/releases/download/v1.1.1/AIMeter-1.1.1-macos-universal.zip")!, size: 1, digest: String(repeating: "a", count: 64)))
        try UpdateInstallation.verify(URL(fileURLWithPath: app), release: release)
        let expanded = FileManager.default.temporaryDirectory.appendingPathComponent("AIMeter-update-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: expanded) }
        try await UpdateArchive.extract(URL(fileURLWithPath: archive), entries: entries, to: expanded)
        try UpdateInstallation.verify(expanded.appendingPathComponent("AIMeter.app"), release: release)
        try UpdateInstallation.verifyPrevious(expanded.appendingPathComponent("AIMeter.app"))
        let linkedApp = expanded.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: linkedApp, withDestinationURL: expanded.appendingPathComponent("AIMeter.app"))
        XCTAssertThrowsError(try UpdateInstallation.verify(linkedApp, release: release))
        XCTAssertThrowsError(try UpdateInstallation.verifyPrevious(linkedApp))
        let bounded = expanded.appendingPathComponent("bounded", isDirectory: true)
        try FileManager.default.createDirectory(at: bounded, withIntermediateDirectories: false)
        let largeEntry = try XCTUnwrap(entries.first { $0.size > 8192 })
        do {
            try await UpdateArchive.extract(URL(fileURLWithPath: archive), entries: [.init(path: largeEntry.path, size: 1)], to: bounded)
            XCTFail("Actual decompressed output exceeded the declared byte budget")
        } catch BoundedProcess.Failure.outputLimit { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bounded.appendingPathComponent(largeEntry.path).path))
    }
}
