import XCTest
@testable import AIMeter
import AIMeterCore

final class AIMeterTests: XCTestCase {
    func testFormatTokenCount() {
        XCTAssertEqual(formatTokenCount(0), "0")
        XCTAssertEqual(formatTokenCount(-50), "0")
        XCTAssertEqual(formatTokenCount(999), "999")
        XCTAssertEqual(formatTokenCount(1_500), "1.5K")
        XCTAssertEqual(formatTokenCount(640_000), "640.0K")
        XCTAssertEqual(formatTokenCount(1_250_000), "1.25M")
        XCTAssertEqual(formatTokenCount(10_000_000), "10.00M")
    }

    func testGaugeWarningSymbolAndColorThresholds() {
        XCTAssertNil(gaugeWarningSymbol(for: 0.80))
        XCTAssertNil(gaugeWarningSymbol(for: 0.35))
        XCTAssertEqual(gaugeWarningSymbol(for: 0.34), "exclamationmark.triangle.fill")
        XCTAssertEqual(gaugeWarningSymbol(for: 0.15), "exclamationmark.triangle.fill")
        XCTAssertEqual(gaugeWarningSymbol(for: 0.14), "exclamationmark.octagon.fill")
    }

    func testStartOfMonthAndPeriodTimestampsAreUTC() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let oct1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 0, minute: 0, second: 0))!
        let oct19Start = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 0, second: 0))!
        let midMonth = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 30, second: 0))!

        XCTAssertEqual(UsageParser.startTimestamp(for: .monthly, now: midMonth), Int(oct1.timeIntervalSince1970))
        XCTAssertEqual(UsageParser.startTimestamp(for: .daily, now: midMonth), Int(oct19Start.timeIntervalSince1970))
        XCTAssertEqual(UsageParser.startTimestamp(for: .fiveHours, now: midMonth), Int(midMonth.timeIntervalSince1970) - 5 * 3600)
        XCTAssertEqual(UsageParser.startTimestamp(for: .twoHours, now: midMonth), Int(midMonth.timeIntervalSince1970) - 2 * 3600)
    }

    func testPeriodUsageMetricCalculationAndServerRateLimitSync() {
        let localMetric = PeriodUsageMetric(period: .fiveHours, usedTokens: 42_000, limitTokens: 150_000)
        XCTAssertEqual(localMetric.remainingTokens, 108_000)
        XCTAssertEqual(localMetric.remainingPercent, 72)

        let syncedMetric = PeriodUsageMetric(
            period: .weekly,
            usedTokens: 160_000_000,
            limitTokens: 200_000_000,
            serverUsedPercent: 56.0,
            resetTimestamp: 1792888154
        )
        XCTAssertEqual(syncedMetric.remainingPercent, 44)
        XCTAssertEqual(syncedMetric.effectiveLimitTokens, 285_714_286)

        // When usedTokens is 0 but serverUsedPercent is known (e.g. GrokBot weekly cache), remainingTokens scales by ratio
        let grokMetric = PeriodUsageMetric(
            period: .weekly,
            usedTokens: 0,
            limitTokens: 10_000_000,
            serverUsedPercent: 90.0
        )
        XCTAssertEqual(grokMetric.remainingPercent, 10)
        XCTAssertEqual(grokMetric.remainingTokens, 1_000_000)
    }

    func testCustomSubscriptionConfigCustomizationAndPeriodToggles() throws {
        let grok = CustomSubscriptionConfig.grokbotPreset()
        XCTAssertTrue(grok.isPeriodEnabled(.twoHours))
        XCTAssertTrue(grok.isPeriodEnabled(.daily))
        XCTAssertTrue(grok.isPeriodEnabled(.weekly))
        XCTAssertFalse(grok.isPeriodEnabled(.monthly))

        var sub = CustomSubscriptionConfig.claudePreset()
        XCTAssertTrue(sub.isPeriodEnabled(.fiveHours))
        XCTAssertFalse(sub.isPeriodEnabled(.daily))
        XCTAssertTrue(sub.isPeriodEnabled(.weekly))

        sub.setPeriod(.daily, enabled: true)
        XCTAssertTrue(sub.isPeriodEnabled(.daily))

        // Should never allow disabling all periods (at least 1 remains)
        sub.setPeriod(.twoHours, enabled: false)
        sub.setPeriod(.fiveHours, enabled: false)
        sub.setPeriod(.daily, enabled: false)
        sub.setPeriod(.weekly, enabled: false)
        sub.setPeriod(.monthly, enabled: false)
        XCTAssertEqual(sub.enabledPeriodRawValues.count, 1)

        sub.limit2h = -5
        sub.limit5h = -10
        sub.sanitize()
        XCTAssertEqual(sub.limit2h, 1)
        XCTAssertEqual(sub.limit5h, 1)
    }

    func testDecodeMultiPeriodLocalUsageJSONWithCustomProviders() throws {
        let json = """
        {
          "openaiUsedTokens": 170218895,
          "openaiCostUSD": 460.66,
          "openaiUsedByPeriod": {
            "2h": 8453202,
            "5h": 21556465,
            "1d": 40036059,
            "7d": 160952376,
            "30d": 170218895
          },
          "openaiServerUsedPercentByPeriod": {
            "7d": 56.0
          },
          "openaiResetAtByPeriod": {
            "7d": 1792888154
          },
          "openaiPlanType": "prolite",
          "geminiUsedTokens": 2296092,
          "geminiCostUSD": 4.95,
          "geminiUsedByPeriod": {
            "5h": 535813,
            "1d": 535813,
            "7d": 535813,
            "30d": 2296092
          },
          "providers": {
            "grokbot": {
              "usedByPeriod": {
                "2h": 0,
                "5h": 2330,
                "1d": 10754,
                "7d": 58159,
                "30d": 87440
              },
              "serverUsedPercentByPeriod": {
                "7d": 90.53
              },
              "resetAtByPeriod": {
                "7d": 1792468435
              },
              "costUSD": 75.63,
              "status": "Grok Bot Plan"
            }
          },
          "detectedProviders": ["grokbot", "claude", "cursor"]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalUsageData.self, from: json)
        XCTAssertEqual(decoded.openaiUsedByPeriod?.twoHours, 8453202)
        XCTAssertEqual(decoded.openaiUsedByPeriod?.fiveHours, 21556465)
        XCTAssertEqual(decoded.providers?["grokbot"]?.serverUsedPercentByPeriod?.weekly, 90.53)
        XCTAssertEqual(decoded.providers?["grokbot"]?.resetAtByPeriod?.weekly, 1792468435)
        XCTAssertEqual(decoded.providers?["grokbot"]?.status, "Grok Bot Plan")
        XCTAssertEqual(decoded.detectedProviders, ["grokbot", "claude", "cursor"])
    }

    func testParseOpenAIUsagePageAndPagination() throws {
        let sampleJSON = """
        {
          "object": "page",
          "data": [
            {
              "start_time": 1790812800,
              "end_time": 1790899200,
              "results": [
                {"input_tokens": 1200, "output_tokens": 300},
                {"input_tokens": "500", "output_tokens": 250}
              ]
            }
          ],
          "has_more": true,
          "next_page": "page_abc123"
        }
        """.data(using: .utf8)!

        let parsed = try UsageParser.parseOpenAIUsagePageWithBuckets(data: sampleJSON)
        XCTAssertEqual(parsed.totalTokens, 2250)
        XCTAssertEqual(parsed.buckets.count, 1)
        XCTAssertEqual(parsed.buckets.first?.tokens, 2250)
        XCTAssertEqual(parsed.nextPage, "page_abc123")
    }

    func testParseOpenAICostsPageSupportsNumericAndStringAmounts() throws {
        let sampleJSON = """
        {
          "object": "page",
          "data": [
            {
              "results": [
                {"amount": {"value": 1.25, "currency": "usd"}},
                {"amount": {"value": "2.75", "currency": "usd"}}
              ]
            }
          ],
          "has_more": false,
          "next_page": "ignored_when_has_more_false"
        }
        """.data(using: .utf8)!

        let parsed = try UsageParser.parseOpenAICostsPage(data: sampleJSON)
        XCTAssertEqual(parsed.costUSD, 4.00, accuracy: 0.0001)
        XCTAssertNil(parsed.nextPage)
    }

    func testParseGeminiMonitoringSeries() throws {
        let sampleJSON = """
        {
          "timeSeries": [
            {
              "points": [
                {"value": {"int64Value": "15000"}},
                {"value": {"int64Value": 5000}}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let total = try UsageParser.parseGeminiMonitoringSeries(data: sampleJSON)
        XCTAssertEqual(total, 20000)
    }

    func testLocalUsageCollectorCutoffsAndISOParsing() {
        let fixedDate = Date(timeIntervalSince1970: 1729344000) // 2024-10-19T13:20:00Z
        let cutoffs = LocalUsageCollector.calculateCutoffs(now: fixedDate)

        XCTAssertEqual(cutoffs["2h"], fixedDate.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(cutoffs["5h"], fixedDate.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(cutoffs["1d"], fixedDate.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(cutoffs["7d"], fixedDate.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(cutoffs["30d"], fixedDate.addingTimeInterval(-30 * 86400))

        let parsedStandard = LocalUsageCollector.parseISODate("2024-10-19T13:20:00Z")
        XCTAssertNotNil(parsedStandard)
        XCTAssertEqual(parsedStandard?.timeIntervalSince1970, 1729344000)

        let parsedFractional = LocalUsageCollector.parseISODate("2024-10-19T13:20:00.500Z")
        XCTAssertNotNil(parsedFractional)

        let parsedOffset = LocalUsageCollector.parseISODate("2024-10-19T13:20:00+00:00")
        XCTAssertNotNil(parsedOffset)
    }

    func testLocalUsageCollectorCollectAndSaveAtomically() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetFile = tempDir.appendingPathComponent("test_usage.json")
        let collected = try await LocalUsageCollector.collectAndSave(targetFileURL: targetFile, home: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetFile.path))
        XCTAssertEqual(collected.source, "local_logs_native")
        XCTAssertNotNil(collected.updatedAt)

        let readBackData = try Data(contentsOf: targetFile)
        let decoded = try JSONDecoder().decode(LocalUsageData.self, from: readBackData)
        XCTAssertEqual(decoded.source, "local_logs_native")
    }

    func testPeriodFilterDisplaysOnlyMatchingMetrics() {
        let metrics = [
            PeriodUsageMetric(period: .fiveHours, usedTokens: 100, limitTokens: 1000),
            PeriodUsageMetric(period: .weekly, usedTokens: 200, limitTokens: 2000),
            PeriodUsageMetric(period: .monthly, usedTokens: 300, limitTokens: 3000)
        ]

        let sectionFilteredTo2h = ProviderUsageSection(
            title: "Test",
            subtitle: "",
            usedCostUSD: 0,
            budgetUSD: 0,
            metrics: metrics,
            selectedFilter: .twoHours,
            highlightedPeriod: nil
        )
        // 2h is not in metrics, so displayedMetrics must be empty, not fall back to all metrics
        XCTAssertTrue(sectionFilteredTo2h.displayedMetrics.isEmpty)

        let sectionFilteredTo5h = ProviderUsageSection(
            title: "Test",
            subtitle: "",
            usedCostUSD: 0,
            budgetUSD: 0,
            metrics: metrics,
            selectedFilter: .fiveHours,
            highlightedPeriod: nil
        )
        XCTAssertEqual(sectionFilteredTo5h.displayedMetrics.count, 1)
        XCTAssertEqual(sectionFilteredTo5h.displayedMetrics.first?.period, .fiveHours)

        let sectionUnfiltered = ProviderUsageSection(
            title: "Test",
            subtitle: "",
            usedCostUSD: 0,
            budgetUSD: 0,
            metrics: metrics,
            selectedFilter: nil,
            highlightedPeriod: nil
        )
        XCTAssertEqual(sectionUnfiltered.displayedMetrics.count, 3)
    }

    func testProviderUnitAndCompactUsageFormatting() {
        XCTAssertEqual(providerUnit(for: "cursor"), "req")
        XCTAssertEqual(providerUnit(for: "copilot"), "req")
        XCTAssertEqual(providerUnit(for: "perplexity"), "req")
        XCTAssertEqual(providerUnit(for: "trae"), "req")

        XCTAssertEqual(providerUnit(for: "windsurf"), "msgs")
        XCTAssertEqual(providerUnit(for: "poe"), "pts")
        XCTAssertEqual(providerUnit(for: "devin"), "ACU")

        XCTAssertEqual(providerUnit(for: "openai"), "tokens")
        XCTAssertEqual(providerUnit(for: "gemini"), "tokens")
        XCTAssertEqual(providerUnit(for: "claude"), "tokens")
        XCTAssertEqual(providerUnit(for: "grokbot"), "tokens")
        XCTAssertEqual(providerUnit(for: "deepseek"), "tokens")

        // Token formatting
        XCTAssertEqual(formatCompactUsage(140_000_000, unit: "tokens"), "140M")
        XCTAssertEqual(formatCompactUsage(2_500_000, unit: "tokens"), "2.5M")
        XCTAssertEqual(formatCompactUsage(45_000, unit: "tokens"), "45K")
        XCTAssertEqual(formatCompactUsage(500, unit: "tokens"), "500")

        // Request / msgs / pts / ACU formatting
        XCTAssertEqual(formatCompactUsage(23, unit: "req"), "23")
        XCTAssertEqual(formatCompactUsage(1_500, unit: "req"), "1.5K")
        XCTAssertEqual(formatCompactUsage(25_000, unit: "msgs"), "25K")
    }

    func testProgressiveDisclosureSummaryFiltering() {
        let metrics = [
            PeriodUsageMetric(period: .twoHours, usedTokens: 900, limitTokens: 1000),   // 10% remaining (bottleneck)
            PeriodUsageMetric(period: .fiveHours, usedTokens: 500, limitTokens: 1000),  // 50% remaining
            PeriodUsageMetric(period: .daily, usedTokens: 300, limitTokens: 1000),      // 70% remaining
            PeriodUsageMetric(period: .weekly, usedTokens: 200, limitTokens: 1000),     // 80% remaining
            PeriodUsageMetric(period: .monthly, usedTokens: 100, limitTokens: 1000)     // 90% remaining (monthly)
        ]

        // Detailed mode (isDetailed = true) shows all 5
        let detailedSection = ProviderUsageSection(
            title: "Test",
            subtitle: "",
            usedCostUSD: 10.0,
            budgetUSD: 50.0,
            metrics: metrics,
            selectedFilter: nil,
            highlightedPeriod: nil,
            isDetailed: true
        )
        XCTAssertEqual(detailedSection.displayedMetrics.count, 5)

        // Summary mode (isDetailed = false) shows bottleneck (2h) and monthly (30d) = 2
        let summarySection = ProviderUsageSection(
            title: "Test",
            subtitle: "",
            usedCostUSD: 10.0,
            budgetUSD: 50.0,
            metrics: metrics,
            selectedFilter: nil,
            highlightedPeriod: nil,
            isDetailed: false
        )
        XCTAssertEqual(summarySection.displayedMetrics.count, 2)
        XCTAssertEqual(summarySection.displayedMetrics[0].period, .twoHours)
        XCTAssertEqual(summarySection.displayedMetrics[1].period, .monthly)

        // When bottleneck IS the monthly limit, show only 1 row
        let monthlyBottleneckMetrics = [
            PeriodUsageMetric(period: .twoHours, usedTokens: 100, limitTokens: 1000),
            PeriodUsageMetric(period: .monthly, usedTokens: 950, limitTokens: 1000) // 5% remaining
        ]
        let singleRowSummary = ProviderUsageSection(
            title: "Test",
            subtitle: "",
            usedCostUSD: 10.0,
            budgetUSD: 50.0,
            metrics: monthlyBottleneckMetrics,
            selectedFilter: nil,
            highlightedPeriod: nil,
            isDetailed: false
        )
        XCTAssertEqual(singleRowSummary.displayedMetrics.count, 1)
        XCTAssertEqual(singleRowSummary.displayedMetrics.first?.period, .monthly)
    }

    func testMenuBarDisplayModeLabelsAndHonestPresets() {
        XCTAssertEqual(MenuBarDisplayMode.smart.label, "最逼迫のみ (推奨)")
        XCTAssertEqual(MenuBarDisplayMode.compact.label, "コンパクト (2つ)")
        XCTAssertEqual(MenuBarDisplayMode.iconOnly.label, "数値のみ")
        XCTAssertEqual(MenuBarDisplayMode.all.label, "すべて表示")

        // Presets should have 0.0 initial usedCostUSD (no fake hardcoded monthly charges)
        let presetIds = ["grokbot", "claude", "cursor", "windsurf", "copilot", "devin", "perplexity", "deepseek", "poe", "trae"]
        for id in presetIds {
            let preset = CustomSubscriptionConfig.preset(forId: id)
            XCTAssertNotNil(preset)
            XCTAssertEqual(preset?.usedCostUSD, 0.0, "Preset \(id) should default to 0.0 usedCostUSD")
        }

        // Windsurf only has cumulative total count, so only 30d should be enabled by default
        let windsurf = CustomSubscriptionConfig.windsurfPreset()
        XCTAssertEqual(windsurf.enabledPeriodRawValues, ["30d"])
    }

    func testWidgetSnapshotGeneration() throws {
        let date = Date(timeIntervalSince1970: 1_792_400_000)
        let codex = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "openai", name: "Codex", shortName: "OAI", iconName: "cpu", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .fiveHours, usedTokens: 50, limitTokens: 100),
                      PeriodUsageMetric(period: .weekly, usedTokens: 90, limitTokens: 100)]
        ))
        let gemini = try XCTUnwrap(WidgetServiceItem.fromMetrics(
            id: "gemini", name: "Gemini", shortName: "Gem", iconName: "sparkle", unit: "tokens",
            metrics: [PeriodUsageMetric(period: .monthly, usedTokens: 25, limitTokens: 100)]
        ))
        let snapshot = AIMeterWidgetSnapshot.make(
            services: [gemini, codex], totalCostUSD: 3.30, updatedAt: date, hasData: true
        )
        XCTAssertTrue(snapshot.hasData)
        XCTAssertEqual(snapshot.allServices.map(\.id), ["openai", "gemini"])
        XCTAssertEqual(snapshot.mostCriticalService?.bottleneckPeriod, .weekly)
        XCTAssertEqual(snapshot.mostCriticalService?.remainingPercent, 10)
        XCTAssertEqual(snapshot.totalCostUSD, 3.30)
        XCTAssertEqual(snapshot.updatedAt, date)
    }
}
