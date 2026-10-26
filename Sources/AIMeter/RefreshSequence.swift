import Foundation

enum RefreshSequence {
    /// Local failure must preserve its last snapshot without suppressing the
    /// independent, explicitly configured API refresh.
    @MainActor
    static func run(local: () async throws -> Void, remote: () async -> Void) async -> Error? {
        var localError: Error?
        do { try await local() } catch { localError = error }
        if !Task.isCancelled { await remote() }
        return localError
    }
}
