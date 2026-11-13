import XCTest
@testable import AIMeter

final class OnboardingTests: XCTestCase {

    /// Window dots: never more than five visible, the window follows the
    /// current page by exactly one step, and the current page is inside it.
    func testWindowDotsSlideOnePageAtATime() {
        let total = 12
        var previousStart = 0
        for current in 0..<total {
            let dots = OnboardingWindowDots(current: current, total: total)
            XCTAssertEqual(dots.windowSize, 5)
            XCTAssertLessThanOrEqual(dots.windowStart, current)
            XCTAssertGreaterThanOrEqual(dots.windowEnd, current)
            XCTAssertEqual(dots.windowEnd - dots.windowStart, 4)
            if current > 0 {
                let step = dots.windowStart - previousStart
                XCTAssertTrue(step == 0 || step == 1, "window jumped by \(step) at page \(current)")
            }
            previousStart = dots.windowStart
        }
        let first = OnboardingWindowDots(current: 0, total: total)
        XCTAssertEqual(first.windowStart, 0)
        let last = OnboardingWindowDots(current: total - 1, total: total)
        XCTAssertEqual(last.windowEnd, total - 1)
    }

    func testWindowDotsShowEverythingWhenFewPages() {
        let dots = OnboardingWindowDots(current: 2, total: 4)
        XCTAssertEqual(dots.windowSize, 4)
        XCTAssertEqual(dots.windowStart, 0)
        XCTAssertEqual(dots.windowEnd, 3)
    }

    /// Every concern has an option, a non-assertive escape, and a match text
    /// that mirrors the choice without promising an outcome.
    func testConcernCopyIsCompleteAndMakesNoGuarantees() {
        XCTAssertEqual(OnboardingConcern.allCases.count, 4)
        for concern in OnboardingConcern.allCases {
            XCTAssertFalse(concern.optionTitle.isEmpty)
            XCTAssertFalse(concern.matchHeadline.isEmpty)
            XCTAssertFalse(concern.matchReason.isEmpty)
            for banned in ["必ず", "絶対に", "誰でも"] {
                XCTAssertFalse(concern.matchHeadline.contains(banned), "\(concern) headline")
                XCTAssertFalse(concern.matchReason.contains(banned), "\(concern) reason")
            }
        }
        XCTAssertEqual(OnboardingConcern.notSureYet.optionTitle, "まだわからない")
        XCTAssertFalse(OnboardingConcern.notSureYet.matchHeadline.contains("ぴったり"))
    }

    func testConcernRawValueRoundTrips() {
        for concern in OnboardingConcern.allCases {
            XCTAssertEqual(OnboardingConcern(rawValue: concern.rawValue), concern)
        }
    }
}
