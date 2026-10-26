import Foundation
import Combine

/// Owns a single validation request. Cancellation invalidates its generation
/// before cancelling the worker, so a late result cannot save a stale path.
@MainActor
final class PathValidation: ObservableObject {
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
    }

    func start(
        provider: String, path: String,
        scan: @escaping (String, String) async -> LocalUsageCollector.ProviderPathScanResult = {
            await LocalUsageCollector.validateAndScanAsync(providerId: $0, path: $1)
        },
        completion: @escaping (LocalUsageCollector.ProviderPathScanResult) -> Void
    ) {
        cancel()
        let request = generation
        isRunning = true
        task = Task {
            let result = await scan(provider, path)
            guard !Task.isCancelled, request == generation else { return }
            isRunning = false
            task = nil
            completion(result)
        }
    }
}
