import XCTest
import SQLite3
import AIMeterCore
@testable import AIMeter

final class SecurityInputTests: XCTestCase {
    private var root: URL!
    private var timestamp: String { ISO8601DateFormatter().string(from: Date()) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func scan(_ provider: String, _ url: URL, limits: BoundedInput.Limits = .init()) -> LocalUsageCollector.ProviderPathScanResult {
        LocalUsageCollector.validateAndScan(providerId: provider, path: url.path, home: root, limits: limits)
    }
    private func database(_ name: String = "state.vscdb", sql: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }
    private func codex(_ input: String, output: String = "2", cached: String = "0") -> String {
        """
        {"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":\(output),"cached_input_tokens":\(cached)}}}}
        """
    }

    func testNumericRepresentationsAndCheckedAccumulation() throws {
        for bad: Any in [Int.min, Int.max, -1, Double.infinity, -Double.infinity, Double.nan,
                         Double(Int.max), "1e100", "NaN", "-inf", "-1", true] {
            XCTAssertThrowsError(try UsageNumber.count(bad), "\(bad)")
        }
        XCTAssertEqual(try UsageNumber.count("1.2e3"), 1200)
        XCTAssertEqual(try UsageNumber.count(NSNumber(value: 42)), 42)
        XCTAssertEqual(try UsageNumber.count(nil), 0)
        XCTAssertEqual(try UsageNumber.count(String(UsageNumber.maximumCount)), UsageNumber.maximumCount)
        XCTAssertThrowsError(try UsageNumber.add(UsageNumber.maximumCount, 1))
        XCTAssertThrowsError(try UsageNumber.difference(0, Int.min))
        XCTAssertEqual(try UsageNumber.difference(20, 30), 0)
    }

    func testAPIParsersRejectOriginalAndAlternateTriggers() throws {
        for number in ["\"1e100\"", "1e100", "\(Int.max)", "-1", "true", "\"NaN\""] {
            let api = Data("""
            {"data":[{"start_time":1,"end_time":2,"results":[{"input_tokens":\(number),"output_tokens":1}]}]}
            """.utf8)
            XCTAssertThrowsError(try UsageParser.parseOpenAIUsagePage(data: api))
            let gemini = Data("""
            {"timeSeries":[{"points":[{"value":{"int64Value":\(number)}}]}]}
            """.utf8)
            XCTAssertThrowsError(try UsageParser.parseGeminiMonitoringSeries(data: gemini))
        }
        let max = UsageNumber.maximumCount
        for json in [
            "{\"data\":[{\"results\":[{\"input_tokens\":\(max),\"output_tokens\":1}]}]}",
            "{\"data\":[{\"results\":[{\"input_tokens\":\(max)}]},{\"results\":[{\"input_tokens\":1}]}]}",
            "{\"data\":[{\"start_time\":\"1e100\",\"results\":[]}]}"
        ] {
            XCTAssertThrowsError(try UsageParser.parseOpenAIUsagePage(data: Data(json.utf8)))
        }
        let geminiSum = Data("""
        {"timeSeries":[{"points":[{"value":{"int64Value":"\(max)"}},{"value":{"doubleValue":1}}]}]}
        """.utf8)
        XCTAssertThrowsError(try UsageParser.parseGeminiMonitoringSeries(data: geminiSum))
        for cost in ["\"NaN\"", "1e308", "-1"] {
            let data = Data("{\"data\":[{\"results\":[{\"amount\":{\"value\":\(cost)}}]}]}".utf8)
            XCTAssertThrowsError(try UsageParser.parseOpenAICostsPage(data: data))
        }
    }

    func testPostPaginationTotalsAreIndependentlyChecked() throws {
        let first = UsageParser.BucketTokenRecord(startTime: 1, endTime: 2, tokens: UsageNumber.maximumCount)
        let second = UsageParser.BucketTokenRecord(startTime: 2, endTime: 3, tokens: 1)
        XCTAssertThrowsError(try UsageParser.totalTokens(in: [first, second]))
        XCTAssertEqual(try UsageParser.totalTokens(in: [first, second], since: 2), 1)
        XCTAssertThrowsError(try UsageParser.totalTokens(in: [.init(startTime: 1, endTime: 2, tokens: Int.min)]))
    }

    func testMutatedMetricsAndDecodedSnapshotCannotTrap() throws {
        var metric = PeriodUsageMetric(period: .monthly, usedTokens: 50, limitTokens: 100, serverUsedPercent: 25)
        XCTAssertTrue(metric.isValid)
        XCTAssertEqual(metric.effectiveLimitTokens, 200)
        XCTAssertEqual(metric.remainingTokens, 150)
        for bad in [Double.nan, Double.infinity, -1, 1e100] {
            metric.serverUsedPercent = bad
            XCTAssertFalse(metric.isValid)
            XCTAssertEqual(metric.remainingPercent, 0)
            XCTAssertEqual(metric.remainingTokens, 0)
        }
        metric.serverUsedPercent = nil
        metric.usedTokens = Int.min
        XCTAssertFalse(metric.isValid)
        XCTAssertEqual(metric.remainingTokens, 0)
        metric.usedTokens = UsageNumber.maximumCount
        metric.serverUsedPercent = 1
        XCTAssertFalse(metric.isValid) // Inferred limit is outside the supported domain.
        XCTAssertEqual(metric.effectiveLimitTokens, 0)

        let url = try write("snapshot.json", "{\"openaiUsedTokens\":\(Int.min)}")
        XCTAssertNil(SharedStore.loadLocalUsageData(from: url))
        XCTAssertFalse(SharedStore.loadWidgetSnapshot(from: url).hasData)
        let item = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .fiveHours, usedTokens: 50, limitTokens: 100, serverUsedPercent: 25)]
        ))
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [item], totalCostUSD: 0, updatedAt: Date(), hasData: true
        )
        try SharedStore.saveWidgetSnapshot(snapshot, to: url)
        let valid = SharedStore.loadWidgetSnapshot(from: url)
        XCTAssertTrue(valid.hasData)
        XCTAssertEqual(valid.allServices.first?.remainingPercent, 75)
    }

    func testCodexCumulativeCountsAndMaliciousNumbers() throws {
        let url = try write("session.jsonl", [codex("100", cached: "20"), codex("100", cached: "20"),
                                            codex("50", cached: "10")].joined(separator: "\n"))
        XCTAssertEqual(scan("openai", url).previewCount, 84) // duplicate/reset do not double count
        for bad in ["\(Int.min)", "\(Int.max)", "\"1e100\"", "1e100"] {
            _ = try write("session.jsonl", codex(bad))
            XCTAssertFalse(scan("openai", url).isValid, bad)
        }
        _ = try write("session.jsonl", codex(String(UsageNumber.maximumCount), output: "1"))
        XCTAssertFalse(scan("openai", url).isValid)
    }

    func testGeminiClaudeAndCopilotRejectBadNumbersAndKeepNormalInputs() throws {
        for (provider, filename, good, bad) in [
            ("gemini", "transcript.jsonl",
             "{\"created_at\":\"\(timestamp)\",\"input_tokens\":10,\"output_tokens\":2}",
             "{\"created_at\":\"\(timestamp)\",\"input_tokens\":\(Int.min),\"output_tokens\":2}"),
            ("claude", "claude.jsonl",
             "{\"timestamp\":\"\(timestamp)\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}",
             "{\"timestamp\":\"\(timestamp)\",\"usage\":{\"input_tokens\":\(UsageNumber.maximumCount),\"output_tokens\":2}}"),
            ("copilot", "events.jsonl",
             "{\"timestamp\":\"\(timestamp)\",\"type\":\"session.usage_checkpoint\",\"data\":{\"accountingSnapshot\":{\"totalPremiumRequestCost\":12}}}",
             "{\"timestamp\":\"\(timestamp)\",\"type\":\"session.usage_checkpoint\",\"data\":{\"accountingSnapshot\":{\"totalPremiumRequestCost\":1e100}}}")
        ] {
            let url = try write(filename, good)
            XCTAssertTrue(scan(provider, url).isValid, provider)
            XCTAssertEqual(scan(provider, url).previewCount, 12, provider)
            _ = try write(filename, bad)
            XCTAssertFalse(scan(provider, url).isValid, provider)
        }
    }

    func testNativeDefaultPathsUseOnlyInjectedHomeIncludingAuxiliarySources() async throws {
        _ = try write(".gemini/tmp/a/chats/chat.json", """
        {"messages":[{"timestamp":"\(timestamp)","tokens":{"total":20,"input":10,"cached":0,"output":10}}]}
        """)
        _ = try write(".claude.json", "{\"projects\":{\"test\":{\"lastTotalInputTokens\":10,\"lastTotalOutputTokens\":5}}}")
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: root.appendingPathComponent("usage.json"), home: root)
        XCTAssertEqual(result.geminiUsedTokens, 20)
        XCTAssertEqual(result.providers?["claude"]?.usedByPeriod?.monthly, 15)
        XCTAssertEqual(result.openaiUsedTokens, 0)
        XCTAssertEqual(result.detectedProviders, ["claude"])
        _ = try write(".gemini/tmp/a/chats/chat.json", """
        {"messages":[{"timestamp":"\(timestamp)","tokens":{"input":\(Int.min)}}]}
        """)
        do {
            _ = try await LocalUsageCollector.collectAndSave(targetFileURL: root.appendingPathComponent("other.json"), home: root)
            XCTFail("Invalid auxiliary input accepted")
        } catch {}
    }

    func testGrokPercentageIsActuallyValidated() throws {
        // Base32("weekly-usage.cache"), synthetic cache key.
        let key = "O5SWK23MPEWXK43BM5SS4Y3BMNUGK"
        let url = try write("\(key).blob", "{\"value\":{\"reading\":{\"usage\":{\"percentUsed\":25}}}}")
        XCTAssertTrue(scan("grokbot", url).isValid)
        XCTAssertEqual(scan("grokbot", url).previewCount, 2_500_000)
        _ = try write("\(key).blob", "{\"value\":{\"reading\":{\"usage\":{\"percentUsed\":1e100}}}}")
        XCTAssertFalse(scan("grokbot", url).isValid)
    }

    func testSQLiteNormalTableAndUntrustedSchemas() throws {
        let normal = try database(sql: """
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
        INSERT INTO ItemTable VALUES ('windsurf.settings.cachedPlanInfo','{"planName":"Test","usage":{"usedMessages":12,"messages":100}}');
        """)
        XCTAssertTrue(scan("windsurf", normal).isValid)
        XCTAssertEqual(scan("windsurf", normal).previewCount, 12)
        for (name, schema) in [
            ("view", "CREATE VIEW ItemTable AS WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT 'windsurf.settings.cachedPlanInfo' AS key, sum(x) AS value FROM n"),
            ("generated", "CREATE TABLE ItemTable(key TEXT, seed TEXT, value TEXT GENERATED ALWAYS AS (upper(seed)))"),
            ("wrong", "CREATE TABLE ItemTable(other TEXT)"),
            ("virtual", "CREATE VIRTUAL TABLE ItemTable USING fts5(key,value)")
        ] {
            let db = try database("\(name).vscdb", sql: schema)
            XCTAssertFalse(scan("windsurf", db).isValid, name)
        }
        let invalidNumber = try database("negative.vscdb", sql: """
        CREATE TABLE ItemTable(key TEXT,value TEXT);
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"usage":{"usedMessages":-9223372036854775808}}');
        """)
        XCTAssertFalse(scan("windsurf", invalidNumber).isValid)
    }

    func testSQLiteStepLengthFileAndCancellationBudgets() throws {
        let db = try database("special?#.vscdb", sql: """
        CREATE TABLE ItemTable(key TEXT,value TEXT);
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5000)
        INSERT INTO ItemTable SELECT 'other-'||x, '{}' FROM n;
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"usage":{"usedMessages":10}}');
        """)
        XCTAssertEqual(scan("windsurf", db).previewCount, 10)
        var limits = BoundedInput.Limits()
        limits.sqliteSteps = 1000
        XCTAssertFalse(scan("windsurf", db, limits: limits).isValid)
        XCTAssertThrowsError(try WindsurfDatabase.readPlan(at: db, input: BoundedInput(cancelled: { true })))
        limits = .init()
        limits.databaseBytes = 32
        XCTAssertFalse(scan("windsurf", db, limits: limits).isValid)
        let oversized = try database("large-value.vscdb", sql: """
        CREATE TABLE ItemTable(key TEXT,value TEXT);
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo',zeroblob(4096));
        """)
        limits = .init()
        limits.jsonBytes = 1024
        XCTAssertFalse(scan("windsurf", oversized, limits: limits).isValid)
    }

    func testSQLiteSourceReplacementCannotChangeOpenedSnapshot() throws {
        let db = try database(sql: """
        CREATE TABLE ItemTable(key TEXT,value TEXT);
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"usage":{"usedMessages":7}}');
        """)
        let value = try WindsurfDatabase.readPlan(at: db, input: BoundedInput(), snapshotReady: {
            try FileManager.default.removeItem(at: db)
            XCTAssertEqual(mkfifo(db.path, 0o600), 0)
        })
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(value)) as? [String: Any]
        XCTAssertEqual((json?["usage"] as? [String: Any])?["usedMessages"] as? Int, 7)
    }

    func testSQLiteCommittedWALIsPreserved() throws {
        let dbURL = root.appendingPathComponent("wal.vscdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
        PRAGMA journal_mode=WAL;
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value BLOB);
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"usage":{"usedMessages":19}}');
        """, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        XCTAssertEqual(scan("windsurf", dbURL).previewCount, 19)
    }

    func testHiddenEntriesAlsoConsumeTraversalBudget() throws {
        for index in 0..<10 { _ = try write("hidden/.ignored-\(index)", "synthetic") }
        var limits = BoundedInput.Limits()
        limits.entries = 2
        XCTAssertThrowsError(try BoundedInput(limits: limits).files(at: root.appendingPathComponent("hidden")))
        XCTAssertEqual(try BoundedInput().files(at: root.appendingPathComponent("hidden")), [])
    }

    @MainActor
    func testLocalFailureDoesNotSuppressConfiguredRemoteRefresh() async {
        var localValue = 42
        var remoteCalls = 0
        let error = await RefreshSequence.run(local: {
            try BoundedInput(limits: {
                var limits = BoundedInput.Limits()
                limits.seconds = 0
                return limits
            }()).check()
            localValue = 0
        }, remote: {
            remoteCalls += 1
        })
        XCTAssertNotNil(error)
        XCTAssertEqual(localValue, 42)
        XCTAssertEqual(remoteCalls, 1)
        let success = await RefreshSequence.run(local: { localValue = 7 }, remote: { remoteCalls += 1 })
        XCTAssertNil(success)
        XCTAssertEqual(localValue, 7)
        XCTAssertEqual(remoteCalls, 2)
    }

    func testStreamingAndResourceLimitsIncludingNonmatchingEntries() throws {
        let url = try write("lines.jsonl", "first\r\nsecond\nlast")
        var lines: [String] = []
        try BoundedInput().lines(at: url) { lines.append($0.trimmingCharacters(in: .newlines)) }
        XCTAssertEqual(lines, ["first", "second", "last"])
        var limits = BoundedInput.Limits()
        limits.lineBytes = 4
        XCTAssertThrowsError(try BoundedInput(limits: limits).lines(at: url) { _ in })
        limits = .init()
        limits.fileBytes = 4
        XCTAssertThrowsError(try BoundedInput(limits: limits).lines(at: url) { _ in })
        limits = .init()
        limits.jsonBytes = 4
        XCTAssertThrowsError(try BoundedInput(limits: limits).data(at: url))
        limits = .init()
        limits.totalBytes = 5
        let small = try write("small.json", "{}")
        let budget = BoundedInput(limits: limits)
        _ = try budget.data(at: small)
        _ = try budget.data(at: small)
        XCTAssertThrowsError(try budget.data(at: small))
        limits = .init()
        limits.files = 1
        let oneFile = BoundedInput(limits: limits)
        _ = try oneFile.data(at: small)
        XCTAssertThrowsError(try oneFile.data(at: small))
        limits = .init()
        limits.entries = 2
        _ = try write("unrelated/deep/ignored.txt", "ignored")
        XCTAssertThrowsError(try BoundedInput(limits: limits).files(at: root))
        limits = .init()
        limits.seconds = 0
        XCTAssertThrowsError(try BoundedInput(limits: limits).files(at: root))
        XCTAssertThrowsError(try BoundedInput(cancelled: { true }).data(at: small))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: small)
        XCTAssertThrowsError(try BoundedInput().data(at: link))
        let fifo = root.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try BoundedInput().data(at: fifo))
    }

    func testBudgetFailurePreservesPreviousSnapshotAndIsNotValidEmptyScan() async throws {
        let snapshot = try write("usage.json", "{\"source\":\"previous\"}")
        let log = try write(".codex/sessions/log.jsonl", codex("100"))
        let before = try Data(contentsOf: snapshot)
        var limits = BoundedInput.Limits()
        limits.lineBytes = 10
        XCTAssertFalse(scan("openai", log, limits: limits).isValid)
        do {
            _ = try await LocalUsageCollector.collectAndSave(targetFileURL: snapshot, home: root, limits: limits)
            XCTFail("Budget failure must propagate")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: snapshot), before)
    }

    func testMalformedSavedProvidersDoNotCrashOrDiscardValidProviders() async throws {
        for invalid in ["7", "\"text\"", "null", "true", "false", "[]",
                        "{\"usedByPeriod\":7}", "{\"costUSD\":\"invalid\"}"] {
            let snapshot = try write("usage.json", """
            {"providers":{"broken":\(invalid),
              "custom":{"usedByPeriod":{"30d":12},"costUSD":1.5,"status":"Synthetic"}}}
            """)
            let result = try await LocalUsageCollector.collectAndSave(targetFileURL: snapshot, home: root)
            XCTAssertNil(result.providers?["broken"], invalid)
            XCTAssertEqual(result.providers?["custom"]?.usedByPeriod?.monthly, 12)
            XCTAssertEqual(result.providers?["custom"]?.costUSD, 1.5)
            XCTAssertEqual(result.providers?["custom"]?.status, "Synthetic")
            let saved = try JSONDecoder().decode(LocalUsageData.self, from: Data(contentsOf: snapshot))
            XCTAssertEqual(saved, result)
        }
    }

    @MainActor
    func testCancelledOrReplacedValidationCannotApplyStalePath() async {
        let validator = PathValidation()
        var oldContinuation: CheckedContinuation<LocalUsageCollector.ProviderPathScanResult, Never>?
        let oldStarted = expectation(description: "old worker started")
        let oldApplied = expectation(description: "old worker must not apply")
        oldApplied.isInverted = true
        let currentApplied = expectation(description: "current worker applies")
        let result = LocalUsageCollector.ProviderPathScanResult(isValid: true, message: "synthetic", previewCount: 1)
        validator.start(provider: "openai", path: "/synthetic/old", scan: { _, _ in
            await withCheckedContinuation { oldContinuation = $0; oldStarted.fulfill() }
        }, completion: { _ in oldApplied.fulfill() })
        await fulfillment(of: [oldStarted], timeout: 1)
        validator.cancel()
        validator.start(provider: "openai", path: "/synthetic/current", scan: { _, _ in result },
                        completion: { _ in currentApplied.fulfill() })
        oldContinuation?.resume(returning: result)
        await fulfillment(of: [currentApplied, oldApplied], timeout: 0.2)
        XCTAssertFalse(validator.isRunning)
    }

    func testGeminiSystemGeneratedAndCursorHiddenPinsAndAtomic0600Snapshot() async throws {
        _ = try write(".gemini/antigravity/brain/a/.system_generated/logs/transcript.jsonl",
                      "{\"created_at\":\"\(timestamp)\",\"input_tokens\":15,\"output_tokens\":5}")
        _ = try write("Library/Application Support/Cursor/AgentStores/cursor_agent_stores/.control/a/pin.json", "{}")
        _ = try write("Library/Application Support/Cursor/AgentStores/cursor_agent_stores/.control/.hidden/.pin.json", "{}")
        let snapshot = root.appendingPathComponent("usage.json")
        let result = try await LocalUsageCollector.collectAndSave(targetFileURL: snapshot, home: root)
        XCTAssertEqual(result.geminiUsedTokens, 20)
        XCTAssertEqual(result.providers?["cursor"]?.usedByPeriod?.monthly, 2)
        var stat = Darwin.stat()
        XCTAssertEqual(Darwin.lstat(snapshot.path, &stat), 0)
        XCTAssertEqual(stat.st_mode & 0o777, 0o600)

        let symlinkDest = root.appendingPathComponent("symlink-usage.json")
        try FileManager.default.createSymbolicLink(at: symlinkDest, withDestinationURL: snapshot)
        XCTAssertThrowsError(try BoundedInput.writeRegularFileAtomically(Data("{}".utf8), to: symlinkDest))
    }

    func testSymlinkedRootDirectoryAndSymlinkedWALAreRejected() throws {
        let realDir = root.appendingPathComponent("real-sessions")
        _ = try write("real-sessions/test.jsonl", codex("100"))
        let symlinkDir = root.appendingPathComponent("symlink-sessions")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realDir)
        XCTAssertThrowsError(try BoundedInput().files(at: symlinkDir))
        XCTAssertFalse(scan("openai", symlinkDir).isValid)

        let dbURL = try database("wal-symlink.vscdb", sql: """
        CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value BLOB);
        INSERT INTO ItemTable VALUES('windsurf.settings.cachedPlanInfo','{"usage":{"usedMessages":5}}');
        """)
        let walTarget = try write("fake-wal", "unrelated")
        let walSymlink = URL(fileURLWithPath: dbURL.path + "-wal")
        try FileManager.default.createSymbolicLink(at: walSymlink, withDestinationURL: walTarget)
        XCTAssertFalse(scan("windsurf", dbURL).isValid)
    }

    func testGCPReferencesPreserveProjectNumbersAndRejectPathOrQueryInputs() {
        for valid in ["my-project-123", "example.com:my-project-123", "123456789012"] {
            XCTAssertTrue(UsageParser.isValidGCPProjectReference(valid), valid)
        }
        for invalid in ["", "0", "-1", "123project", "123\n", "project?x=y", "../other",
                        "https://other.example", "my-project\n", "my-project/other"] {
            XCTAssertFalse(UsageParser.isValidGCPProjectReference(invalid), invalid)
        }
    }

    func testGCPProjectIDAndTrustedExecutableValidation() throws {
        XCTAssertTrue(UsageParser.isValidGCPProjectID("my-project-123"))
        XCTAssertTrue(UsageParser.isValidGCPProjectID("example.com:my-project-123"))
        for invalid in ["", "Short", "bad_underscore", "../v1/other", "my-project-", "-project",
                        "123project", "project?alt=json#frag", "my-project\n", String(repeating: "a", count: 64)] {
            XCTAssertFalse(UsageParser.isValidGCPProjectID(invalid), invalid)
        }

        let execURL = try write("bin/gcloud", "#!/bin/sh\necho token\n")
        XCTAssertEqual(Darwin.chmod(execURL.deletingLastPathComponent().path, 0o755), 0)
        XCTAssertEqual(Darwin.chmod(execURL.path, 0o755), 0)
        XCTAssertTrue(UsageParser.isTrustedExecutable(atPath: execURL.path))

        let trustedLink = root.appendingPathComponent("bin/gcloud-trusted-link")
        try FileManager.default.createSymbolicLink(at: trustedLink, withDestinationURL: execURL)
        XCTAssertTrue(UsageParser.isTrustedExecutable(atPath: trustedLink.path))

        let groupWritable = try write("bin/gcloud-gw", "#!/bin/sh\n")
        XCTAssertEqual(Darwin.chmod(groupWritable.path, 0o775), 0)
        XCTAssertFalse(UsageParser.isTrustedExecutable(atPath: groupWritable.path))

        let symlinkToUntrusted = root.appendingPathComponent("bin/gcloud-link")
        try FileManager.default.createSymbolicLink(at: symlinkToUntrusted, withDestinationURL: groupWritable)
        XCTAssertFalse(UsageParser.isTrustedExecutable(atPath: symlinkToUntrusted.path))
        XCTAssertFalse(UsageParser.isTrustedExecutable(atPath: execURL.path, currentUID: 999_999))

        let badDirExec = try write("writable-bin/gcloud", "#!/bin/sh\n")
        XCTAssertEqual(Darwin.chmod(badDirExec.path, 0o755), 0)
        XCTAssertEqual(Darwin.chmod(badDirExec.deletingLastPathComponent().path, 0o777), 0)
        XCTAssertFalse(UsageParser.isTrustedExecutable(atPath: badDirExec.path))
        let linkedBadDirectory = root.appendingPathComponent("bin/gcloud-bad-parent")
        try FileManager.default.createSymbolicLink(at: linkedBadDirectory, withDestinationURL: badDirExec)
        XCTAssertFalse(UsageParser.isTrustedExecutable(atPath: linkedBadDirectory.path))
    }
}
