import Foundation

/// The single display-state vocabulary shared by the Store app body and the
/// widget (docs/STORE_CONNECTION_DESIGN.md, 「提案する表示状態」). UI code
/// switches on this state alone; collector result types never reach it.
///
/// The state carries no value by itself. `valueTreatment` states whether a
/// value may accompany the state and in which frame, so a state that must
/// not show a number cannot acquire one by accident. In particular, the
/// only state whose zero is a measured zero is `measuredComplete`: an
/// empty target, an unparseable target, and a wrong target never reach it.
enum StoreDisplayState: Equatable {
    /// 未選択: the input has not been selected.
    case notSelected
    /// 未取得: access is granted, but nothing has been collected under the
    /// current permission set yet.
    case notCollected
    /// 取得中: a collection is in flight. A previous success may be shown
    /// only when explicitly marked as an old value.
    case collecting
    /// 実測（完全）: identity verified, and the scan and parse completed.
    /// A zero count in this state is a measured zero.
    case measuredComplete
    /// 実測（部分）: values were aggregated while some inputs or records
    /// were missing. What is missing must be named alongside the values.
    case measuredPartial
    /// 推定を含む: measured and estimated values are mixed, or the values
    /// are estimates only. Shown as an approximation (目安), never added
    /// to confirmed values.
    case includesEstimate
    /// 参考値のみ: values that cannot enter the period totals (for example
    /// totals with no known period). Shown in a separate reference frame
    /// with their nature stated.
    case referenceOnly
    /// データなし: identity verified and the scan completed, but the
    /// target held no data. Never shown as zero.
    case noData
    /// 解析不能: the target was opened but its contents could not be
    /// interpreted. No value is shown.
    case unparseable
    /// 対象違いの疑い: identity verification failed, or the target's
    /// structure is not the expected one. No value is shown.
    case suspectedWrongTarget
    /// 要再選択: the bookmark is stale, the target moved, or access was
    /// lost. No value is shown.
    case needsReselection
    /// 失敗: any other collection failure. A previous result may be shown
    /// only together with its last-success time.
    case failed

    /// How a value may be presented alongside this state.
    enum ValueTreatment: Equatable {
        /// No value is shown in this state.
        case hidden
        /// Shown as a confirmed value; zero is a measured zero.
        case confirmed
        /// Shown as a confirmed value together with what is missing.
        case confirmedPartial
        /// Shown as an approximation, kept apart from confirmed values.
        case estimate
        /// Shown in the separate reference frame, never in period totals.
        case reference
    }

    var valueTreatment: ValueTreatment {
        switch self {
        case .measuredComplete: return .confirmed
        case .measuredPartial: return .confirmedPartial
        case .includesEstimate: return .estimate
        case .referenceOnly: return .reference
        case .notSelected, .notCollected, .collecting, .noData, .unparseable,
             .suspectedWrongTarget, .needsReselection, .failed:
            return .hidden
        }
    }
}

/// Why a collector result has no display state in the first Store release.
/// The classification is fixed by docs/STORE_CONNECTION_DESIGN.md
/// (「推定値・参考値を返すコレクタの扱い」): these values are not given a
/// display state at all, so no code path can present them as measured
/// values, approximations, or reference values by accident.
enum StoreDisplayExclusion: Equatable {
    /// A proxy metric, not usage (Cursor file counts by modification time).
    case proxyMetric
    /// An estimate whose basis is not established for display (Grok Bot
    /// transcript character estimates; the estimated portion of Gemini
    /// brain logs, which the collector does not separate from measured
    /// records, so the brain input's values are excluded as a whole).
    case unestablishedEstimate
    /// A value whose freshness cannot be established (Grok Bot weekly
    /// quota). It is not shown as a remaining allowance.
    case freshnessUnverified
}

/// The outcome of adapting one collector result: either one of the twelve
/// display states, or an explicit exclusion fixed by the classification.
enum StoreDisplayAdaptation: Equatable {
    case state(StoreDisplayState)
    case excluded(StoreDisplayExclusion)
}

/// Pure conversions from selection state, collection state, collector
/// results, and pipeline failures to `StoreDisplayState`. Nothing here
/// reads storage, starts access, or touches the UI; connecting the states
/// to views is a later stage of the connection plan.
enum StoreDisplayAdapter {
    // MARK: - Selection and collection state

