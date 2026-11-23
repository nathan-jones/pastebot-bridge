import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

enum ClipDatabaseError: LocalizedError {
    case notFound(URL)
    case accessDenied(app: String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let url): "Database not found at \(url.path)"
        case .accessDenied(let app): "macOS blocked access to \(app)'s data. Grant Full Disk Access."
        case .sqlite(let message): "SQLite: \(message)"
        }
    }
}

/// A read-only SQLite connection to another app's database. Not thread-safe.
final class SQLiteDatabase {
    let url: URL
    private let appName: String
    private var db: OpaquePointer?

    init(url: URL, appName: String) {
        self.url = url
        self.appName = appName
    }

    deinit {
        sqlite3_close(db)
    }

    var isOpen: Bool { db != nil }

    /// Opens the database read-only and runs `validationQuery` to make sure it's readable.
    func open(validationQuery: String) throws {
        guard db == nil else { return }

        // Distinguish "missing" from "blocked by TCC" before SQLite gives a vaguer error.
        do {
            try FileHandle(forReadingFrom: url).close()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ClipDatabaseError.notFound(url)
        } catch {
            throw ClipDatabaseError.accessDenied(app: appName)
        }

        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2("file:\(path)?mode=ro", &handle,
                                 SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(rc))"
            sqlite3_close(handle)
            throw ClipDatabaseError.sqlite(message)
        }
        sqlite3_busy_timeout(handle, 3000)
        db = handle

        do {
            _ = try scalarInt(validationQuery)
        } catch {
            close()
            throw error
        }
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    /// Changes whenever another connection (the clipboard app) commits to the database.
    func dataVersion() throws -> Int {
        try scalarInt("PRAGMA data_version")
    }

    // MARK: Statements

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw ClipDatabaseError.sqlite("database is not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ClipDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    func step(_ stmt: OpaquePointer) throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ClipDatabaseError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard try step(stmt) else { throw ClipDatabaseError.sqlite("no result for \(sql)") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    static func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    static func sqlList(_ values: [String]) -> String {
        values.map { "'\($0)'" }.joined(separator: ",")
    }
}

// MARK: Shared clip helpers

enum ClipContent {
    /// http(s) text with no whitespace is treated as a link.
    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            && !trimmed.contains(where: \.isWhitespace)
    }

    /// Decodes UTF-8 that may have been cut mid-character by `substr`.
    static func decodeUTF8(_ data: Data) -> String? {
        for drop in 0...min(3, data.count) {
            if let string = String(data: data.dropLast(drop), encoding: .utf8) { return string }
        }
        return nil
    }

    /// Re-encodes an image (usually TIFF, which can be tens of MB) losslessly as PNG, keeping its
    /// orientation and color profile.
    static func pngData(fromImage data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
