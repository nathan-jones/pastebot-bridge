import CryptoKit
import Foundation
import SQLite3

/// Read-only access to Alfred's clipboard history (Powerpack feature).
///
/// Schema (Alfred 4–6):
///   clipboard(item, ts decimal seconds-since-2001, app, apppath, dataType integer, dataHash)
///   dataType 0: text, in `item`
///            1: image; `dataHash` names a TIFF in `clipboard.alfdb.data/`
///            2: files; `dataHash` names a plist (array of paths) in `clipboard.alfdb.data/`
///
/// The table has no stable key (rowids can change on VACUUM), so a clip's id is derived from its
/// timestamp and content. Alfred never edits an entry in place, so every version is 0.
///
/// Not thread-safe; owned and serialized by `ClipStore`.
final class AlfredDatabase: ClipSource {
    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Alfred/Databases/clipboard.alfdb")

    private enum DataType: Int {
        case text = 0, image = 1, files = 2
    }

    let kind = ClipSourceKind.alfred
    private let db: SQLiteDatabase
    private let dataDirectory: URL
    /// clip id → rowid, refreshed by `manifest()`.
    private var rowIDs: [String: Int64] = [:]
    /// App path → bundle identifier (nil if the app is gone).
    private var bundleIDs: [String: String?] = [:]

    init(url: URL = AlfredDatabase.defaultURL) {
        db = SQLiteDatabase(url: url, appName: "Alfred")
        dataDirectory = URL(fileURLWithPath: url.path + ".data", isDirectory: true)
    }

    func open() throws { try db.open(validationQuery: "SELECT count(*) FROM clipboard") }

    func close() {
        db.close()
        rowIDs = [:]
    }

    func dataVersion() throws -> Int { try db.dataVersion() }
    func entryCount() throws -> Int { try db.scalarInt("SELECT count(*) FROM clipboard") }

    // MARK: Queries

    func manifest() throws -> [ManifestEntry] {
        let stmt = try db.prepare("""
            SELECT rowid, ts, dataType, dataHash, item FROM clipboard ORDER BY ts DESC
            """)
        defer { sqlite3_finalize(stmt) }
        var result: [ManifestEntry] = []
        var rowIDs: [String: Int64] = [:]
        while try db.step(stmt) {
            let id = Self.clipID(stmt, ts: 1, dataType: 2, dataHash: 3, item: 4)
            rowIDs[id] = rowIDs[id] ?? sqlite3_column_int64(stmt, 0)
            result.append(ManifestEntry(id: id, version: 0))
        }
        self.rowIDs = rowIDs
        return result
    }

    func cloudClip(id: String, maxTextBytes: Int) throws -> CloudClip? {
        if rowIDs[id] == nil { _ = try manifest() }
        guard let rowID = rowIDs[id] else { return nil }

        let stmt = try db.prepare("""
            SELECT ts, dataType, dataHash, item, app, apppath,
                   length(CAST(item AS BLOB)), substr(CAST(item AS BLOB), 1, ?2)
            FROM clipboard WHERE rowid = ?1
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        sqlite3_bind_int(stmt, 2, Int32(clamping: maxTextBytes))
        guard try db.step(stmt), Self.clipID(stmt, ts: 0, dataType: 1, dataHash: 2, item: 3) == id else {
            // The table changed since the last manifest; the next reconcile picks it up.
            rowIDs[id] = nil
            return nil
        }

        let createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        let dataHash = SQLiteDatabase.columnText(stmt, 2)
        let appPath = SQLiteDatabase.columnText(stmt, 5)
        var clip = Clip(id: id, createdAt: createdAt, sourceName: SQLiteDatabase.columnText(stmt, 4),
                        sourceBundleID: appPath.flatMap(bundleID(forApp:)),
                        kind: .other, text: nil, textTruncated: false, types: [], hasImage: false)
        var image: Data?

        switch DataType(rawValue: Int(sqlite3_column_int(stmt, 1))) {
        case .text:
            let fullLength = Int(sqlite3_column_int64(stmt, 6))
            let data = SQLiteDatabase.columnBlob(stmt, 7) ?? Data()
            clip.text = ClipContent.decodeUTF8(data)
            clip.textTruncated = data.count < fullLength
            clip.types = ["public.utf8-plain-text"]
            clip.kind = clip.text.map(ClipContent.looksLikeURL) == true ? .link : .text
        case .image:
            image = dataHash.flatMap(imageData(named:))
            clip.types = ["public.tiff"]
            clip.hasImage = image != nil
            clip.kind = .image
        case .files:
            let paths = dataHash.flatMap(filePaths(named:))
            clip.text = paths?.joined(separator: "\n") ?? SQLiteDatabase.columnText(stmt, 3)
            clip.types = ["public.file-url"]
            clip.kind = .file
        case nil:
            clip.text = SQLiteDatabase.columnText(stmt, 3)
        }
        return CloudClip(clip: clip, version: 0, image: image)
    }

    /// Alfred clips were never uploaded at the old image resolution, so nothing to migrate.
    func imageClipIDs() throws -> [String] { [] }

    // MARK: Helpers

    /// A stable id for a row: hash of its type, timestamp and content (or data file name).
    private static func clipID(_ stmt: OpaquePointer, ts: Int32, dataType: Int32, dataHash: Int32,
                               item: Int32) -> String {
        var hasher = SHA256()
        let content = SQLiteDatabase.columnText(stmt, dataHash).flatMap { $0.isEmpty ? nil : $0 }
            .map { Data($0.utf8) } ?? SQLiteDatabase.columnBlob(stmt, item) ?? Data()
        hasher.update(data: Data("\(sqlite3_column_int(stmt, dataType))\u{0}".utf8))
        hasher.update(data: Data("\(SQLiteDatabase.columnText(stmt, ts) ?? "")\u{0}".utf8))
        hasher.update(data: content)
        let hex = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
        return ClipSourceKind.alfred.idPrefix + hex
    }

    private func bundleID(forApp path: String) -> String? {
        if let cached = bundleIDs[path] { return cached }
        let id = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
        bundleIDs[path] = id
        return id
    }

    /// Alfred stores images as TIFF; PNG/JPEG pass through, anything else becomes PNG.
    private func imageData(named name: String) -> Data? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent(name)) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        return ClipContent.pngData(fromImage: data)
    }

    private func filePaths(named name: String) -> [String]? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent(name)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        let paths = (plist as? [Any])?.compactMap { $0 as? String }
        return paths?.isEmpty == false ? paths : nil
    }
}
