import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Security
import AIMeterCore

/// Updates are requested explicitly. No startup polling or credentials are used.
@MainActor
final class AppUpdater: ObservableObject {
    enum Channel: String, Sendable { case stable, development }
    static let shared = AppUpdater()
    @Published private(set) var isBusy = false
    @Published private(set) var status = "ボタンを押すと更新を確認し、インストール後に再起動します。"
    @Published private(set) var progress: Double?

    private init() {
        if let path = UserDefaults.standard.string(forKey: "AIMeterUpdateResultDirectory") {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
            if directory.deletingLastPathComponent().standardizedFileURL == parent,
               directory.lastPathComponent.hasPrefix(".AIMeter-update-"),
               let data = try? Data(contentsOf: directory.appendingPathComponent("result")), data.count < 128,
               let result = String(data: data, encoding: .utf8) {
                switch result.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "installed": status = "アップデートが完了しました。以前のアプリはバックアップとして保持されています。"
                case "restored": status = "更新後の起動を確認できず、以前のアプリへ戻しました。もう一度更新をお試しください。"
                case "failed": status = "前回の更新を完了できませんでした。アプリの保存先を確認し、もう一度お試しください。"
                default: break
                }
            }
        }
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
    var currentChannelLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        if info["AIMeterBuildProfile"] as? String == "local" { return "ローカル開発版" }
        return info["AIMeterUpdateChannel"] as? String == "development" ? "開発版" : "安定版"
    }

    func update(to channel: Channel) async {
        #if AIMETER_APP_STORE
        status = "アップデートはMac App Storeから行ってください。"
        return
        #else
        guard let config = try? DistributionConfiguration.current(), config.mode == .direct else {
            status = "このアプリの更新方法を確認できません。"
            return
        }
        guard !isBusy else { return }
        isBusy = true
        progress = nil
        defer { isBusy = false; progress = nil }
        var work: URL?
        var handedOff = false
        defer { if !handedOff, let work { try? FileManager.default.removeItem(at: work) } }
        do {
            let destination = try UpdateInstallation.destination(Bundle.main.bundleURL)
            status = channel == .stable ? "最新版を確認しています…" : "開発版を確認しています…"
            let release = try await UpdateService.latest(channel: channel)
            if !release.needsInstallation(over: Bundle.main.infoDictionary ?? [:], channel: channel) {
                status = "\(channel == .stable ? "安定版" : "開発版") \(release.version) はインストール済みです。"
                return
            }
            let retained = try UpdateInstallation.makeWorkDirectory(beside: destination)
            work = retained
            let archive = retained.appendingPathComponent("update.zip")
            status = "\(release.version) をダウンロードしています…"
            let result = try await UpdateService.download(release, to: archive)
            guard result.count == release.asset.size, result.sha256 == release.asset.digest else {
                throw UpdateFailure.message("ダウンロードの整合性を確認できませんでした。もう一度お試しください。")
            }
            status = "署名と安全性を確認しています…"
            let entries = try await Task.detached(priority: .utility) {
                try UpdateArchive.validate(archive)
            }.value
            let expanded = retained.appendingPathComponent("expanded", isDirectory: true)
            try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            try await UpdateArchive.extract(archive, entries: entries, to: expanded)
            let candidate = expanded.appendingPathComponent("AIMeter.app", isDirectory: true)
            try await Task.detached(priority: .utility) {
                try UpdateInstallation.verify(candidate, release: release)
            }.value
            _ = try await BoundedProcess.run(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", candidate.path],
                                             environment: UpdateInstallation.environment,
                                             limits: .init(seconds: 60, stdoutBytes: 16_384, stderrBytes: 16_384))
            let candidateInfo = try UpdateInstallation.info(candidate)
            if UpdateInstallation.isDowngrade(candidateInfo, from: Bundle.main.infoDictionary ?? [:]) {
                let alert = NSAlert()
                alert.messageText = "\(channel == .stable ? "安定版" : "開発版") \(release.version) へ切り替えますか？"
                alert.informativeText = "現在より古いバージョンへ切り替えるため、新しい機能が利用できなくなる場合があります。"
                    + (release.tag == "v1.1.1" ? " この安定版にはアプリ内アップデート機能が含まれません。開発版に戻すには手動でのインストールが必要です。" : "")
                alert.addButton(withTitle: "切り替えて再起動")
                alert.addButton(withTitle: "キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else { status = "更新をキャンセルしました。"; return }
            }
            try await Task.detached(priority: .utility) { try UpdateInstallation.verifyPrevious(destination) }.value
            status = "更新を適用して再起動します…"
            try UpdateInstallation.handoff(candidate: candidate, destination: destination, retained: retained)
            handedOff = true
            NSApplication.shared.terminate(nil)
        } catch let failure as UpdateFailure {
            status = failure.localizedDescription
        } catch {
            status = "更新を完了できませんでした。通信とアプリの保存先を確認し、もう一度お試しください。現在のアプリは保持されています。"
        }
        #endif
    }
}

