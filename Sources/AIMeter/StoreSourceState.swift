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
        case notRun, collecting, success(Success), notDetected, invalidTarget, failed
    }

    struct Source: Equatable {
        fileprivate(set) var permission: Permission = .unselected
        fileprivate(set) var collection: Collection = .notRun
        /// The most recent successful result under the current permission set.
        fileprivate(set) var previousSuccess: Success?
    }

    struct Snapshot: Equatable {
        enum Coverage: Equatable { case none, partial, complete }
        let enabled: Bool
        let sources: [String: Source]
        let generation: UUID

        /// Coverage describes this run only; stale successes never count.
        /// The configured source IDs define the full expected input set.
        var coverage: Coverage {
            guard enabled, !sources.isEmpty else { return .none }
            let successes = sources.values.filter {
                if case .success = $0.collection { return true }
                return false
            }.count
            if successes == 0 { return .none }
            return successes == sources.count ? .complete : .partial
        }
    }

    struct Run: Equatable {
        fileprivate let generation: UUID
        let sources: Set<String>
    }

    enum Result: Equatable {
        /// Only use after target validation and a complete successful scan.
        case success(count: Int, date: Date)
        case notDetected, invalidTarget, failed
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
        case .notDetected: sources[id]?.collection = .notDetected
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
