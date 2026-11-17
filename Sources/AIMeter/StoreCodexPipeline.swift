import Foundation
import AIMeterCore

/// The first connected Store collection path (docs/STORE_CONNECTION_DESIGN.md,
/// connection plan stage 4): Codex only, end to end. A run flows from the
/// saved selection through the identity-verified scoped open, the FD-based
/// Codex collector, and the source state, and comes back as display states
/// plus — only when a confirmed usage value exists — the collected data.
///
/// Fail-closed throughout: an unselected source, a selection without a
/// recorded identity, an identity mismatch, and a scan that produced no
/// usage value all yield a presentation with no data, so no caller can
/// display or store a number for them. Other services are not connected
/// here; their collectors are never invoked.
struct StoreCodexPipeline {
    static let serviceID = "openai"
    static let sourceID = "openai.sessions"

    /// What one run concluded, in display terms. `data` is the only payload
    /// a caller may apply to the app's display, and it is present only when
    /// the run produced usage totals under a confirmed display state.
    struct Presentation: Equatable {
        /// Display state per catalog source of the Codex service.
        let sourceStates: [String: StoreDisplayState]
        /// Service-level coverage of this run, from the state snapshot.
        /// Coverage counts sources that produced a value; it never promotes
        /// one source's value into another source's state.
        let coverage: StoreSourceState.Snapshot.Coverage
        /// Sources that produced no value while another source of the
        /// service did — the missing targets to name alongside a partial
        /// result. Empty unless the coverage is partial.
        let missingSources: [StoreSourceCatalog.Source]
        let data: LocalUsageData?

        /// The primary (only) Codex source's display state.
        var displayState: StoreDisplayState {
            sourceStates[StoreCodexPipeline.sourceID] ?? .notSelected
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
        let sourceIDs = StoreSourceCatalog.service(id: Self.serviceID)?.sources.map(\.id) ?? [Self.sourceID]
        self.state = StoreSourceState(sourceIDs: Set(sourceIDs))
        self.now = now
    }

    /// Runs one collection under the current saved selection. Throws only
    /// `CancellationError`; every other failure is folded into the returned
    /// presentation's display state.
    func collect() async throws -> Presentation {
        await syncPermission()
        guard let run = await state.begin() else {
            return await presentation(data: nil)
        }
        let identityAtStart = bookmarks.identity(sourceID: Self.sourceID)
        let outcome: LocalUsageCollector.StoreCodexOutcome
        do {
            outcome = try await scopedDirectory.withRoot(sourceID: Self.sourceID) { fd in
                try LocalUsageCollector.collectStoreCodex(rootFD: fd, now: now())
            }
        } catch let failure as StoreScopedDirectory.Failure {
            await record(failure, run: run)
            return await presentation(data: nil)
        } catch let failure as StoreBookmarkStore.Failure {
            await record(failure, run: run)
            return await presentation(data: nil)
        } catch let failure as StoreSafeFileTree.Failure {
            _ = await state.finish(Self.result(treeFailure: failure), source: Self.sourceID, run: run)
            return await presentation(data: nil)
        } catch is CancellationError {
            // The source stays in the collecting state; the next run's
            // begin() supersedes this one and rejects its late results.
            throw CancellationError()
        } catch {
            _ = await state.finish(.failed, source: Self.sourceID, run: run)
            return await presentation(data: nil)
        }

        // A selection change during the run replaces the identity record.
        // What was read belongs to the previous selection: discard it, and
        // re-sync the permission, which invalidates this run so the stale
        // outcome can never be finished into the state afterwards.
        guard bookmarks.identity(sourceID: Self.sourceID) == identityAtStart else {
            await syncPermission()
            return await presentation(data: nil)
        }

        let accepted = await state.finish(Self.result(outcome: outcome, date: now()),
                                          source: Self.sourceID, run: run)
        return await presentation(data: accepted ? Self.displayableData(outcome: outcome) : nil)
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

    /// Scoped-open failures. An identity mismatch means the saved selection
    /// no longer names the recorded target, so the permission itself is
    /// stale: it syncs to needing reselection (invalidating the run), which
    /// the adapter renders as `needsReselection`, matching
    /// `StoreDisplayAdapter.state(directoryFailure:)`.
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

    /// The state's count carries this source's headline measured value: the
    /// monthly used-token total the run produced. A quota-only run produced
    /// no usage total, so it records zero; the presentation never surfaces
    /// the state's count as a usage value, and the quota payload itself is
    /// withheld from `data` below, so usage stays absent rather than zero.
    static func result(outcome: LocalUsageCollector.StoreCodexOutcome, date: Date) -> StoreSourceState.Result {
        switch outcome {
        case let .complete(data):
            return .success(count: monthlyTokens(data), date: date)
        case let .partial(data):
            return .partial(count: monthlyTokens(data), date: date)
        case let .quotaOnly(_, partial):
            return partial ? .partial(count: 0, date: date) : .success(count: 0, date: date)
        case .notDetected:
            return .noData
        case .invalidData:
            return .unparseable
        }
    }

    static func result(treeFailure: StoreSafeFileTree.Failure) -> StoreSourceState.Result {
        switch treeFailure {
        case .invalidRoot, .invalidEntry: return .invalidTarget
        case .io, .limit, .cancelled: return .failed
        }
    }

    private static func monthlyTokens(_ data: LocalUsageData) -> Int {
        max(0, data.openaiUsedByPeriod?.monthly ?? data.openaiUsedTokens ?? 0)
    }

    /// Only outcomes that carry usage totals may reach the app's display.
    /// A quota-only payload holds a measured quota but no usage totals;
    /// applying it would render the absent usage as zero, so it is withheld
    /// in this stage and the run is reported through its display state.
    private static func displayableData(outcome: LocalUsageCollector.StoreCodexOutcome) -> LocalUsageData? {
        switch outcome {
        case let .complete(data), let .partial(data): return data
        case .quotaOnly, .notDetected, .invalidData: return nil
        }
    }

    // MARK: - Presentation

    /// Builds the presentation from the state snapshot alone, so the
    /// display states, the coverage, and the missing sources always agree
    /// with each other and with what the state accepted for this run.
    private func presentation(data: LocalUsageData?) async -> Presentation {
        let snapshot = await state.snapshot()
        var states: [String: StoreDisplayState] = [:]
        for (id, source) in snapshot.sources {
            states[id] = StoreDisplayAdapter.state(for: source)
        }
        var missing: [StoreSourceCatalog.Source] = []
        if snapshot.coverage == .partial,
           let service = StoreSourceCatalog.service(id: Self.serviceID) {
            missing = service.sources.filter {
                snapshot.sources[$0.id]?.collection.producesValue == false
            }
        }
        return Presentation(sourceStates: states, coverage: snapshot.coverage,
                            missingSources: missing, data: data)
    }
}