enum UpdateFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
    static let invalid = UpdateFailure.message("配布物の形式または署名を確認できないため、更新を中止しました。")
}

struct UpdateRelease: Sendable {
    struct Asset: Sendable {
        let url: URL
        let size: Int
        let digest: String
        var id: Int64? = nil
    }
    let version: String
    let build: String?
    let tag: String
    let asset: Asset

    func needsInstallation(over info: [String: Any], channel: AppUpdater.Channel) -> Bool {
        let installedChannel = info["AIMeterUpdateChannel"] as? String ?? "stable"
        if info["AIMeterBuildProfile"] as? String == "local" || installedChannel != channel.rawValue { return true }
        guard let currentVersion = info["CFBundleShortVersionString"] as? String else { return true }
        let comparison = currentVersion.compare(version, options: .numeric)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        if let build { return (info["CFBundleVersion"] as? String ?? "0").compare(build, options: .numeric) == .orderedAscending }
        return false
    }
}

enum UpdateService {
    static let repository = "TaigaShinohara/AIMeter-public"
    static let maximumArchiveBytes = 256 * 1024 * 1024
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let id: Int64?
            let name: String
            let size: Int
            let browser_download_url: String
            let digest: String?
        }
    }

    static func latest(channel: AppUpdater.Channel,
                       fetchMetadata: (URL, Int) async throws -> Data = { url, maximumBytes in
                           try await UpdateHTTPClient().fetch(url, maximumBytes: maximumBytes).data
                       }) async throws -> UpdateRelease {
        let suffix = channel == .stable ? "/latest" : "?per_page=100"
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases\(suffix)")!
        do {
            let data = try await fetchMetadata(url, 2 * 1024 * 1024)
            return try parse(data, channel: channel)
        } catch UpdateHTTPClient.Failure.status(404) {
            throw unavailable(channel: channel)
        }
    }

    static func download(_ release: UpdateRelease, to destination: URL,
                         fetchArchive: (URL, Int, URL) async throws -> UpdateHTTPClient.Result = { url, maximumBytes, destination in
                             try await UpdateHTTPClient().fetch(url, maximumBytes: maximumBytes,
                                                               destination: destination, allowAssetRedirects: true)
                         }) async throws -> UpdateHTTPClient.Result {
        do {
            return try await fetchArchive(release.asset.url, release.asset.size, destination)
        } catch UpdateHTTPClient.Failure.status(404) {
            throw UpdateFailure.message("公開された配布ファイルを取得できませんでした。しばらくしてからもう一度お試しください。現在のアプリは保持されています。")
        }
    }

    private static func unavailable(channel: AppUpdater.Channel) -> UpdateFailure {
        .message(channel == .development
            ? "公開された開発版が見つかりませんでした。現在のアプリは保持されています。"
            : "公開された安定版が見つかりませんでした。現在のアプリは保持されています。")
    }

    static func parse(_ data: Data, channel: AppUpdater.Channel) throws -> UpdateRelease {
        let decoder = JSONDecoder()
        let releases: [Release]
        if channel == .stable { releases = [try decoder.decode(Release.self, from: data)] }
        else { releases = try decoder.decode([Release].self, from: data) }
        let matching = releases.filter { !$0.draft && $0.prerelease == (channel == .development) }
        // GitHub returns newest releases first. A malformed matching release must
        // fail visibly rather than silently installing an older release.
        guard let release = matching.first else {
            throw unavailable(channel: channel)
        }
        let pattern = channel == .stable ? #"^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$"# : #"^v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))-dev\.([1-9][0-9]*)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(release.tag_name.startIndex..., in: release.tag_name)
        guard release.tag_name.utf8.count <= 100, let match = regex.firstMatch(in: release.tag_name, range: range),
              let versionRange = Range(match.range(at: 1), in: release.tag_name) else { throw UpdateFailure.invalid }
        let version = String(release.tag_name[versionRange])
        let build = channel == .development ? Range(match.range(at: 2), in: release.tag_name).map { String(release.tag_name[$0]) } : nil
        let name = "AIMeter-\(version)-macos-universal.zip"
        let assets = release.assets.filter { $0.name == name }
        guard assets.count == 1, let asset = assets.first, (1...maximumArchiveBytes).contains(asset.size),
              let url = URL(string: asset.browser_download_url), isAssetURL(url, tag: release.tag_name, name: name) else { throw UpdateFailure.invalid }
        guard let raw = asset.digest, raw.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw UpdateFailure.invalid }
        let digest = String(raw.dropFirst(7))
        return UpdateRelease(version: version, build: build, tag: release.tag_name,
                             asset: .init(url: url, size: asset.size, digest: digest, id: asset.id))
    }

    static func isAssetURL(_ url: URL, tag: String, name: String) -> Bool {
        UpdateHTTPClient.isHTTPS(url) && url.host == "github.com" && url.query == nil
            && url.path == "/\(repository)/releases/download/\(tag)/\(name)"
    }
}

