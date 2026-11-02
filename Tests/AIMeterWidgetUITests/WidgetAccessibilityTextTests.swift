import AIMeterCore
@testable import AIMeterWidgetUI
import XCTest

final class WidgetAccessibilityTextTests: XCTestCase {
    func testOfficialAndConfiguredPercentagesHaveDifferentSpokenMeanings() {
        let official = WidgetRowText(item: WidgetUIFixtures.item(percent: 35, source: .official), showAmounts: true)
        let configured = WidgetRowText(item: WidgetUIFixtures.item(percent: 35, source: .configuredLimit), showAmounts: true)

        XCTAssertTrue(official.accessibilityLabel.contains("公式残量、残り35パーセント"))
        XCTAssertFalse(official.accessibilityLabel.contains("設定上限からの目安"))
        XCTAssertTrue(configured.accessibilityLabel.contains("設定上限からの目安、残り35パーセント"))
        XCTAssertFalse(configured.accessibilityLabel.contains("公式残量"),
                       "A configured estimate must not be announced as official quota")
        for text in [official, configured] {
            XCTAssertTrue(text.accessibilityLabel.contains("利用量 1.2M、上限 10M tokens"))
            XCTAssertFalse(text.accessibilityLabel.contains("1.2M/10M"))
        }
    }

    func testUnavailableQuotaIsNotAnnouncedAsZeroAndKeepsEstimatedUsageSeparate() {
        let item = WidgetUIFixtures.item(source: .unavailable)
        let text = WidgetRowText(item: item, showAmounts: true)

        XCTAssertTrue(text.accessibilityLabel.contains("公式残量 未取得"))
        XCTAssertFalse(text.accessibilityLabel.contains("残り0パーセント"))
        XCTAssertFalse(text.accessibilityLabel.contains("リセット："),
                       "An unavailable quota must not imply that a known reset will restore it")
        XCTAssertEqual(text.usage, "推定使用量 1.2M tokens")
        XCTAssertTrue(text.accessibilityLabel.contains("推定使用量 1.2M tokens"))
        XCTAssertFalse(text.accessibilityLabel.contains("/10M"))
    }

    func testUsageOffRemovesAmountsFromBothVisibleAndSpokenPresentation() {
        for source in [RemainingQuotaSource.official, .configuredLimit, .unavailable] {
            let item = WidgetUIFixtures.item(source: source)
            let hidden = WidgetRowText(item: item, showAmounts: false)
            let shown = WidgetRowText(item: item, showAmounts: true)

            XCTAssertNil(hidden.usage)
            XCTAssertFalse(hidden.accessibilityLabel.contains(item.usedDisplay))
            XCTAssertFalse(hidden.accessibilityLabel.contains("10M"))
            XCTAssertFalse(hidden.accessibilityLabel.contains("tokens"))
            XCTAssertNotNil(shown.usage)
            XCTAssertTrue(shown.accessibilityLabel.contains(item.usedDisplay))
            XCTAssertTrue(hidden.accessibilityLabel.contains(item.name))
            XCTAssertTrue(hidden.accessibilityLabel.contains(item.periodLabel))
        }
    }

    func testQuotaOnlyRowsNeverInventUsageAmountsEvenWhenAmountsAreEnabled() {
        for source in [RemainingQuotaSource.official, .unavailable] {
            let item = WidgetUIFixtures.item(source: source, quotaOnly: true, longText: true)
            for showAmounts in [false, true] {
                let text = WidgetRowText(item: item, showAmounts: showAmounts)
                XCTAssertNil(text.usage)
                XCTAssertFalse(text.accessibilityLabel.contains("推定使用量"))
                XCTAssertFalse(text.accessibilityLabel.contains("0/0"))
                XCTAssertTrue(text.accessibilityLabel.contains(item.periodLabel))
            }
        }
    }

    func testTruncatedVisualFieldsRetainTheirFullMeaningInAccessibility() throws {
        let item = WidgetUIFixtures.item(source: .configuredLimit, longText: true)
        let text = WidgetRowText(item: item, showAmounts: true)

        XCTAssertTrue(text.accessibilityLabel.contains(item.name), "Use the full service name, not its short label")
        XCTAssertTrue(text.accessibilityLabel.contains(item.periodLabel), "Keep every model in the full quota label")
        XCTAssertTrue(text.accessibilityLabel.contains(item.unit), "Keep the full unit even if its visual field truncates")
        XCTAssertTrue(text.accessibilityLabel.contains(try XCTUnwrap(item.resetText)))
        XCTAssertFalse(text.accessibilityLabel.contains("…"), "Visual ellipsis must not replace the full spoken fields")
    }

    func testNoResetIsAnnouncedWhenTheSnapshotHasNoResetInformation() {
        let item = WidgetUIFixtures.item(includeReset: false)
        let text = WidgetRowText(item: item, showAmounts: true)
        XCTAssertFalse(text.accessibilityLabel.contains("リセット："))
        XCTAssertTrue(text.accessibilityLabel.contains("残り60パーセント"))
    }

    func testMediumRowsDoNotAnnounceAnInvisibleReset() {
        let text = WidgetRowText(item: WidgetUIFixtures.item(), showAmounts: true, showReset: false)
        XCTAssertFalse(text.accessibilityLabel.contains("リセット："))
        XCTAssertTrue(text.accessibilityLabel.contains("利用量"))
    }
}
