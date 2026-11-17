import Foundation
import AIMeterCore

/// The Copilot vertical slice of the Store connection plan
/// (docs/STORE_CONNECTION_DESIGN.md, connection plan stage 6, third
/// service after Codex and Claude). The flow mirrors
/// `StoreClaudePipeline`: saved selection → identity record →
/// two-stage verified scoped open → FD-scoped collection → source
/// state → display state.
///
/// The connected input is the `copilot.sessions` directory selection;
/// the collector walks it for `events.jsonl` files. Two deliberate
/// classification choices, mirroring the Claude slice:
///
/// - Every value a run produces is reference-classified in this slice.
///   The design document fixes the checkpoints as reference values
///   (cumulative premium-request costs with no proven period start,
///   never merged into the period totals), and this slice extends that
///   treatment to the message counts as well: the presentation carries
///   them only inside `ReferenceValue`, never as a `LocalUsageData`,
///   so no caller can apply them to the app's confirmed display or
///   persist them as measured values. The adapter's own finer
///   classification (message counts as the measured frame, checkpoints
///   as reference-only) is unchanged and remains available to a later
///   slice.
/// - Message counts and checkpoints stay in separate frames inside
///   `ReferenceValue`, exactly as the collector returns them; the two
///   are never added together.
///
/// Fail-closed throughout, like the earlier slices: an unselected
/// source, a selection without a recorded identity, an identity
/// mismatch, and a scan that produced no readable value all yield a
/// presentation with no reference value.
struct StoreCopilotPipeline {
    static let serviceID = "copilot"
    static let sourceID = "copilot.sessions"

    /// A run's values, kept in reference frames only. The frames are
    /// never merged: the period message counts and the cumulative
    /// checkpoints (whose period start is unknown) stay separate,
    /// exactly as the collector returns them.
    struct ReferenceValue: Equatable {
        /// Message counts per period, when any valid user.message was
        /// read.
        let messageCounts: ProviderPeriodUsageJSON?
        /// Latest observed checkpoint per file, in timestamp order.
        /// These are cumulative values, not period consumption.
        let checkpoints: [StoreCopilotCollector.Checkpoint]
        /// Files whose latest checkpoint values conflict and were
        /// withheld from `checkpoints`.
        let indeterminateCheckpoints: Int
    }

    /// What one run concluded, in display terms. `reference` is the
    /// only payload a caller may read values from, and it is present
    /// only when the state accepted a reference result for this run.
    struct Presentation: Equatable {
        /// Display state per connected source of the Copilot service.
        /// Only `copilot.sessions` is connected in this slice.
        let sourceStates: [String: StoreDisplayState]
        /// Service-level coverage of this run, from the state snapshot.
        let coverage: StoreSourceState.Snapshot.Coverage
        let reference: ReferenceValue?

        /// The connected source's display state.
        var displayState: StoreDisplayState {
            sourceStates[StoreCopilotPipeline.sourceID] ?? .notSelected
        }
    }

    let bookmarks: StoreBookmarkStore
    let scopedDirectory: StoreScopedDirectory
    let state: StoreSourceState
    private let now: () -> Date

    init(bookmarks: StoreBookmarkStore,
         directoryOperations: StoreScopedDirectory.Operations = .live,
         now: @escaping () -> Date = Date.init) {
        self.bookmarks = bookmarks
        self.scopedDirectory = StoreScopedDirectory(bookmarks: bookmarks, operations: directoryOperations)
        self.state = StoreSourceState(sourceIDs: [Self.sourceID])
        self.now = now
    }

    /// Runs one collection under the current saved selection. Throws
    /// only `CancellationError`; every other failure is folded into the
    /// returned presentation's display state.
    func collect() async throws -> Presentation {
        await syncPermission()
        guard let run = await state.begin() else {
            return await presentation(reference: nil)
        }
        let identityAtStart = bookmarks.identity(sourceID: Self.sourceID)
        let outcome: StoreCopilotCollector.Result
        do {
            outcome = try await scopedDirectory.withRoot(sourceID: Self.sourceID) { fd in
                try StoreCopilotCollector.collect(rootFD: fd, now: now())
            }
        } catch let failure as StoreScopedDirectory.Failure {
            await record(failure, run: run)
            return await presentation(reference: nil)
        } catch let failure as StoreBookmarkStore.Failure {
            await record(failure, run: run)
            return await presentation(reference: nil)
        } catch let failure as StoreSafeFileTree.Failure {
            _ = await state.finish(Self.result(treeFailure: failure), source: Self.sourceID, run: run)
            return await presentation(reference: nil)
        } catch is CancellationError {
            // The source stays in the collecting state; the next run's
            // begin() supersedes this one and rejects its late results.
            throw CancellationError()
        } catch {
            _ = await state.finish(.failed, source: Self.sourceID, run: run)
            return await presentation(reference: nil)
        }

        // A selection change during the run replaces the identity
        // record. What was read belongs to the previous selection:
        // discard it, and re-sync the permission, which invalidates
        // this run so the stale outcome can never be finished into the
        // state afterwards.
        guard bookmarks.identity(sourceID: Self.sourceID) == identityAtStart else {
            await syncPermission()
            return await presentation(reference: nil)
        }

        let accepted = await state.finish(Self.result(outcome: outcome, date: now()),
                                          source: Self.sourceID, run: run)
        return await presentation(reference: accepted ? Self.referenceValue(outcome: outcome) : nil)
    }

