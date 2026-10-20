import Foundation
import SQLite3

/// A read-only connection to another app's database.
final class SQLiteReader {
    private var db: OpaquePointer?

    /// Without pending WAL content the database file is complete on its own, so it's opened immutable:
    /// no locks, and no `-wal`/`-shm` files left behind next to it. With pending content it's opened
    /// read-only, which reads the WAL the owning app keeps.
    init?(path: String) {
        let walSize = TranscriptInfo.of(path + "-wal")?.size ?? 0
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:" + escaped + (walSize == 0 ? "?immutable=1" : "?mode=ro")
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            // deinit still runs for an init that fails here, so it mustn't close the handle again.
            sqlite3_close(db)
            db = nil
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        sqlite3_close(db)
    }

    func hasTable(_ name: String) -> Bool {
        var found = false
        rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]) { _ in found = true }
        return found
    }

    /// Runs `sql` with `arguments` bound in order, calling `body` for each row. Errors end the query.
    func rows(_ sql: String, _ arguments: [Any] = [], _ body: (Row) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }
        for (offset, argument) in arguments.enumerated() {
            let position = Int32(offset + 1)
            switch argument {
            case let value as Int64: sqlite3_bind_int64(statement, position, value)
            case let value as Int: sqlite3_bind_int64(statement, position, Int64(value))
            case let value as String: sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: sqlite3_bind_null(statement, position)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            body(Row(statement: statement))
        }
    }

    struct Row {
        let statement: OpaquePointer?

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func blob(_ column: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(statement, column) else {
                return isNull(column) ? nil : Data()
            }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}

/// Size and modification time of a database and its WAL, to tell whether it changed since last read.
struct DatabaseStamp: Equatable {
    var size: UInt64
    var modified: Double
    var walSize: UInt64
    var walModified: Double

    init?(path: String) {
        guard let db = TranscriptInfo.of(path) else { return nil }
        let wal = TranscriptInfo.of(path + "-wal")
        size = db.size
        modified = db.modified
        walSize = wal?.size ?? 0
        walModified = wal?.modified ?? 0
    }
}