/// Bounded responses and streamed archive writes keep a server response from
/// allocating arbitrary memory or exhausting disk. Only GitHub's asset CDN can
/// receive redirects; API requests never follow redirects.
final class UpdateHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error { case status(Int) }
    struct Result: Sendable { let data: Data; let count: Int; let sha256: String }
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var completion: Swift.Result<Result, Error>?
    private var session: URLSession?
    private var timer: DispatchWorkItem?
    private var handle: FileHandle?
    private var buffer = Data()
    private var hasher = SHA256()
    private var count = 0
    private var maximumBytes = 0
    private var redirects = 0
    private var allowAssetRedirects = false
    private var accepted = false

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.fragment == nil
    }

    func fetch(_ url: URL, maximumBytes: Int, destination: URL? = nil,
               allowAssetRedirects: Bool = false) async throws -> Result {
        guard Self.isHTTPS(url), ["api.github.com", "github.com"].contains(url.host ?? ""), maximumBytes > 0 else { throw UpdateFailure.invalid }
        self.maximumBytes = maximumBytes
        self.allowAssetRedirects = allowAssetRedirects
        if let destination {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw UpdateFailure.invalid }
            handle = try FileHandle(forWritingTo: destination)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                if let completion { continuation.resume(with: completion); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 180
                configuration.waitsForConnectivity = false
                configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("AIMeter-Updater", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                self.timer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timer)
                session.dataTask(with: request).resume()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard allowAssetRedirects, redirects < 3, let url = request.url, Self.isHTTPS(url),
              ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "") else {
            completionHandler(nil); finish(.failure(UpdateFailure.invalid)); return
        }
        redirects += 1
        var clean = URLRequest(url: url)
        clean.setValue("AIMeter-Updater", forHTTPHeaderField: "User-Agent")
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(UpdateFailure.invalid)); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(Failure.status(http.statusCode))); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(UpdateFailure.message("更新情報を取得できませんでした。通信状況やGitHubの利用制限を確認して、しばらくしてからお試しください。")))
            return
        }
        accepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard completion == nil, accepted, data.count <= maximumBytes - count else { finish(.failure(UpdateFailure.invalid)); return }
        do {
            if let handle { try handle.write(contentsOf: data) } else { buffer.append(data) }
            hasher.update(data: data)
            count += data.count
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { finish(.failure(error)) }
        else if accepted { finish(.success(.init(data: buffer, count: count, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()))) }
        else { finish(.failure(UpdateFailure.invalid)) }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard completion == nil else { return }
        completion = result
        timer?.cancel(); timer = nil
        try? handle?.close(); handle = nil
        session?.invalidateAndCancel(); session = nil
        let saved = continuation; continuation = nil
        saved?.resume(with: result)
    }
}