    /// Converts one source's permission and collection state. Permission
    /// dominates: an unselected, revoked, or reselection-needed source
    /// never reports a collection outcome.
    static func state(permission: StoreSourceState.Permission,
                      collection: StoreSourceState.Collection) -> StoreDisplayState {
        switch permission {
        case .unselected, .revoked: return .notSelected
        case .reselect: return .needsReselection
        case .granted: break
        }
        switch collection {
        case .notRun: return .notCollected
        case .collecting: return .collecting
        case .success: return .measuredComplete
        case .partial: return .measuredPartial
        case .estimate: return .includesEstimate
        case .reference: return .referenceOnly
        case .noData: return .noData
        case .unparseable: return .unparseable
        case .invalidTarget: return .suspectedWrongTarget
        case .failed: return .failed
        }
    }

    static func state(for source: StoreSourceState.Source) -> StoreDisplayState {
        state(permission: source.permission, collection: source.collection)
    }

    /// Converts the saved-selection inspection. A selection with a recorded
    /// identity is granted but not yet collected under it; a selection
    /// without one, a stale bookmark, or an unresolvable bookmark is
    /// reported as needing reselection and is never trusted implicitly.
    static func state(selection: StoreBookmarkStore.SelectionStatus) -> StoreDisplayState {
        switch selection {
        case .unselected: return .notSelected
        case .saved: return .notCollected
        case .needsReselection: return .needsReselection
        }
    }

    // MARK: - Pipeline failures

    /// Bookmark failures: a missing selection is simply unselected; an
    /// unresolvable bookmark or a denied access start asks for reselection
    /// (docs/APP_STORE_DESIGN.md).
    static func state(bookmarkFailure: StoreBookmarkStore.Failure) -> StoreDisplayState {
        switch bookmarkFailure {
        case .missing: return .notSelected
        case .invalid, .accessDenied: return .needsReselection
        }
    }

    /// Scoped-open failures: an identity mismatch (`changed`) asks for
    /// reselection; a target that is not the selected kind of entry is a
    /// suspected wrong target; the rest are plain failures.
    static func state(directoryFailure: StoreScopedDirectory.Failure) -> StoreDisplayState {
        switch directoryFailure {
        case .changed: return .needsReselection
        case .invalidURL, .invalidDirectory: return .suspectedWrongTarget
        case .openFailed: return .failed
        }
    }

    static func state(fileFailure: StoreScopedFile.Failure) -> StoreDisplayState {
        switch fileFailure {
        case .changed: return .needsReselection
        case .invalidURL, .invalidFile: return .suspectedWrongTarget
        case .openFailed: return .failed
        }
    }

    /// Tree-read failures: an unexpected root or entry means the opened
    /// target is not the structure the collector expects; I/O, limit, and
    /// cancellation outcomes produce no result and are plain failures.
    static func state(treeFailure: StoreSafeFileTree.Failure) -> StoreDisplayState {
        switch treeFailure {
        case .invalidRoot, .invalidEntry: return .suspectedWrongTarget
        case .io, .limit, .cancelled: return .failed
        }
    }

    // MARK: - Codex

    /// `quotaOnly` is a completed scan whose accepted records carried quota
    /// but no usage totals; the outcome is measured, and the payload keeps
    /// usage absent rather than presenting an invented zero.
    static func codex(_ outcome: LocalUsageCollector.StoreCodexOutcome) -> StoreDisplayState {
        switch outcome {
        case .notDetected: return .noData
        case .invalidData: return .unparseable
        case .quotaOnly(_, partial: let partial): return partial ? .measuredPartial : .measuredComplete
        case .partial: return .measuredPartial
        case .complete: return .measuredComplete
        }
    }

    // MARK: - Gemini

    /// Brain logs: token-bearing records are measured. When any included
    /// record used the character-length estimate, the aggregated values
    /// cannot be separated into measured and estimated parts, so the
    /// classification excludes the brain input's values as a whole rather
    /// than presenting them as measured or as an approximation.
    ///
    /// The collector's period totals merge the brain and chats inputs, so
    /// these conversions classify each input's state only; per-input values
    /// are a later stage's concern.
    static func geminiBrain(_ result: StoreGeminiCollector.Result) -> StoreDisplayAdaptation {
        switch result.brain {
        case .unselected: return .state(.notSelected)
        case .notDetected: return .state(.noData)
        case .invalid: return .state(.unparseable)
        case .partial, .complete:
            if result.brainUsesEstimate { return .excluded(.unestablishedEstimate) }
            return .state(result.brain == .complete ? .measuredComplete : .measuredPartial)
        }
    }

