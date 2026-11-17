import Foundation

/// Persists user-selected read-only access separately for each source of a service.
/// A saved path alone is never treated as permission to read it.
final class StoreBookmarkStore {
    enum Failure: Error, Equatable {
        case missing
        case invalid
        case accessDenied
    }

    enum SelectionStatus: Equatable {
        case unselected
        /// Resolved bookmark with a recorded selection identity: access and
        /// contents remain unverified.
        case saved(URL)
        case needsReselection
    }

    struct Operations {
        var create: (URL) throws -> Data
        var resolve: (Data) throws -> (url: URL, stale: Bool)
        var start: (URL) -> Bool
        var stop: (URL) -> Void
        /// Records the selected target's identity at selection time. Returns
        /// nil when the identity cannot be established; the selection is then
        /// stored without one and reads back as needing reselection.
        var captureIdentity: (URL) -> StoreSelectionIdentity? = { StoreSelectionIdentity.capture(url: $0) }

        static let live = Operations(
            create: { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                          includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolve: { data in
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                return (url, stale)
            },
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    private let defaults: UserDefaults
    private let operations: Operations
    private let storageKey = "storeSourceBookmarks"
    private let identityStorageKey = "storeSourceIdentities"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, operations: Operations = .live) {
        self.defaults = defaults
        self.operations = operations
    }

    /// Called only after the user selects a source in the system panel.
    /// The target's identity is captured while the selection is in effect and
    /// stored with the bookmark. When no identity can be recorded, any
    /// identity recorded for an earlier selection of this source is discarded,
    /// so the new selection is never matched against the previous target.
    func save(_ url: URL, sourceID: String) throws {
        let bookmark = try operations.create(url)
        let identity = operations.captureIdentity(url)
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:]
        bookmarks[sourceID] = bookmark
        defaults.set(bookmarks, forKey: storageKey)
        var identities = defaults.dictionary(forKey: identityStorageKey) as? [String: Data] ?? [:]
        if let identity, let data = try? JSONEncoder().encode(identity) {
            identities[sourceID] = data
        } else {
            identities.removeValue(forKey: sourceID)
        }
        defaults.set(identities, forKey: identityStorageKey)
    }

    func remove(sourceID: String) {
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: sourceID)
        defaults.set(bookmarks, forKey: storageKey)
        var identities = defaults.dictionary(forKey: identityStorageKey) as? [String: Data] ?? [:]
        identities.removeValue(forKey: sourceID)
        defaults.set(identities, forKey: identityStorageKey)
    }

    /// The identity recorded at selection time, or nil when none was recorded
    /// (including selections saved before identities existed) or the stored
    /// record cannot be decoded. A nil result means unverified; it must never
    /// be treated as a match.
    func identity(sourceID: String) -> StoreSelectionIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = (defaults.dictionary(forKey: identityStorageKey) as? [String: Data])?[sourceID] else {
            return nil
        }
        return try? JSONDecoder().decode(StoreSelectionIdentity.self, from: data)
    }

    /// Inspect the saved selection without starting security-scoped access or
    /// reading the target. A resolved URL does not establish target existence.
    /// A selection without a recorded identity is reported as needing
    /// reselection: pre-identity saves are never trusted implicitly.
    func selectionStatus(sourceID: String) -> SelectionStatus {
        guard let bookmark = savedBookmark(sourceID: sourceID) else { return .unselected }
        guard identity(sourceID: sourceID) != nil else { return .needsReselection }
        do {
            let resolved = try operations.resolve(bookmark)
            return resolved.stale ? .needsReselection : .saved(resolved.url)
        } catch {
            return .needsReselection
        }
    }

    /// Keeps access active through the entire operation, including suspension.
    func withAccess<T>(sourceID: String, _ body: (URL) async throws -> T) async throws -> T {
        guard let bookmark = savedBookmark(sourceID: sourceID) else { throw Failure.missing }
        let resolved: (url: URL, stale: Bool)
        do { resolved = try operations.resolve(bookmark) }
        catch { throw Failure.invalid }
        guard operations.start(resolved.url) else { throw Failure.accessDenied }
        defer { operations.stop(resolved.url) }
        if resolved.stale {
            let replacement: Data
            do { replacement = try operations.create(resolved.url) }
            catch { throw Failure.invalid }
            // A concurrent replacement or removal must not be undone by the
            // refresh of an older bookmark.
            guard replaceIfUnchanged(replacement, original: bookmark, sourceID: sourceID) else {
                throw CancellationError()
            }
        }
        return try await body(resolved.url)
    }

    private func savedBookmark(sourceID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return (defaults.dictionary(forKey: storageKey) as? [String: Data])?[sourceID]
    }

    private func replaceIfUnchanged(_ replacement: Data, original: Data, sourceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:]
        guard bookmarks[sourceID] == original else { return false }
        bookmarks[sourceID] = replacement
        defaults.set(bookmarks, forKey: storageKey)
        return true
    }
}
