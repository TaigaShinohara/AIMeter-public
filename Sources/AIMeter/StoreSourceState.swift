import Foundation

/// Prevents the direct-distribution collector from being used by the Store app
/// before the scoped Store collection pipeline is connected and verified.
enum StoreCollectionUnavailable: Error { case notConnected }

/// In-memory Store collection state. All mutations and result acceptance are
/// serialized by the actor. This does not serialize external reads or writes:
/// callers must cancel reads on revocation and separately gate persistence and
/// presentation against the current generation at their own boundary.
actor StoreSourceState {
    enum Permission: Equatable {
        case unselected, granted, reselect, revoked
    }

    struct Success: Equatable {
        let count: Int
        let date: Date
    }

    enum Collection: Equatable {
        case notRun, collecting, success(Success), partial(Success), estimate(Success), reference(Success)
        case noData, unparseable, invalidTarget, failed

        /// Whether this outcome carries a value produced by the current run.
        var producesValue: Bool {
            switch self {
            case .success, .partial, .estimate, .reference: return true
            case .notRun, .collecting, .noData, .unparseable, .invalidTarget, .failed: return false
            }
        }
    }

    struct Source: Equatable {
        fileprivate(set) var permission: Permission = .unselected
        fileprivate(set) var collection: Collection = .notRun
        /// The most recent measured result under the current permission set.
        fileprivate(set) var previousSuccess: Success?
    }

    struct Snapshot: Equatable {
        enum Coverage: Equatable { case none, partial, complete }
        let enabled: Bool
        let sources: [String: Source]
        let generation: UUID

        /// Coverage describes this run only; stale successes never count.
        /// The configured source IDs define the full expected input set.
        /// A source counts as covered when this run produced a value for it
        /// (measured, partial, estimate, or reference). Coverage says nothing
        /// about the kind of each value — that stays visible per source, and
        /// coverage never promotes an estimate or a reference value into a
        /// confirmed one.
        var coverage: Coverage {
            guard enabled, !sources.isEmpty else { return .none }
            let covered = sources.values.filter { $0.collection.producesValue }.count
            if covered == 0 { return .none }
            return covered == sources.count ? .complete : .partial
        }
    }

    struct Run: Equatable {
        fileprivate let generation: UUID
        let sources: Set<String>
    }

    enum Result: Equatable {
        /// Measured values from a complete scan of a validated target.
        /// Only use after target validation and a complete successful scan;
        /// a count of zero here is a measured zero, distinct from every
        /// other case.
        case success(count: Int, date: Date)
        /// Measured values from a scan that completed while some inputs or
        /// records were missing. The values cover only what was read.
        case partial(count: Int, date: Date)
        /// Values that include estimates. They are never presented or
        /// accumulated as confirmed values.
        case estimate(count: Int, date: Date)
        /// Reference values only (for example totals with no known period).
        /// They are never merged into the period totals.
        case reference(count: Int, date: Date)
        /// The scan completed but the target held no data. Never a zero.
        case noData
        /// The target was read but its contents could not be interpreted.
        case unparseable
        case invalidTarget, failed
    }

    private var enabled = false
    private var sources: [String: Source]
    private var generation = UUID()

    init(sourceIDs: Set<String>) {
        sources = Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, Source()) })
    }

    func snapshot() -> Snapshot {
        Snapshot(enabled: enabled, sources: sources, generation: generation)
    }

    /// Cancelled selection calls no mutation; especially it preserves a grant.
    func selectionCancelled() {}

    @discardableResult
    func setPermission(_ permission: Permission, for id: String) -> Bool {
        guard sources[id] != nil else { return false }
        // A new selection can replace an existing grant while remaining granted.
        guard sources[id]?.permission != permission || permission == .granted else { return true }
        sources[id]?.permission = permission
        invalidate()
        return true
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        invalidate()
    }

    /// A new run supersedes every previous run, even with identical permissions.
    func begin() -> Run? {
        guard enabled else { return nil }
        let allowed = Set(sources.compactMap { $0.value.permission == .granted ? $0.key : nil })
        guard !allowed.isEmpty else { return nil }
        generation = UUID()
        for id in allowed { sources[id]?.collection = .collecting }
        return Run(generation: generation, sources: allowed)
    }

    /// Accepts each source once, and rejects stale, unauthorized, or invalid results.
    /// `previousSuccess` tracks measured results only (complete or partial):
    /// stale presentation shows it as an old confirmed value, so an estimate
    /// or a reference value must never take its place.
    @discardableResult
    func finish(_ result: Result, source id: String, run: Run) -> Bool {
        guard enabled, run.generation == generation, run.sources.contains(id),
              sources[id]?.permission == .granted,
              sources[id]?.collection == .collecting else { return false }
        switch result {
        case let .success(count, date):
            guard count >= 0 else { return false }
            let success = Success(count: count, date: date)
            sources[id]?.collection = .success(success)
            sources[id]?.previousSuccess = success
        case let .partial(count, date):
            guard count >= 0 else { return false }
            let success = Success(count: count, date: date)
            sources[id]?.collection = .partial(success)
            sources[id]?.previousSuccess = success
        case let .estimate(count, date):
            guard count >= 0 else { return false }
            sources[id]?.collection = .estimate(Success(count: count, date: date))
        case let .reference(count, date):
            guard count >= 0 else { return false }
            sources[id]?.collection = .reference(Success(count: count, date: date))
        case .noData: sources[id]?.collection = .noData
        case .unparseable: sources[id]?.collection = .unparseable
        case .invalidTarget: sources[id]?.collection = .invalidTarget
        case .failed: sources[id]?.collection = .failed
        }
        return true
    }

    /// Whether this generation is current; checking it alone does not make a
    /// later external side effect atomic with a concurrent permission change.
    func isCurrent(_ run: Run) -> Bool { enabled && run.generation == generation }

    private func invalidate() {
        generation = UUID()
        for id in Array(sources.keys) {
            sources[id]?.collection = .notRun
            sources[id]?.previousSuccess = nil
        }
    }
}
