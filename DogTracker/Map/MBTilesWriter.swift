import Foundation
import SQLite3
import OSLog

/// Creates and writes to an MBTiles (SQLite) file.
///
/// MBTiles spec: https://github.com/mapbox/mbtiles-spec/blob/master/1.3/spec.md
/// Used by the tile downloader (phase 9) and read by MapLibre at runtime
/// via file:// URL with mbtiles source type.
final class MBTilesWriter: @unchecked Sendable {
    private let log = Logger(subsystem: "com.levijohnson.DogTracker", category: "MBTiles")
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?

    let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &db, flags, nil) == SQLITE_OK else {
            throw MBTilesError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA journal_mode=WAL")
        try createSchema()
        try prepareInsert()
    }

    deinit {
        if let s = insertStmt { sqlite3_finalize(s) }
        if let d = db { sqlite3_close(d) }
    }

    /// Write metadata key/value pairs.
    func writeMetadata(_ meta: [(String, String)]) throws {
        let sql = "INSERT OR REPLACE INTO metadata (name, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MBTilesError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        for (name, value) in meta {
            sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw MBTilesError.insertFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_reset(stmt)
        }
    }

    /// Insert a single tile. `tileRow` is TMS (origin at bottom-left).
    func insertTile(zoom: Int, column: Int, row: Int, data: Data) throws {
        guard let stmt = insertStmt else { return }
        sqlite3_bind_int(stmt, 1, Int32(zoom))
        sqlite3_bind_int(stmt, 2, Int32(column))
        sqlite3_bind_int(stmt, 3, Int32(row))
        _ = data.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 4, buf.baseAddress, Int32(data.count), nil)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MBTilesError.insertFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_reset(stmt)
    }

    func beginTransaction() throws { try execute("BEGIN TRANSACTION") }
    func commitTransaction() throws { try execute("COMMIT") }

    // MARK: - Private

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS tiles (
                zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB,
                PRIMARY KEY (zoom_level, tile_column, tile_row)
            );
        """)
    }

    private func prepareInsert() throws {
        let sql = "INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK else {
            throw MBTilesError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw MBTilesError.execFailed(msg)
        }
    }
}

enum MBTilesError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case insertFailed(String)
    case execFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s): "MBTiles open failed: \(s)"
        case .prepareFailed(let s): "MBTiles prepare failed: \(s)"
        case .insertFailed(let s): "MBTiles insert failed: \(s)"
        case .execFailed(let s): "MBTiles exec failed: \(s)"
        }
    }
}