    static func geminiChats(_ result: StoreGeminiCollector.Result) -> StoreDisplayState {
        switch result.chats {
        case .unselected: return .notSelected
        case .notDetected: return .noData
        case .invalid: return .unparseable
        case .partial: return .measuredPartial
        case .complete: return .measuredComplete
        }
    }

    // MARK: - Claude

    static func claudeLogs(_ result: StoreClaudeCollector.Result) -> StoreDisplayState {
        switch result.logs {
        case .unselected: return .notSelected
        case .notDetected: return .noData
        case .invalid: return .unparseable
        case .partial: return .measuredPartial
        case .complete: return .measuredComplete
        }
    }

    /// Project totals have no known period, so a complete projects result
    /// is reference-only and never enters the period totals. An incomplete
    /// result is withheld entirely — the collector returns no totals for
    /// it — and an unavailable one means no settings data contributed a
    /// projects frame at all.
    static func claudeProjects(_ result: StoreClaudeCollector.Result) -> StoreDisplayState {
        switch result.projects {
        case .unavailable: return .notSelected
        case .notDetected: return .noData
        case .incomplete: return .unparseable
        case .complete: return .referenceOnly
        }
    }

    // MARK: - Copilot

    /// Message counts are the measured frame. The collector's state mixes
    /// messages and checkpoints, so a completed scan without any valid
    /// message is data-absent for this frame, not a zero.
    static func copilotMessages(_ result: StoreCopilotCollector.Result) -> StoreDisplayState {
        switch result.state {
        case .unselected: return .notSelected
        case .invalid: return .unparseable
        case .notDetected: return .noData
        case .complete, .partial:
            guard result.messageCounts != nil else { return .noData }
            return result.state == .complete ? .measuredComplete : .measuredPartial
        }
    }

    /// Checkpoints are cumulative values with no proven period start, so
    /// they are reference-only. A checkpoint whose file's latest values
    /// conflict is withheld by the collector; when nothing else remains,
    /// that conflict is unparseable rather than an absence of data.
    static func copilotCheckpoints(_ result: StoreCopilotCollector.Result) -> StoreDisplayState {
        if !result.checkpoints.isEmpty { return .referenceOnly }
        if result.indeterminateCheckpoints > 0 { return .unparseable }
        switch result.state {
        case .unselected: return .notSelected
        case .invalid: return .unparseable
        case .notDetected, .complete, .partial: return .noData
        }
    }

    // MARK: - Grok Bot

    /// The weekly quota's freshness is unverified, so a collected quota is
    /// excluded from the first release instead of being shown as a
    /// remaining allowance. Contradictory caches leave no quota value;
    /// that conflict is unparseable, not an absence of data.
    static func grokQuota(_ result: StoreGrokCollector.Result) -> StoreDisplayAdaptation {
        if result.quota != nil { return .excluded(.freshnessUnverified) }
        switch result.quotaState {
        case .unselected: return .state(.notSelected)
        case .notDetected: return .state(.noData)
        case .invalid: return .state(.unparseable)
        case .partial, .complete: return .state(.unparseable)
        }
    }

    /// Transcript values are character-length estimates. They are excluded
    /// rather than shown as approximations: their basis is not established.
    static func grokTranscript(_ result: StoreGrokCollector.Result) -> StoreDisplayAdaptation {
        if result.estimatedUsage != nil { return .excluded(.unestablishedEstimate) }
        switch result.transcriptState {
        case .unselected: return .state(.notSelected)
        case .notDetected: return .state(.noData)
        case .invalid: return .state(.unparseable)
        case .partial, .complete: return .state(.noData)
        }
    }

    // MARK: - Cursor

    /// File counts by modification time are a proxy metric, not usage, so
    /// a collected count is excluded from the first release instead of
    /// being shown as a measured value. A target without the recognized
    /// control structure is a suspected wrong target.
    static func cursor(_ result: StoreCursorCollector.Result) -> StoreDisplayAdaptation {
        if result.fileCounts != nil { return .excluded(.proxyMetric) }
        switch result.state {
        case .unselected: return .state(.notSelected)
        case .notRecognized: return .state(.suspectedWrongTarget)
        case .empty: return .state(.noData)
        case .invalid: return .state(.unparseable)
        case .partial, .complete: return .state(.noData)
        }
    }
}