/// Check both ZIP headers before invoking the OS extractor. Only the existing
/// distribution payload is accepted; links, aliases and extra files are refused.
enum UpdateArchive {
    struct Entry: Sendable { let path: String; let size: Int }
    static let maximumEntryBytes = 64 * 1024 * 1024
    static let payload: Set<String> = [
        "Contents/MacOS/AIMeter", "Contents/Info.plist", "Contents/Resources/AppIcon.icns", "Contents/Resources/LICENSE",
        "Contents/PlugIns/AIMeterWidget.appex/Contents/MacOS/AIMeterWidgetExtension",
        "Contents/PlugIns/AIMeterWidget.appex/Contents/Info.plist", "Contents/PlugIns/AIMeterWidget.appex/Contents/Resources/AppIcon.icns",
        "Contents/_CodeSignature/CodeResources", "Contents/PlugIns/AIMeterWidget.appex/Contents/_CodeSignature/CodeResources"
    ]
    static let optional: Set<String> = ["Contents/CodeResources"]

    @discardableResult
    static func validate(_ url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try validate(data)
    }

    @discardableResult
    static func validate(_ data: Data) throws -> [Entry] {
        func number(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, size <= data.count, offset <= data.count - size else { throw UpdateFailure.invalid }
            return (0..<size).reduce(0) { $0 | (Int(data[offset + $1]) << (8 * $1)) }
        }
        guard data.count >= 22, data.count <= UpdateService.maximumArchiveBytes else { throw UpdateFailure.invalid }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x06054b50,
               offset + 22 + (try number(offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw UpdateFailure.invalid }
        let entries = try number(end + 10, 2)
        guard entries == (try number(end + 8, 2)), (1...128).contains(entries) else { throw UpdateFailure.invalid }
        let centralStart = try number(end + 16, 4)
        let centralSize = try number(end + 12, 4)
        guard centralStart + centralSize == end else { throw UpdateFailure.invalid }
        var cursor = centralStart
        var files = Set<String>()
        var names = Set<String>()
        var ranges: [Range<Int>] = []
        var expandedSize = 0
        var extractedEntries: [Entry] = []
        let allowedFiles = Set(payload.union(optional).map { "AIMeter.app/" + $0 })
        var allowedDirectories: Set<String> = ["AIMeter.app/"]
        for path in allowedFiles {
            var pieces = path.split(separator: "/").map(String.init)
            pieces.removeLast()
            while !pieces.isEmpty { allowedDirectories.insert(pieces.joined(separator: "/") + "/"); pieces.removeLast() }
        }
        // The original 1.1.1 ditto archive contains AppleDouble companions.
        // Accept only companions of known files/directories, and never extract
        // them. New releases omit these metadata entries entirely.
        var metadataFiles = Set<String>()
        var metadataDirectories: Set<String> = ["__MACOSX/"]
        for path in allowedFiles.union(allowedDirectories) {
            let stripped = path.hasSuffix("/") ? String(path.dropLast()) : path
            var pieces = stripped.split(separator: "/").map(String.init)
            guard let last = pieces.popLast() else { continue }
            metadataFiles.insert("__MACOSX/" + (pieces + ["._" + last]).joined(separator: "/"))
            if path.hasSuffix("/") { metadataDirectories.insert("__MACOSX/" + path) }
        }
        for _ in 0..<entries {
            guard try number(cursor, 4) == 0x02014b50 else { throw UpdateFailure.invalid }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4)
            let compressed = try number(cursor + 20, 4), uncompressed = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2), extraLength = try number(cursor + 30, 2), commentLength = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4), local = try number(cursor + 42, 4)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0, nameLength <= 512, flags & 1 == 0, [0, 8].contains(method),
                  try number(cursor + 34, 2) == 0,
                  let name = String(data: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), encoding: .utf8),
                  names.insert(name).inserted, name.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
                  allowedFiles.contains(name) || allowedDirectories.contains(name)
                    || metadataFiles.contains(name) || metadataDirectories.contains(name) else { throw UpdateFailure.invalid }
            let type = (attributes >> 16) & 0o170000
            guard type == 0 || type == (name.hasSuffix("/") ? 0o040000 : 0o100000), attributes & (0o6000 << 16) == 0 else { throw UpdateFailure.invalid }
            guard try number(local, 4) == 0x04034b50, try number(local + 6, 2) == flags,
                  try number(local + 8, 2) == method, try number(local + 26, 2) == nameLength else { throw UpdateFailure.invalid }
            let localExtra = try number(local + 28, 2)
            let content = local + 30 + nameLength + localExtra
            guard content + compressed <= centralStart,
                  data.subdata(in: (local + 30)..<(local + 30 + nameLength)) == Data(name.utf8) else { throw UpdateFailure.invalid }
            for (offset, expected) in [(14, crc), (18, compressed), (22, uncompressed)] {
                let actual = try number(local + offset, 4)
                guard actual == expected || (flags & 8 != 0 && actual == 0) else { throw UpdateFailure.invalid }
            }
            ranges.append(local..<(content + compressed))
            expandedSize += uncompressed
            guard uncompressed <= maximumEntryBytes, expandedSize <= 512 * 1024 * 1024 else { throw UpdateFailure.invalid }
            if name.hasPrefix("AIMeter.app/"), !name.hasSuffix("/") {
                files.insert(String(name.dropFirst("AIMeter.app/".count)))
                extractedEntries.append(.init(path: name, size: uncompressed))
            }
            cursor = next
        }
        guard cursor == end, files.isSuperset(of: payload), files.isSubset(of: payload.union(optional)) else { throw UpdateFailure.invalid }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sorted.count { guard sorted[index - 1].upperBound <= sorted[index].lowerBound else { throw UpdateFailure.invalid } }
        return extractedEntries
    }

    static func extract(_ archive: URL, entries: [Entry], to directory: URL) async throws {
        // Stream one fixed, validated member to a bounded pipe. unzip never
        // writes to disk; its CRC check and the exact byte count must pass
        // before we create a file. A false central-directory size therefore
        // cannot turn into an unbounded decompression write.
        for entry in entries {
            let output = try await BoundedProcess.run(executable: "/usr/bin/unzip", arguments: ["-p", archive.path, entry.path],
                                                      environment: UpdateInstallation.environment,
                                                      limits: .init(seconds: 30, stdoutBytes: entry.size, stderrBytes: 16_384))
            guard output.stdout.count == entry.size else { throw UpdateFailure.invalid }
            let target = directory.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o755])
            guard FileManager.default.createFile(atPath: target.path, contents: output.stdout,
                                                 attributes: [.posixPermissions: entry.path.contains("/MacOS/") ? 0o755 : 0o644]) else { throw UpdateFailure.invalid }
        }
    }
}