    // MARK: - Selection and permission

    /// Mirrors the saved selection into the source state. A selection
    /// without a recorded identity syncs as needing reselection and is
    /// never trusted implicitly (connection plan stage 1).
    private func syncPermission() async {
        await state.setEnabled(true)
        switch bookmarks.selectionStatus(sourceID: Self.sourceID) {
        case .unselected:
            await state.setPermission(.unselected, for: Self.sourceID)
        case .saved:
            await state.setPermission(.granted, for: Self.sourceID)
        case .needsReselection:
            await state.setPermission(.reselect, for: Self.sourceID)
        }
    }

    // MARK: - Failure recording

    /// Scoped-open failures. An identity mismatch means the saved
    /// selection no longer names the recorded target, so the permission
    /// itself is stale: it syncs to needing reselection (invalidating
    /// the run), which the adapter renders as `needsReselection`,
    /// matching `StoreDisplayAdapter.state(directoryFailure:)`.
    private func record(_ failure: StoreScopedDirectory.Failure, run: StoreSourceState.Run) async {
        switch failure {
        case .changed:
            await state.setPermission(.reselect, for: Self.sourceID)
        case .invalidURL, .invalidDirectory:
            _ = await state.finish(.invalidTarget, source: Self.sourceID, run: run)
        case .openFailed:
            _ = await state.finish(.failed, source: Self.sourceID, run: run)
        }
    }

    /// Bookmark failures, mirroring
    /// `StoreDisplayAdapter.state(bookmarkFailure:)` through the
    /// permission axis: missing is unselected, and an unresolvable
    /// bookmark or a denied access start needs reselection.
    private func record(_ failure: StoreBookmarkStore.Failure, run: StoreSourceState.Run) async {
        switch failure {
        case .missing:
            await state.setPermission(.unselected, for: Self.sourceID)
        case .invalid, .accessDenied:
            await state.setPermission(.reselect, for: Self.sourceID)
        }
    }

    // MARK: - Outcome mapping

    /// Every value-producing outcome is recorded as a reference result
    /// in this slice, so the state can never present or accumulate a
    /// Copilot value as a confirmed one. A scan whose only values were
    /// checkpoints with conflicting latest values produced nothing
    /// readable: that is unparseable, matching
    /// `StoreDisplayAdapter.copilotCheckpoints`, not an absence of
    /// data.
    static func result(outcome: StoreCopilotCollector.Result, date: Date) -> StoreSourceState.Result {
        switch outcome.state {
        case .complete, .partial:
            guard outcome.messageCounts != nil || !outcome.checkpoints.isEmpty else {
                return .unparseable
            }
            return .reference(count: headlineCount(outcome), date: date)
        case .notDetected:
            return .noData
        case .invalid:
            return .unparseable
        case .unselected:
            // Unreachable: the pipeline only runs with a root FD. Kept
            // as a plain failure rather than any value-bearing result.
            return .failed
        }
    }

    static func result(treeFailure: StoreSafeFileTree.Failure) -> StoreSourceState.Result {
        switch treeFailure {
        case .invalidRoot, .invalidEntry: return .invalidTarget
        case .io, .limit, .cancelled: return .failed
        }
    }

    /// The state's headline count for a reference result: the monthly
    /// message count when messages were read, otherwise the latest
    /// checkpoint's cumulative cost. The two frames are never added
    /// together.
    private static func headlineCount(_ outcome: StoreCopilotCollector.Result) -> Int {
        if let counts = outcome.messageCounts { return max(0, counts.monthly ?? 0) }
        guard let latest = outcome.checkpoints.max(by: { $0.timestamp < $1.timestamp }) else { return 0 }
        return max(0, Int(latest.premiumRequestCost.rounded()))
    }

    /// The reference payload for an accepted run, or nil when the run
    /// produced no readable value. Mirrors the conditions of
    /// `result(outcome:)`.
    static func referenceValue(outcome: StoreCopilotCollector.Result) -> ReferenceValue? {
        switch outcome.state {
        case .complete, .partial:
            guard outcome.messageCounts != nil || !outcome.checkpoints.isEmpty else { return nil }
            return ReferenceValue(messageCounts: outcome.messageCounts,
                                  checkpoints: outcome.checkpoints,
                                  indeterminateCheckpoints: outcome.indeterminateCheckpoints)
        case .notDetected, .invalid, .unselected:
            return nil
        }
    }

    // MARK: - Presentation

    /// Builds the presentation from the state snapshot alone, so the
    /// display states and the coverage always agree with each other
    /// and with what the state accepted for this run.
    private func presentation(reference: ReferenceValue?) async -> Presentation {
        let snapshot = await state.snapshot()
        var states: [String: StoreDisplayState] = [:]
        for (id, source) in snapshot.sources {
            states[id] = StoreDisplayAdapter.state(for: source)
        }
        return Presentation(sourceStates: states, coverage: snapshot.coverage,
                            reference: reference)
    }
}
