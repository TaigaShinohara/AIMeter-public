import Foundation

/// Serializes Store selection changes and result commits at the same boundary.
/// Callers must cancel ongoing asynchronous collection when a selection changes;
/// generation invalidation prevents its eventual result from being committed.
/// All relevant selection mutations and commits must pass through this actor.
actor StoreAccessCoordinator {
    struct Run: Equatable {
        fileprivate let id: UUID
    }

    private var generation = UUID()

    /// Starting a new run supersedes prior runs.
    func beginRun() -> Run {
        generation = UUID()
        return Run(id: generation)
    }

    /// Call only after an actual selection or explicit removal, not panel cancel.
    /// The synchronous operation runs after invalidation while this actor holds
    /// the boundary. Even a throwing operation leaves the old generation invalid.
    func changeSelection(_ operation: () throws -> Void) rethrows {
        generation = UUID()
        try operation()
    }

    /// Executes a synchronous commit only while the run remains current.
    /// The run is consumed before execution, including when the operation throws.
    /// Neither closure can suspend; awaiting inside it would break this boundary.
    @discardableResult
    func commit(_ run: Run, _ operation: () throws -> Void) rethrows -> Bool {
        guard run.id == generation else { return false }
        generation = UUID()
        try operation()
        return true
    }
}
