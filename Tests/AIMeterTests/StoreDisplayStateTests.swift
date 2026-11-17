import XCTest
import Foundation
import AIMeterCore
@testable import AIMeter

/// Correspondence table between collector outcomes, selection/collection
/// state, and failures on one side, and the twelve display states of
/// docs/STORE_CONNECTION_DESIGN.md on the other. Fixtures are synthetic
/// result values constructed in place; no collector runs here.
final class StoreDisplayStateTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func periods(_ value: Int) -> ProviderPeriodUsageJSON {
        ProviderPeriodUsageJSON(twoHours: value, fiveHours: value, daily: value, weekly: value, monthly: value)
    }

    private var zeroPeriods: ProviderPeriodUsageJSON { periods(0) }

    // MARK: - Value treatment

    func testValueTreatmentHidesValuesOutsideValueStates() {
        let hidden: [StoreDisplayState] = [.notSelected, .notCollected, .collecting, .noData,
                                           .unparseable, .suspectedWrongTarget, .needsReselection, .failed]
        for state in hidden { XCTAssertEqual(state.valueTreatment, .hidden, "\(state)") }
        XCTAssertEqual(StoreDisplayState.measuredComplete.valueTreatment, .confirmed)
        XCTAssertEqual(StoreDisplayState.measuredPartial.valueTreatment, .confirmedPartial)
        XCTAssertEqual(StoreDisplayState.includesEstimate.valueTreatment, .estimate)
        XCTAssertEqual(StoreDisplayState.referenceOnly.valueTreatment, .reference)
    }

    func testAllTwelveStatesAreReachableAndDistinct() {
        let success = StoreSourceState.Success(count: 1, date: date)
        let reached: [StoreDisplayState] = [
            StoreDisplayAdapter.state(permission: .unselected, collection: .notRun),
            StoreDisplayAdapter.state(permission: .granted, collection: .notRun),
            StoreDisplayAdapter.state(permission: .granted, collection: .collecting),
            StoreDisplayAdapter.state(permission: .granted, collection: .success(success)),
            StoreDisplayAdapter.state(permission: .granted, collection: .partial(success)),
            StoreDisplayAdapter.state(permission: .granted, collection: .estimate(success)),
            StoreDisplayAdapter.state(permission: .granted, collection: .reference(success)),
            StoreDisplayAdapter.state(permission: .granted, collection: .noData),
            StoreDisplayAdapter.state(permission: .granted, collection: .unparseable),
            StoreDisplayAdapter.state(permission: .granted, collection: .invalidTarget),
            StoreDisplayAdapter.state(permission: .reselect, collection: .notRun),
            StoreDisplayAdapter.state(permission: .granted, collection: .failed)
        ]
        XCTAssertEqual(reached, [.notSelected, .notCollected, .collecting, .measuredComplete,
                                 .measuredPartial, .includesEstimate, .referenceOnly, .noData,
                                 .unparseable, .suspectedWrongTarget, .needsReselection, .failed])
        XCTAssertEqual(Set(reached.map { "\($0)" }).count, 12)
    }

    // MARK: - Selection and collection state

    func testPermissionDominatesCollection() {
        let success = StoreSourceState.Success(count: 1, date: date)
        let collections: [StoreSourceState.Collection] = [
            .notRun, .collecting, .success(success), .partial(success), .estimate(success),
            .reference(success), .noData, .unparseable, .invalidTarget, .failed
        ]
        for collection in collections {
            XCTAssertEqual(StoreDisplayAdapter.state(permission: .unselected, collection: collection), .notSelected)
            XCTAssertEqual(StoreDisplayAdapter.state(permission: .revoked, collection: collection), .notSelected)
            XCTAssertEqual(StoreDisplayAdapter.state(permission: .reselect, collection: collection), .needsReselection)
        }
    }

    func testGrantedCollectionStatesConvertOneToOne() {
        let success = StoreSourceState.Success(count: 0, date: date)
        let table: [(StoreSourceState.Collection, StoreDisplayState)] = [
            (.notRun, .notCollected),
            (.collecting, .collecting),
            (.success(success), .measuredComplete),
            (.partial(success), .measuredPartial),
            (.estimate(success), .includesEstimate),
            (.reference(success), .referenceOnly),
            (.noData, .noData),
            (.unparseable, .unparseable),
            (.invalidTarget, .suspectedWrongTarget),
            (.failed, .failed)
        ]
        for (collection, expected) in table {
            XCTAssertEqual(StoreDisplayAdapter.state(permission: .granted, collection: collection), expected, "\(collection)")
        }
    }

    func testSelectionStatusConversion() {
        XCTAssertEqual(StoreDisplayAdapter.state(selection: .unselected), .notSelected)
        XCTAssertEqual(StoreDisplayAdapter.state(selection: .saved(URL(fileURLWithPath: "/tmp/synthetic"))), .notCollected)
        XCTAssertEqual(StoreDisplayAdapter.state(selection: .needsReselection), .needsReselection)
    }

    // MARK: - Pipeline failures

    func testFailureConversions() {
        XCTAssertEqual(StoreDisplayAdapter.state(bookmarkFailure: .missing), .notSelected)
        XCTAssertEqual(StoreDisplayAdapter.state(bookmarkFailure: .invalid), .needsReselection)
        XCTAssertEqual(StoreDisplayAdapter.state(bookmarkFailure: .accessDenied), .needsReselection)

        XCTAssertEqual(StoreDisplayAdapter.state(directoryFailure: .changed), .needsReselection)
        XCTAssertEqual(StoreDisplayAdapter.state(directoryFailure: .invalidURL), .suspectedWrongTarget)
        XCTAssertEqual(StoreDisplayAdapter.state(directoryFailure: .invalidDirectory), .suspectedWrongTarget)
        XCTAssertEqual(StoreDisplayAdapter.state(directoryFailure: .openFailed), .failed)

        XCTAssertEqual(StoreDisplayAdapter.state(fileFailure: .changed), .needsReselection)
        XCTAssertEqual(StoreDisplayAdapter.state(fileFailure: .invalidURL), .suspectedWrongTarget)
        XCTAssertEqual(StoreDisplayAdapter.state(fileFailure: .invalidFile), .suspectedWrongTarget)
        XCTAssertEqual(StoreDisplayAdapter.state(fileFailure: .openFailed), .failed)

        XCTAssertEqual(StoreDisplayAdapter.state(treeFailure: .invalidRoot), .suspectedWrongTarget)
        XCTAssertEqual(StoreDisplayAdapter.state(treeFailure: .invalidEntry), .suspectedWrongTarget)
        XCTAssertEqual(StoreDisplayAdapter.state(treeFailure: .io), .failed)
        XCTAssertEqual(StoreDisplayAdapter.state(treeFailure: .limit), .failed)
        XCTAssertEqual(StoreDisplayAdapter.state(treeFailure: .cancelled), .failed)
    }

    // MARK: - Codex

    func testCodexOutcomeConversion() {
        let data = LocalUsageData(openaiUsedTokens: 42, source: "store_selected_sources")
        XCTAssertEqual(StoreDisplayAdapter.codex(.complete(data)), .measuredComplete)
        XCTAssertEqual(StoreDisplayAdapter.codex(.partial(data)), .measuredPartial)
        XCTAssertEqual(StoreDisplayAdapter.codex(.quotaOnly(data, partial: false)), .measuredComplete)
        XCTAssertEqual(StoreDisplayAdapter.codex(.quotaOnly(data, partial: true)), .measuredPartial)
        XCTAssertEqual(StoreDisplayAdapter.codex(.notDetected), .noData)
        XCTAssertEqual(StoreDisplayAdapter.codex(.invalidData), .unparseable)
    }

    // MARK: - Gemini

    private func gemini(brain: StoreGeminiCollector.SourceState,
                        chats: StoreGeminiCollector.SourceState,
                        used: ProviderPeriodUsageJSON? = nil,
                        brainUsesEstimate: Bool = false) -> StoreGeminiCollector.Result {
        StoreGeminiCollector.Result(brain: brain, chats: chats, used: used ?? periods(9),
                                    raw: used ?? periods(9), cost: 0, brainUsesEstimate: brainUsesEstimate)
    }

    func testGeminiBrainConversion() {
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .unselected, chats: .unselected)), .state(.notSelected))
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .notDetected, chats: .unselected)), .state(.noData))
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .invalid, chats: .unselected)), .state(.unparseable))
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .complete, chats: .unselected)), .state(.measuredComplete))
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .partial, chats: .unselected)), .state(.measuredPartial))
    }

    func testGeminiBrainEstimateIsExcludedAsAWhole() {
        // The collector does not separate estimated records from measured
        // ones, so any included estimate excludes the brain input's values
        // instead of presenting them as measured or as an approximation.
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .complete, chats: .unselected, brainUsesEstimate: true)),
                       .excluded(.unestablishedEstimate))
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(gemini(brain: .partial, chats: .unselected, brainUsesEstimate: true)),
                       .excluded(.unestablishedEstimate))
        // The chats input is unaffected by the brain exclusion.
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(gemini(brain: .complete, chats: .complete, brainUsesEstimate: true)),
                       .measuredComplete)
    }

    func testGeminiChatsConversion() {
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(gemini(brain: .unselected, chats: .unselected)), .notSelected)
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(gemini(brain: .unselected, chats: .notDetected)), .noData)
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(gemini(brain: .unselected, chats: .invalid)), .unparseable)
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(gemini(brain: .unselected, chats: .partial)), .measuredPartial)
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(gemini(brain: .unselected, chats: .complete)), .measuredComplete)
    }

    func testGeminiEmptyTargetWithZeroTotalsIsNoDataNotMeasuredZero() {
        // The collector always returns period totals; an empty target reads
        // back as all-zero totals with notDetected states. The adapter keys
        // off the states, so the zeros are never presented as measured.
        let result = gemini(brain: .notDetected, chats: .notDetected, used: zeroPeriods)
        XCTAssertEqual(StoreDisplayAdapter.geminiBrain(result), .state(.noData))
        XCTAssertEqual(StoreDisplayAdapter.geminiChats(result), .noData)
        XCTAssertEqual(StoreDisplayState.noData.valueTreatment, .hidden)
    }

    // MARK: - Claude

    private func claude(logs: StoreClaudeCollector.LogState,
                        projects: StoreClaudeCollector.ProjectsState,
                        used: ProviderPeriodUsageJSON? = nil,
                        undatedProjects: StoreClaudeCollector.Estimate? = nil) -> StoreClaudeCollector.Result {
        StoreClaudeCollector.Result(logs: logs, settings: .absent, used: used, logCost: nil,
                                    plan: nil, projects: projects, undatedProjects: undatedProjects)
    }

    func testClaudeLogsConversion() {
        XCTAssertEqual(StoreDisplayAdapter.claudeLogs(claude(logs: .unselected, projects: .unavailable)), .notSelected)
        XCTAssertEqual(StoreDisplayAdapter.claudeLogs(claude(logs: .notDetected, projects: .unavailable)), .noData)
        XCTAssertEqual(StoreDisplayAdapter.claudeLogs(claude(logs: .invalid, projects: .unavailable)), .unparseable)
        XCTAssertEqual(StoreDisplayAdapter.claudeLogs(claude(logs: .partial, projects: .unavailable, used: periods(3))), .measuredPartial)
        XCTAssertEqual(StoreDisplayAdapter.claudeLogs(claude(logs: .complete, projects: .unavailable, used: periods(3))), .measuredComplete)
    }

    func testClaudeProjectsAreReferenceOnly() {
        let estimate = StoreClaudeCollector.Estimate(tokens: 100, cost: 1.5)
        XCTAssertEqual(StoreDisplayAdapter.claudeProjects(claude(logs: .complete, projects: .complete, undatedProjects: estimate)),
                       .referenceOnly)
        XCTAssertEqual(StoreDisplayState.referenceOnly.valueTreatment, .reference)
        // Incomplete project totals are withheld entirely, never shown.
        XCTAssertEqual(StoreDisplayAdapter.claudeProjects(claude(logs: .complete, projects: .incomplete)), .unparseable)
        XCTAssertEqual(StoreDisplayAdapter.claudeProjects(claude(logs: .complete, projects: .notDetected)), .noData)
        XCTAssertEqual(StoreDisplayAdapter.claudeProjects(claude(logs: .unselected, projects: .unavailable)), .notSelected)
    }

    // MARK: - Copilot

    private func copilot(state: StoreCopilotCollector.State,
                         messageCounts: ProviderPeriodUsageJSON? = nil,
                         checkpoints: [StoreCopilotCollector.Checkpoint] = [],
                         indeterminate: Int = 0) -> StoreCopilotCollector.Result {
        StoreCopilotCollector.Result(state: state, messageCounts: messageCounts,
                                     checkpoints: checkpoints, indeterminateCheckpoints: indeterminate)
    }

    func testCopilotMessagesConversion() {
        XCTAssertEqual(StoreDisplayAdapter.copilotMessages(copilot(state: .unselected)), .notSelected)
        XCTAssertEqual(StoreDisplayAdapter.copilotMessages(copilot(state: .notDetected)), .noData)
        XCTAssertEqual(StoreDisplayAdapter.copilotMessages(copilot(state: .invalid)), .unparseable)
        XCTAssertEqual(StoreDisplayAdapter.copilotMessages(copilot(state: .complete, messageCounts: periods(5))), .measuredComplete)
        XCTAssertEqual(StoreDisplayAdapter.copilotMessages(copilot(state: .partial, messageCounts: periods(5))), .measuredPartial)
        // A scan completed on checkpoints alone found no messages: the
        // messages frame is data-absent, not a measured zero.
        XCTAssertEqual(StoreDisplayAdapter.copilotMessages(copilot(
            state: .complete,
            checkpoints: [.init(timestamp: date, premiumRequestCost: 3)])), .noData)
    }

    func testCopilotCheckpointsAreReferenceOnly() {
        let checkpoint = StoreCopilotCollector.Checkpoint(timestamp: date, premiumRequestCost: 12.5)
        XCTAssertEqual(StoreDisplayAdapter.copilotCheckpoints(copilot(state: .complete, checkpoints: [checkpoint])), .referenceOnly)
        XCTAssertEqual(StoreDisplayAdapter.copilotCheckpoints(copilot(state: .partial, checkpoints: [checkpoint])), .referenceOnly)
        // Conflicting latest values are withheld by the collector; with
        // nothing else remaining, that is unparseable, not no data.
        XCTAssertEqual(StoreDisplayAdapter.copilotCheckpoints(copilot(state: .partial, indeterminate: 1)), .unparseable)
        XCTAssertEqual(StoreDisplayAdapter.copilotCheckpoints(copilot(state: .notDetected)), .noData)
        XCTAssertEqual(StoreDisplayAdapter.copilotCheckpoints(copilot(state: .invalid)), .unparseable)
        XCTAssertEqual(StoreDisplayAdapter.copilotCheckpoints(copilot(state: .unselected)), .notSelected)
    }

    // MARK: - Grok Bot

    private func grok(quotaState: StoreGrokCollector.State,
                      quota: StoreGrokCollector.Quota? = nil,
                      transcriptState: StoreGrokCollector.State,
                      estimatedUsage: ProviderPeriodUsageJSON? = nil) -> StoreGrokCollector.Result {
        StoreGrokCollector.Result(quotaState: quotaState, quota: quota, transcriptState: transcriptState,
                                  estimatedUsage: estimatedUsage, transcriptsMayOverlap: false)
    }

    func testGrokQuotaIsExcludedWhileFreshnessIsUnverified() {
        let quota = StoreGrokCollector.Quota(percent: 40, resetSeconds: 3600, costUSD: nil,
                                             plan: nil, observedAt: date, freshness: .unverified)
        XCTAssertEqual(StoreDisplayAdapter.grokQuota(grok(quotaState: .complete, quota: quota, transcriptState: .unselected)),
                       .excluded(.freshnessUnverified))
        XCTAssertEqual(StoreDisplayAdapter.grokQuota(grok(quotaState: .unselected, transcriptState: .unselected)), .state(.notSelected))
        XCTAssertEqual(StoreDisplayAdapter.grokQuota(grok(quotaState: .notDetected, transcriptState: .unselected)), .state(.noData))
        XCTAssertEqual(StoreDisplayAdapter.grokQuota(grok(quotaState: .invalid, transcriptState: .unselected)), .state(.unparseable))
        // Contradictory caches leave no quota: unparseable, not no data.
        XCTAssertEqual(StoreDisplayAdapter.grokQuota(grok(quotaState: .partial, transcriptState: .unselected)), .state(.unparseable))
    }

    func testGrokTranscriptEstimateIsExcluded() {
        XCTAssertEqual(StoreDisplayAdapter.grokTranscript(grok(quotaState: .unselected, transcriptState: .complete,
                                                               estimatedUsage: periods(7))),
                       .excluded(.unestablishedEstimate))
        XCTAssertEqual(StoreDisplayAdapter.grokTranscript(grok(quotaState: .unselected, transcriptState: .unselected)), .state(.notSelected))
        XCTAssertEqual(StoreDisplayAdapter.grokTranscript(grok(quotaState: .unselected, transcriptState: .notDetected)), .state(.noData))
        XCTAssertEqual(StoreDisplayAdapter.grokTranscript(grok(quotaState: .unselected, transcriptState: .invalid)), .state(.unparseable))
    }

    // MARK: - Cursor

    func testCursorCountsAreExcludedAsProxyMetric() {
        XCTAssertEqual(StoreDisplayAdapter.cursor(StoreCursorCollector.Result(state: .complete, fileCounts: periods(11))),
                       .excluded(.proxyMetric))
        XCTAssertEqual(StoreDisplayAdapter.cursor(StoreCursorCollector.Result(state: .partial, fileCounts: periods(11))),
                       .excluded(.proxyMetric))
        XCTAssertEqual(StoreDisplayAdapter.cursor(StoreCursorCollector.Result(state: .unselected, fileCounts: nil)), .state(.notSelected))
        XCTAssertEqual(StoreDisplayAdapter.cursor(StoreCursorCollector.Result(state: .notRecognized, fileCounts: nil)),
                       .state(.suspectedWrongTarget))
        XCTAssertEqual(StoreDisplayAdapter.cursor(StoreCursorCollector.Result(state: .empty, fileCounts: nil)), .state(.noData))
        XCTAssertEqual(StoreDisplayAdapter.cursor(StoreCursorCollector.Result(state: .invalid, fileCounts: nil)), .state(.unparseable))
    }

    // MARK: - True zero

    func testMeasuredZeroComesOnlyFromCompletedMeasuredScans() {
        // A format-matching record set with zero in-period usage is a
        // measured zero (the collector reports it as complete).
        let zeroData = LocalUsageData(openaiUsedTokens: 0, openaiUsedByPeriod: zeroPeriods,
                                      source: "store_selected_sources")
        XCTAssertEqual(StoreDisplayAdapter.codex(.complete(zeroData)), .measuredComplete)
        XCTAssertEqual(StoreDisplayState.measuredComplete.valueTreatment, .confirmed)
        let success = StoreSourceState.Success(count: 0, date: date)
        XCTAssertEqual(StoreDisplayAdapter.state(permission: .granted, collection: .success(success)), .measuredComplete)

        // Empty, broken, and wrong targets never reach the measured states.
        let negatives: [StoreDisplayState] = [
            StoreDisplayAdapter.codex(.notDetected),
            StoreDisplayAdapter.codex(.invalidData),
            StoreDisplayAdapter.geminiChats(gemini(brain: .notDetected, chats: .notDetected, used: zeroPeriods)),
            StoreDisplayAdapter.claudeLogs(claude(logs: .notDetected, projects: .unavailable)),
            StoreDisplayAdapter.claudeLogs(claude(logs: .invalid, projects: .unavailable)),
            StoreDisplayAdapter.copilotMessages(copilot(state: .invalid)),
            StoreDisplayAdapter.state(permission: .granted, collection: .invalidTarget)
        ]
        for state in negatives {
            XCTAssertNotEqual(state, .measuredComplete)
            XCTAssertNotEqual(state, .measuredPartial)
            XCTAssertEqual(state.valueTreatment, .hidden, "\(state)")
        }
        guard case .state(let cursorState) = StoreDisplayAdapter.cursor(
            StoreCursorCollector.Result(state: .notRecognized, fileCounts: nil)) else {
            return XCTFail("Expected a display state for an unrecognized Cursor target")
        }
        XCTAssertEqual(cursorState, .suspectedWrongTarget)
        XCTAssertEqual(cursorState.valueTreatment, .hidden)
    }
}
