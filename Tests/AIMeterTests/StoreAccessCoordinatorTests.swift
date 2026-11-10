import XCTest
@testable import AIMeter

final class StoreAccessCoordinatorTests: XCTestCase {
    private enum TestFailure: Error { case expected }

    func testSelectionChangeAndRemovalRejectOldRuns() async throws {
        let coordinator = StoreAccessCoordinator()
        var selection = "original"
        var committed = 0
        let beforeChange = await coordinator.beginRun()
        await coordinator.changeSelection { selection = "replacement" }
        let rejectedAfterChange = await coordinator.commit(beforeChange) { committed += 1 }
        XCTAssertFalse(rejectedAfterChange)
        XCTAssertEqual(selection, "replacement")

        let beforeRemoval = await coordinator.beginRun()
        await coordinator.changeSelection { selection = "" }
        let rejectedAfterRemoval = await coordinator.commit(beforeRemoval) { committed += 1 }
        XCTAssertFalse(rejectedAfterRemoval)
        XCTAssertEqual(selection, "")
        XCTAssertEqual(committed, 0)

        let current = await coordinator.beginRun()
        let accepted = await coordinator.commit(current) { committed += 1 }
        XCTAssertTrue(accepted)
        XCTAssertEqual(committed, 1)
        let duplicate = await coordinator.commit(current) { committed += 1 }
        XCTAssertFalse(duplicate)
        XCTAssertEqual(committed, 1)
    }

    func testFailedChangeStillInvalidatesOldRun() async throws {
        let coordinator = StoreAccessCoordinator()
        let old = await coordinator.beginRun()
        do {
            try await coordinator.changeSelection { throw TestFailure.expected }
            XCTFail("Expected failure")
        } catch TestFailure.expected { }
        let accepted = await coordinator.commit(old) { XCTFail("Old run committed") }
        XCTAssertFalse(accepted)
    }

    func testFailedCommitPropagatesAndDoesNotReviveOldRun() async throws {
        let coordinator = StoreAccessCoordinator()
        let old = await coordinator.beginRun()
        await coordinator.changeSelection { }
        let current = await coordinator.beginRun()
        do {
            _ = try await coordinator.commit(current) { throw TestFailure.expected }
            XCTFail("Expected failure")
        } catch TestFailure.expected { }
        let acceptedOld = await coordinator.commit(old) { XCTFail("Old run committed") }
        XCTAssertFalse(acceptedOld)
        let acceptedCurrent = await coordinator.commit(current) { XCTFail("Failed run committed twice") }
        XCTAssertFalse(acceptedCurrent)
        let fresh = await coordinator.beginRun()
        var commits = 0
        let acceptedFresh = await coordinator.commit(fresh) { commits += 1 }
        XCTAssertTrue(acceptedFresh)
        XCTAssertEqual(commits, 1)
    }

    func testNewRunSupersedesOldAndCancelledSelectionDoesNothing() async {
        let coordinator = StoreAccessCoordinator()
        let old = await coordinator.beginRun()
        let current = await coordinator.beginRun()
        let rejected = await coordinator.commit(old) { XCTFail("Old run committed") }
        XCTAssertFalse(rejected)
        // A cancelled panel does not call changeSelection.
        var commits = 0
        let accepted = await coordinator.commit(current) { commits += 1 }
        XCTAssertTrue(accepted)
        XCTAssertEqual(commits, 1)
    }
}
