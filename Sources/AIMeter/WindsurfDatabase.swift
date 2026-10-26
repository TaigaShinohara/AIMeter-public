import Foundation
import SQLite3
import AIMeterCore

enum WindsurfDatabase {
    private final class Budget {
        let input: BoundedInput
        var remaining: Int
        init(_ input: BoundedInput) {
            self.input = input
            remaining = input.limits.sqliteSteps
        }
        func tick() -> Int32 {
            remaining -= 100
            guard remaining > 0, (try? input.check()) != nil else { return 1 }
            return 0
        }
    }

    static func readPlan(at url: URL, input: BoundedInput, snapshotReady: (() throws -> Void)? = nil) throws -> Data? {
        // SQLite opens filenames itself. Only let it open our private copy so a
        // source-path replacement cannot turn its blocking open into a FIFO read.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aimeter-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("state.vscdb")
        try input.copyRegularFile(at: url, to: snapshot, maximum: input.limits.databaseBytes)
        // Preserve committed WAL data from active editors. SQLite validates WAL
        // frames; an inconsistent concurrent copy fails without replacing usage.
        let wal = URL(fileURLWithPath: url.path + "-wal")
        var walInfo = stat()
        if Darwin.lstat(wal.path, &walInfo) == 0 {
            guard (walInfo.st_mode & S_IFMT) == S_IFREG else {
                throw BoundedInput.Failure.file
            }
            try input.copyRegularFile(at: wal, to: URL(fileURLWithPath: snapshot.path + "-wal"),
                                      maximum: input.limits.databaseBytes)
        } else if errno != ENOENT && errno != ENOTDIR {
            throw BoundedInput.Failure.file
        }
        try snapshotReady?()
        try input.check()
        var db: OpaquePointer?
        guard sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw BoundedInput.Failure.database
        }
        defer { sqlite3_close(db) }
        let budget = Budget(input)
        sqlite3_progress_handler(db, 100, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<Budget>.fromOpaque(pointer).takeUnretainedValue().tick()
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }
        sqlite3_busy_timeout(db, 100)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(min(input.limits.jsonBytes, Int(Int32.max))))
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_limit(db, SQLITE_LIMIT_EXPR_DEPTH, 32)
        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        guard sqlite3_exec(db, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw BoundedInput.Failure.database
        }

        func query(_ sql: String, body: (OpaquePointer) throws -> Void) throws {
            try input.check()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                throw BoundedInput.Failure.database
            }
            defer { sqlite3_finalize(statement) }
            while true {
                try input.check()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw BoundedInput.Failure.database }
                try body(statement)
            }
        }
        func text(_ statement: OpaquePointer, _ column: Int32) -> String {
            guard let value = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: value)
        }

        var ordinaryTable = false
        try query("PRAGMA main.table_list('ItemTable')") {
            ordinaryTable = text($0, 1).lowercased() == "itemtable" && text($0, 2) == "table"
        }
        guard ordinaryTable else { throw BoundedInput.Failure.database }
        var columns = Set<String>()
        try query("PRAGMA main.table_xinfo('ItemTable')") {
            // Generated/hidden columns can execute schema expressions when read.
            guard sqlite3_column_int($0, 6) == 0 else { throw BoundedInput.Failure.database }
            columns.insert(text($0, 1).lowercased())
        }
        guard columns.contains("key"), columns.contains("value") else { throw BoundedInput.Failure.database }
        sqlite3_set_authorizer(db, { _, action, first, second, _, _ in
            if action == SQLITE_SELECT { return SQLITE_OK }
            if action == SQLITE_READ, let first, let second,
               String(cString: first).lowercased() == "itemtable",
               ["key", "value"].contains(String(cString: second).lowercased()) { return SQLITE_OK }
            return SQLITE_DENY
        }, nil)

        var result: Data?
        try query("SELECT value FROM main.ItemTable WHERE key='windsurf.settings.cachedPlanInfo' LIMIT 1") {
            let length = Int(sqlite3_column_bytes($0, 0))
            guard length <= input.limits.jsonBytes else { throw BoundedInput.Failure.limit }
            guard [SQLITE_TEXT, SQLITE_BLOB].contains(sqlite3_column_type($0, 0)),
                  let bytes = sqlite3_column_blob($0, 0) else { throw BoundedInput.Failure.database }
            result = Data(bytes: bytes, count: length)
        }
        return result
    }
}
