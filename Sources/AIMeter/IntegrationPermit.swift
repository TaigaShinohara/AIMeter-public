import Foundation

/// Serializes revocation with the actual credential-bearing request/process
/// start. Cancellation alone can arrive between an initial check and resume.
final class IntegrationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func revoke() {
        lock.lock(); active = false; lock.unlock()
    }

    func withPermission<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CancellationError() }
        try Task.checkCancellation()
        return try action()
    }

    func check() throws { try withPermission {} }
}
