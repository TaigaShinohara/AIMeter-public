import Foundation
import AIMeterCore

/// The Gemini vertical slice of the Store connection plan
/// (docs/STORE_CONNECTION_DESIGN.md, connection plan stage 6, fourth
/// service after Codex, Claude, and Copilot). The flow mirrors
/// `StoreCodexPipeline`: saved selection → identity record →
/// two-stage verified scoped open → FD-scoped collection → source
/// state → display state.
///
/// Two deliberate classification choices:
///
/// - Only the `gemini.chats` directory selection is connected. The
///   collector is always called with a nil brain FD, and the pipeline
///   reads only the collector's separated chats totals
///   (`chatsUsed` / `chatsCost`), never the combined totals, so a
///   brain value cannot reach the measured frame even if a future
///   caller passes both FDs. The separation holds by construction:
///   the two inputs are disjoint file sets (brain reads
///   `transcript*.jsonl`; chats reads `.json` files under a `chats`
///   path component), the aggregation accumulators are per-input,
///   and the chats parser has no estimate path — a message counts
///   only when its full token breakdown is present.
/// - The `gemini.brain` input is not connected in this slice. Its
///   records fall back to a text-length estimate when they carry no
///   token values, and the design document excludes that estimate
///   from the first Store release, so brain values are presented in
///   no frame — neither measured nor reference. The source state
///   therefore tracks `gemini.chats` alone; the brain source joins
///   the state only if a later slice connects it.
///
/// Fail-closed throughout, like the earlier slices: an unselected
/// source, a selection without a recorded identity, an identity
/// mismatch, and a scan that produced no usage value all yield a
/// presentation with no data, so no caller can display or store a
/// number for them.
struct StoreGeminiPipeline {
    static let serviceID = "gemini"
    static let sourceID = "gemini.chats"

    /// What one run concluded, in display terms. `data` is the only
    /// payload a caller may apply to the app's display, and it is
    /// present only when the run produced chats usage totals under a
    /// confirmed display state.
    struct Presentation: Equatable {
        /// Display state per connected source of the Gemini service.
        /// Only `gemini.chats` is connected in this slice.
        let sourceStates: [String: StoreDisplayState]
        /// Service-level coverage of this run, from the state snapshot.
        let coverage: StoreSourceState.Snapshot.Coverage
        let data: LocalUsageData?

        /// The connected source's display state.
        var displayState: StoreDisplayState {
            sourceStates[StoreGeminiPipeline.sourceID] ?? .notSelected
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
    /// only `CancellationError`; every other failure is folded into
    /// the returned presentation's display state.
    func collect() async throws -> Presentation {
        await syncPermission()
        guard let run = await state.begin() else {
            return await presentation(data: nil)
        }
        let identityAtStart = bookmarks.identity(sourceID: Self.sourceID)
        let outcome: StoreGeminiCollector.Result
        do {
            outcome = try await scopedDirectory.withRoot(sourceID: Self.sourceID) { fd in
                try StoreGeminiCollector.collect(brainFD: nil, chatsFD: fd, now: now())
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

        // A selection change during the run replaces the identity
        // record. What was read belongs to the previous selection:
        // discard it, and re-sync the permission, which invalidates
        // this run so the stale outcome can never be finished into the
        // state afterwards.
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

    /// The state's count carries this source's headline measured
    /// value: the monthly chats used-token total the run produced.
    /// Only the chats input's state decides the result; the brain
    /// input is unselected by construction in this slice and its
    /// separated totals are never read here.
    static func result(outcome: StoreGeminiCollector.Result, date: Date) -> StoreSourceState.Result {
        switch outcome.chats {
        case .complete:
            return .success(count: monthlyTokens(outcome), date: date)
        case .partial:
            return .partial(count: monthlyTokens(outcome), date: date)
        case .notDetected:
            return .noData
        case .invalid:
            return .unparseable
        case .unselected:
            // Unreachable: the pipeline only runs with a chats FD.
            // Kept as a plain failure rather than any value-bearing
            // result.
            return .failed
        }
    }

    static func result(treeFailure: StoreSafeFileTree.Failure) -> StoreSourceState.Result {
        switch treeFailure {
        case .invalidRoot, .invalidEntry: return .invalidTarget
        case .io, .limit, .cancelled: return .failed
        }
    }

    private static func monthlyTokens(_ outcome: StoreGeminiCollector.Result) -> Int {
        max(0, outcome.chatsUsed.monthly ?? 0)
    }

    /// Only outcomes that carry chats usage totals may reach the
    /// app's display. The data is built from the separated chats
    /// totals alone, so no brain record — measured or estimated —
    /// can be included in what is displayed or stored.
    private static func displayableData(outcome: StoreGeminiCollector.Result) -> LocalUsageData? {
        switch outcome.chats {
        case .complete, .partial:
            return LocalUsageData(geminiUsedTokens: outcome.chatsUsed.monthly,
                                  geminiCostUSD: outcome.chatsCost,
                                  geminiUsedByPeriod: outcome.chatsUsed)
        case .notDetected, .invalid, .unselected:
            return nil
        }
    }

    // MARK: - Presentation

    /// Builds the presentation from the state snapshot alone, so the
    /// display states and the coverage always agree with each other
    /// and with what the state accepted for this run.
    private func presentation(data: LocalUsageData?) async -> Presentation {
        let snapshot = await state.snapshot()
        var states: [String: StoreDisplayState] = [:]
        for (id, source) in snapshot.sources {
            states[id] = StoreDisplayAdapter.state(for: source)
        }
        return Presentation(sourceStates: states, coverage: snapshot.coverage,
                            data: data)
    }
}
