import XCTest
@testable import AIMeter

final class StoreSourceStateTests: XCTestCase {
    func testCancellationPreservesExistingGrantAndRun() async throws {
        let state = StoreSourceState(sourceIDs: ["brain"])
        await state.setEnabled(true)
        await state.setPermission(.granted, for: "brain")
        let maybeRun = await state.begin()
        let run = try XCTUnwrap(maybeRun)
        let before = await state.snapshot()
        await state.selectionCancelled()
        let after = await state.snapshot()
        XCTAssertEqual(before, after)
        let accepted = await state.finish(.success(count: 1, date: Date()), source: "brain", run: run)
        XCTAssertTrue(accepted)
    }

    func testRevocationRejectsOldRunAndRequiresFreshPartialResult() async throws {
        let state = StoreSourceState(sourceIDs: ["brain", "chats"])
        await state.setEnabled(true)
        await state.setPermission(.granted, for: "brain")
        await state.setPermission(.granted, for: "chats")
        let pending1 = await state.begin()
        let first = try XCTUnwrap(pending1)
        let now = Date()
        _ = await state.finish(.success(count: 3, date: now), source: "brain", run: first)
        _ = await state.finish(.success(count: 4, date: now), source: "chats", run: first)
        let checked2 = await state.snapshot().coverage
        XCTAssertEqual(checked2, .complete)

        await state.setPermission(.revoked, for: "chats")
        let checked3 = await state.finish(.success(count: 9, date: now), source: "chats", run: first)
        XCTAssertFalse(checked3)
        let checked4 = await state.snapshot().coverage
        XCTAssertEqual(checked4, .none)
        let pending5 = await state.begin()
        let next = try XCTUnwrap(pending5)
        XCTAssertEqual(next.sources, ["brain"])
        let checked6 = await state.finish(.success(count: 3, date: now), source: "brain", run: next)
        XCTAssertTrue(checked6)
        let checked7 = await state.snapshot().coverage
        XCTAssertEqual(checked7, .partial)
    }

    func testZeroIsDistinctFromMissingAndInvalid() async throws {
        let state = StoreSourceState(sourceIDs: ["a", "b", "c"])
        await state.setEnabled(true)
        for id in ["a", "b", "c"] { await state.setPermission(.granted, for: id) }
        let pending8 = await state.begin()
        let run = try XCTUnwrap(pending8)
        let now = Date()
        let checked9 = await state.finish(.success(count: -1, date: now), source: "a", run: run)
        XCTAssertFalse(checked9)
        let checked10 = await state.finish(.success(count: 0, date: now), source: "a", run: run)
        XCTAssertTrue(checked10)
        let checked11 = await state.finish(.notDetected, source: "b", run: run)
        XCTAssertTrue(checked11)
        let checked12 = await state.finish(.invalidTarget, source: "c", run: run)
        XCTAssertTrue(checked12)
        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.coverage, .partial)
        XCTAssertEqual(snapshot.sources["a"]?.collection, .success(.init(count: 0, date: now)))
        XCTAssertEqual(snapshot.sources["b"]?.collection, .notDetected)
        XCTAssertEqual(snapshot.sources["c"]?.collection, .invalidTarget)
        let checked13 = await state.finish(.failed, source: "a", run: run)
        XCTAssertFalse(checked13)
    }

    func testDisableAndNewRunRejectDelayedResults() async throws {
        let state = StoreSourceState(sourceIDs: ["a"])
        await state.setEnabled(true)
        await state.setPermission(.granted, for: "a")
        let pending14 = await state.begin()
        let old = try XCTUnwrap(pending14)
        let pending15 = await state.begin()
        let fresh = try XCTUnwrap(pending15)
        let checked16 = await state.finish(.failed, source: "a", run: old)
        XCTAssertFalse(checked16)
        await state.setEnabled(false)
        let checked17 = await state.finish(.failed, source: "a", run: fresh)
        XCTAssertFalse(checked17)
        let checked18 = await state.begin()
        XCTAssertNil(checked18)
        let checked19 = await state.snapshot().coverage
        XCTAssertEqual(checked19, .none)
    }

    func testReplacingGrantedSelectionInvalidatesRunningCollection() async throws {
        let state = StoreSourceState(sourceIDs: ["a"])
        await state.setEnabled(true)
        await state.setPermission(.granted, for: "a")
        let pending = await state.begin()
        let run = try XCTUnwrap(pending)
        await state.setPermission(.granted, for: "a")
        let accepted = await state.finish(.success(count: 1, date: Date()), source: "a", run: run)
        XCTAssertFalse(accepted)
    }

    func testFailureKeepsPreviousSuccessForExplicitlyStalePresentation() async throws {
        let state = StoreSourceState(sourceIDs: ["a"])
        await state.setEnabled(true)
        await state.setPermission(.granted, for: "a")
        let pending20 = await state.begin()
        let first = try XCTUnwrap(pending20)
        let now = Date()
        _ = await state.finish(.success(count: 7, date: now), source: "a", run: first)
        let pending21 = await state.begin()
        let next = try XCTUnwrap(pending21)
        _ = await state.finish(.failed, source: "a", run: next)
        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.coverage, .none)
        XCTAssertEqual(snapshot.sources["a"]?.collection, .failed)
        XCTAssertEqual(snapshot.sources["a"]?.previousSuccess, .init(count: 7, date: now))
    }
}
