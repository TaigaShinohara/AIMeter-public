import AppKit
import Darwin
import Foundation
import SwiftUI

// Test-only application. Never print the fixture path, marker bytes, or bookmark.
@MainActor
final class SandboxProbe: ObservableObject {
    @Published private(set) var events: [String] = []
    private let root: String?
    private let bookmarkKey = "syntheticSandboxQABookmarkV1"
    private var activeURL: URL?
    private var inspected: stat?
    private var rootFD: Int32 = -1

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let value = environment["AIMETER_SANDBOX_QA_ROOT"] ?? ""
        let pattern = "^/private/tmp/aimeter-store-sandbox-qa-[a-f0-9]{32}$"
        root = value.range(of: pattern, options: .regularExpression) == nil ? nil : value
        record(root == nil ? "INVALID_FIXTURE_ROOT" : "READY")
    }

    private func record(_ code: String) { events.append(code) }
    private var selectedPath: String? { root.map { $0 + "/base/selected" } }

    func choose() {
        guard let selectedPath else { record("INVALID_FIXTURE_ROOT"); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "合成フォルダを選択"
        panel.message = "手順書の合成 selected フォルダだけを選択してください。"
        panel.directoryURL = URL(fileURLWithPath: selectedPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { record("SELECTION_CANCELLED"); return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard url.standardizedFileURL.path == selectedPath else { record("WRONG_SELECTION_REJECTED"); return }
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            record("BOOKMARK_SAVED_NOT_YET_VERIFIED")
        } catch { record("BOOKMARK_SAVE_FAILED") }
    }

    // Test stage 1. The operator can modify only the synthetic fixture after this.
    func resolveAndStart() {
        reset()
        guard let expected = selectedPath else { record("INVALID_FIXTURE_ROOT"); return }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { record("NO_BOOKMARK"); return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { record("BOOKMARK_STALE_RESELECT"); return }
            guard url.standardizedFileURL.path == expected else { record("RESOLVED_PATH_CHANGED_RESELECT"); return }
            guard url.startAccessingSecurityScopedResource() else { record("SCOPE_START_FAILED"); return }
            activeURL = url
            record("SCOPE_STARTED")
        } catch { record("BOOKMARK_RESOLVE_FAILED") }
    }

    // Test stage 2. Deliberately separated from open to create a test checkpoint.
    func inspect() {
        guard let url = activeURL else { record("SCOPE_NOT_ACTIVE"); return }
        closeRoot()
        var info = stat()
        guard lstat(url.path, &info) == 0 else { record("LSTAT_FAILED"); return }
        guard info.st_mode & S_IFMT == S_IFDIR else { record("LSTAT_NON_DIRECTORY_REJECTED"); return }
        inspected = info
        record("LSTAT_DIRECTORY")
    }

    // Test stage 3. The descriptor remains open until reset or app exit.
    func openRoot() {
        guard let url = activeURL, let expected = inspected else { record("INSPECT_FIRST"); return }
        closeRoot()
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { record("ROOT_OPEN_FAILED"); return }
        var actual = stat()
        guard fstat(fd, &actual) == 0, actual.st_mode & S_IFMT == S_IFDIR,
              actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else {
            Darwin.close(fd)
            record("ROOT_ID_CHANGED_REJECTED")
            return
        }
        rootFD = fd
        record("ROOT_FD_OPEN")
    }

    // Test stage 4. Only the fixed synthetic marker filename is ever read.
    func readMarker() {
        guard let root, rootFD >= 0 else { record("ROOT_FD_REQUIRED"); return }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(rootFD, F_GETPATH, &path) == 0 else { record("FD_PATH_UNAVAILABLE"); return }
        let actualPath = String(cString: path)
        let allowed = [root + "/base/selected", root + "/base/kept-selected",
                       root + "/kept-base/selected", root + "/outside/selected"]
        guard allowed.contains(actualPath) else { record("FD_OUTSIDE_FIXTURE_REJECTED"); return }
        let fd = openat(rootFD, "marker.txt", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { record("MARKER_OPEN_FAILED"); return }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 64 else { record("MARKER_INVALID"); return }
        var bytes = [UInt8](repeating: 0, count: 65)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count >= 0, count <= 64 else { record("MARKER_READ_FAILED"); return }
        let value = Data(bytes.prefix(count))
        if value == Data("AIMETER_INSIDE_SYNTHETIC\n".utf8) { record("INSIDE_MARKER_OBSERVED") }
        else if value == Data("AIMETER_OUTSIDE_SYNTHETIC\n".utf8) { record("OUTSIDE_MARKER_OBSERVED") }
        else { record("UNEXPECTED_MARKER_CONTENT") }
    }

    // Negative control checks only whether open succeeds; it never reads content.
    func outsideControl() {
        guard let root else { record("INVALID_FIXTURE_ROOT"); return }
        let fd = Darwin.open(root + "/outside/selected/marker.txt", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { Darwin.close(fd); record("OUTSIDE_CONTROL_OPENED") }
        else if errno == EACCES || errno == EPERM { record("OUTSIDE_CONTROL_DENIED") }
        else { record("OUTSIDE_CONTROL_INCONCLUSIVE") }
    }

    private func closeRoot() {
        if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }
    }

    func reset() {
        closeRoot()
        inspected = nil
        if let activeURL { activeURL.stopAccessingSecurityScopedResource() }
        activeURL = nil
    }
}

@main
struct StoreSandboxQA: App {
    @StateObject private var probe = SandboxProbe()
    var body: some Scene {
        WindowGroup("Store Sandbox QA") {
            VStack(alignment: .leading, spacing: 12) {
                Text("合成データ専用。手順書で指定したフォルダだけを選択してください。")
                HStack {
                    Button("1 選択・保存") { probe.choose() }
                    Button("2 復元・権限開始") { probe.resolveAndStart() }
                    Button("権限終了") { probe.reset() }
                }
                HStack {
                    Button("3 lstat") { probe.inspect() }
                    Button("4 root open") { probe.openRoot() }
                    Button("5 marker確認") { probe.readMarker() }
                    Button("未許可の対照") { probe.outsideControl() }
                }
                ScrollView { Text(probe.events.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading) }
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .padding(20).frame(minWidth: 640, minHeight: 360)
            .onDisappear { probe.reset() }
        }
    }
}