enum UpdateInstallation {
    // Public signing identity of the existing AIMeter distribution.
    static let teamID = "MY4L8GVM2L"
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
    static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }

    static func destination(_ url: URL) throws -> URL {
        guard url.isFileURL, url.pathExtension == "app", url.lastPathComponent == "AIMeter.app",
              !url.path.contains("/AppTranslocation/"),
              url.standardizedFileURL == url.resolvingSymlinksInPath(),
              FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw UpdateFailure.message("AIMeter.appをアプリケーションフォルダなどの書き込み可能な場所へ移動して、そこから開き直してください。")
        }
        return url
    }

    static func makeWorkDirectory(beside destination: URL) throws -> URL {
        var template = Array(destination.deletingLastPathComponent().appendingPathComponent(".AIMeter-update-XXXXXX").path.utf8CString)
        guard let path = mkdtemp(&template) else { throw UpdateFailure.invalid }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    static func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard data.count <= 65_536,
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw UpdateFailure.invalid }
        return info
    }

    static func isDowngrade(_ candidate: [String: Any], from current: [String: Any]) -> Bool {
        guard let next = candidate["CFBundleShortVersionString"] as? String,
              let previous = current["CFBundleShortVersionString"] as? String else { return false }
        let comparison = next.compare(previous, options: .numeric)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return (candidate["CFBundleVersion"] as? String ?? "0").compare(current["CFBundleVersion"] as? String ?? "0", options: .numeric) == .orderedAscending
    }

    static func verifyPrevious(_ app: URL) throws {
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw UpdateFailure.invalid }
        let app = app.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw UpdateFailure.invalid }
        var files = Set<String>()
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw UpdateFailure.invalid }
            if values.isRegularFile == true {
                let path = item.standardizedFileURL.path
                guard path.hasPrefix(app.path + "/") else { throw UpdateFailure.invalid }
                files.insert(String(path.dropFirst(app.path.count + 1)))
            }
        }
        guard files.isSuperset(of: UpdateArchive.payload), files.isSubset(of: UpdateArchive.payload.union(UpdateArchive.optional)) else { throw UpdateFailure.invalid }
        for (bundle, identifier, executable) in [(app, "com.local.AIMeter", "AIMeter"),
                                                (app.appendingPathComponent("Contents/PlugIns/AIMeterWidget.appex"), "com.local.AIMeter.widget", "AIMeterWidgetExtension")] {
            let metadata = try info(bundle)
            guard metadata["CFBundleIdentifier"] as? String == identifier,
                  metadata["CFBundleExecutable"] as? String == executable else { throw UpdateFailure.invalid }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw UpdateFailure.invalid }
        }
    }

    static func verify(_ app: URL, release: UpdateRelease) throws {
        guard try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw UpdateFailure.invalid }
        let app = app.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw UpdateFailure.invalid }
        var files = Set<String>()
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw UpdateFailure.invalid }
            if values.isRegularFile == true {
                let path = item.standardizedFileURL.path
                guard path.hasPrefix(app.path + "/") else { throw UpdateFailure.invalid }
                files.insert(String(path.dropFirst(app.path.count + 1)))
            }
        }
        guard files.isSuperset(of: UpdateArchive.payload), files.isSubset(of: UpdateArchive.payload.union(UpdateArchive.optional)) else { throw UpdateFailure.invalid }
        var sourceCommit: String?
        var metadata: [String]?
        let expectedChannel = release.build == nil ? "stable" : "development"
        for (bundle, identifier, executable) in [(app, "com.local.AIMeter", "AIMeter"),
                                                  (app.appendingPathComponent("Contents/PlugIns/AIMeterWidget.appex"), "com.local.AIMeter.widget", "AIMeterWidgetExtension")] {
            let infoData = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
            guard infoData.count <= 65_536,
                  let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == identifier, info["CFBundleExecutable"] as? String == executable,
                  info["CFBundleShortVersionString"] as? String == release.version,
                  let build = info["CFBundleVersion"] as? String, build.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
                  release.build == nil || release.build == build,
                  let commit = info["AIMeterSourceCommit"] as? String,
                  commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
                  sourceCommit == nil || sourceCommit == commit else { throw UpdateFailure.invalid }
            sourceCommit = commit
            let profile = info["AIMeterBuildProfile"] as? String
            let dirty = info["AIMeterSourceDirty"] as? Bool
            let channel = info["AIMeterUpdateChannel"] as? String
            let legacyStable = release.tag == "v1.1.1" && profile == nil && dirty == nil && channel == nil
            guard legacyStable || (profile == "distribution" && dirty == false && channel == expectedChannel) else { throw UpdateFailure.invalid }
            let bundleMetadata = [profile ?? "", dirty.map(String.init) ?? "", channel ?? "", build]
            guard metadata == nil || metadata == bundleMetadata else { throw UpdateFailure.invalid }
            metadata = bundleMetadata
            var code: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(Self.requirement(identifier: identifier) as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw UpdateFailure.invalid }
        }
    }

    static func handoff(candidate: URL, destination: URL, retained: URL) throws {
        _ = try self.destination(destination)
        let script = retained.appendingPathComponent("install.sh")
        try installerScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(getpid()), destination.path, candidate.path, retained.path]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        UserDefaults.standard.set(retained.path, forKey: "AIMeterUpdateResultDirectory")
        try process.run()
    }

    // Paths are separate argv values throughout. The retained directory is on
    // the same volume, so switching bundles uses complete-directory renames.
    static let installerScript = #"""
    #!/bin/bash
    set -u
    umask 077
    parent_pid="$1"
    destination="$2"
    candidate="$3"
    retained="$4"
    previous="$retained/previous.app"
    exec >"$retained/install.log" 2>&1
    fail() { /usr/bin/printf '%s' failed >"$retained/result"; /usr/bin/open -n "$destination" >/dev/null 2>&1; exit 1; }
    register_app() {
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination" &&
            /usr/bin/pluginkit -a "$destination/Contents/PlugIns/AIMeterWidget.appex"
    }
    live_pids() {
        process_list=$(/bin/ps -axo pid=,comm=) || return 1
        while read -r task_pid command; do
            if [[ "$command" == "$destination/Contents/MacOS/AIMeter" || "$command" == "$destination/Contents/PlugIns/AIMeterWidget.appex/Contents/MacOS/AIMeterWidgetExtension" ]]; then
                /bin/echo "$task_pid"
            fi
        done <<<"$process_list"
    }
    for ((attempt=0; attempt<150; attempt++)); do
        /bin/kill -0 "$parent_pid" 2>/dev/null || break
        /bin/sleep 0.2
    done
    /bin/kill -0 "$parent_pid" 2>/dev/null && { /usr/bin/printf '%s' failed >"$retained/result"; exit 1; }
    [[ -d "$destination" && ! -L "$destination" && -d "$candidate" && ! -L "$candidate" && ! -e "$previous" ]] || fail
    /usr/bin/codesign --verify --deep --strict -R 'anchor apple generic and identifier "com.local.AIMeter" and certificate leaf[subject.OU] = "MY4L8GVM2L" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$candidate" || fail
    /usr/sbin/spctl --assess --type execute "$candidate" || fail
    current_pids=$(live_pids) || fail
    for task_pid in $current_pids; do /bin/kill -TERM "$task_pid" 2>/dev/null || true; done
    for ((attempt=0; attempt<50; attempt++)); do
        current_pids=$(live_pids) || fail
        [[ -z "$current_pids" ]] && break
        /bin/sleep 0.2
    done
    current_pids=$(live_pids) || fail
    [[ -z "$current_pids" ]] || fail
    /bin/mv "$destination" "$previous" || fail
    if ! /bin/mv "$candidate" "$destination"; then
        /bin/mv "$previous" "$destination"
        fail
    fi
    /usr/bin/printf '%s' installed >"$retained/result"
    if /usr/bin/codesign --verify --deep --strict "$destination" && register_app && /usr/bin/open -n "$destination"; then
        for ((attempt=0; attempt<50; attempt++)); do
            main_pid=$(/bin/ps -axo pid=,comm= | while read -r task_pid command; do
                [[ "$command" == "$destination/Contents/MacOS/AIMeter" ]] && /bin/echo "$task_pid"
            done)
            if [[ -n "$main_pid" ]]; then
                /bin/sleep 1
                /bin/kill -0 "$main_pid" 2>/dev/null && exit 0
            fi
            /bin/sleep 0.2
        done
    fi
    current_pids=$(live_pids) || exit 1
    for task_pid in $current_pids; do /bin/kill -TERM "$task_pid" 2>/dev/null || true; done
    /bin/sleep 1
    current_pids=$(live_pids) || exit 1
    [[ -z "$current_pids" ]] || exit 1
    /usr/bin/codesign --verify --deep --strict "$previous" || exit 1
    /bin/mv "$destination" "$retained/failed.app" || exit 1
    /bin/mv "$previous" "$destination" || exit 1
    /usr/bin/printf '%s' restored >"$retained/result"
    register_app && /usr/bin/open -n "$destination"
    exit 1
    """#
}
