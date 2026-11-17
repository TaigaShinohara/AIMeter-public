import Foundation
import AIMeterCore

/// The Claude vertical slice of the Store connection plan
/// (docs/STORE_CONNECTION_DESIGN.md, connection plan stage 6, first
/// service after Codex). The flow mirrors `StoreCodexPipeline`: saved
/// selection → identity record → two-stage verified scoped open →
/// FD-scoped collection → source state → display state.
///
/// Two deliberate differences from the Codex slice:
///
/// - Only the `claude.logs` directory selection is connected. The
///   `claude.settings` file selection is not read in this slice (the
///   collector is always called with a nil settings FD), so the source
///   state tracks `claude.logs` alone; the settings source joins the
///   state when its own slice connects it. A projects total can still
///   appear in this slice when the settings JSON lives inside the
///   selected logs directory itself, which the collector already reads
///   as part of the logs scope.
/// - Every value a run produces is reference-classified. The design
///   document fixes the projects totals as reference values (no known
///   period, never merged into the period totals), and this slice
///   extends that treatment to the log period totals as well: the
///   presentation carries them only inside `ReferenceValue`, never as a
///   `LocalUsageData`, so no caller can apply them to the app's
///   confirmed display or persist them as measured values. The
///   collector's own finer classification (log totals as measured,
///   projects as reference) is unchanged and remains available to a
///   later slice.
///
/// Fail-closed throughout, like the Codex slice: an unselected source, a
/// selection without a recorded identity, an identity mismatch, and a
/// scan that produced no value all yield a presentation with no
/// reference value.
struct StoreClaudePipeline {
    static let serviceID = "claude"
    static let sourceID = "claude.logs"

    /// A run's values, kept in reference frames only. The two frames are
    /// never merged: the undated projects total and the log period
    /// totals stay separate, exactly as the collector returns them.
    struct ReferenceValue: Equatable {
        /// Undated project totals (tokens and cost) from settings data,
        /// when the run produced them.
        let projects: StoreClaudeCollector.Estimate?
        /// Log period totals, reference-classified in this slice.
        let periodUsage: ProviderPeriodUsageJSON?
        /// Cost aggregated from the logs, when any log record was read.
        let logCostUSD: Double?
    }

    /// What one run concluded, in display terms. `reference` is the only
    /// payload a caller may read values from, and it is present only
    /// when the state accepted a reference result for this run.
    struct Presentation: Equatable {
        /// Display state per connected source of the Claude service.
        /// Only `claude.logs` is connected in this slice.
        let sourceStates: [String: StoreDisplayState]
        /// Service-level coverage of this run, from the state snapshot.
        let coverage: StoreSourceState.Snapshot.Coverage
        let reference: ReferenceValue?

        /// The connected source's display state.
        var displayState: StoreDisplayState {
            sourceStates[StoreClaudePipeline.sourceID] ?? .notSelected
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

    /// Runs one collection under the current saved selection. Throws only
    /// `CancellationError`; every other failure is folded into the
    /// returned presentation's display state.
    func collect() async throws -> Presentation {
        await syncPermission()
        guard let run = await state.begin() else {
            return await presentation(reference: nil)
        }
        let identityAtStart = bookmarks.identity(sourceID: Self.sourceID)
        let outcome: StoreClaudeCollector.Result
        do {
            outcome = try await scopedDirectory.withRoot(sourceID: Self.sourceID) { fd in
                try StoreClaudeCollector.collect(logsFD: fd, settingsFD: nil, now: now())
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

        // A selection change during the run replaces the identity record.
        // What was read belongs to the previous selection: discard it, and
        // re-sync the permission, which invalidates this run so the stale
        // outcome can never be finished into the state afterwards.
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

    /// Bookmark failures, mirroring `StoreDisplayAdapter.state(bookmarkFailure:)`
    /// through the permission axis: missing is unselected, and an
    /// unresolvable bookmark or a denied access start needs reselection.
    private func record(_ failure: StoreBookmarkStore.Failure, run: StoreSourceState.Run) async {
        switch failure {
        case .missing:
            await state.setPermission(.unselected, for: Self.sourceID)
        case .invalid, .accessDenied:
            await state.setPermission(.reselect, for: Self.sourceID)
        }
    }

    // MARK: - Outcome mapping

    /// Every value-producing outcome is recorded as a reference result in
    /// this slice, so the state can never present or accumulate a Claude
    /// value as a confirmed one. A scan whose records could not be
    /// interpreted at all is unparseable and yields no value, even when a
    /// projects total was readable: the target as a whole did not parse.
    static func result(outcome: StoreClaudeCollector.Result, date: Date) -> StoreSourceState.Result {
        switch outcome.logs {
        case .complete, .partial:
            return .reference(count: headlineCount(outcome), date: date)
        case .notDetected:
            if outcome.projects == .complete, let projects = outcome.undatedProjects {
                return .reference(count: projects.tokens, date: date)
            }
            return .noData
        case .invalid:
            return .unparseable
        case .unselected:
            // Unreachable: the pipeline only runs with a logs FD. Kept as
            // a plain failure rather than any value-bearing result.
            return .failed
        }
    }

    static func result(treeFailure: StoreSafeFileTree.Failure) -> StoreSourceState.Result {
        switch treeFailure {
        case .invalidRoot, .invalidEntry: return .invalidTarget
        case .io, .limit, .cancelled: return .failed
        }
    }

    /// The state's headline count for a reference result: the undated
    /// projects total when one exists, otherwise the logs' monthly
    /// total. The two are never added together.
    private static func headlineCount(_ outcome: StoreClaudeCollector.Result) -> Int {
        max(0, outcome.undatedProjects?.tokens ?? outcome.used?.monthly ?? 0)
    }

    /// The reference payload for an accepted run, or nil when the run
    /// produced no value. Mirrors the conditions of `result(outcome:)`.
    static func referenceValue(outcome: StoreClaudeCollector.Result) -> ReferenceValue? {
        switch outcome.logs {
        case .complete, .partial:
            return ReferenceValue(projects: outcome.undatedProjects,
                                  periodUsage: outcome.used,
                                  logCostUSD: outcome.logCost)
        case .notDetected:
            guard outcome.projects == .complete, let projects = outcome.undatedProjects else { return nil }
            return ReferenceValue(projects: projects, periodUsage: nil, logCostUSD: nil)
        case .invalid, .unselected:
            return nil
        }
    }

    // MARK: - Presentation

    /// Builds the presentation from the state snapshot alone, so the
    /// display states and the coverage always agree with each other and
    /// with what the state accepted for this run.
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
