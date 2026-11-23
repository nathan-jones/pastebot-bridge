import Foundation
import SQLite3

/// Read-only access to Pastebot 3's clipboard database.
///
/// Schema (Pastebot 3.2):
///   entries(uuid, version, created_at REAL unix-seconds, source_name, source_bundle_identifier, …)
///   types_data(id, entry_uuid, item_index, type UTI, data BLOB)
///
/// Not thread-safe; owned and serialized by `ClipStore`.
final class PastebotDatabase: ClipSource {
    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.tapbots.Pastebot3Mac/Data/Documents/general.pastebot/sql")

    static let textTypes = [
        "public.utf8-plain-text",
        "public.utf16-external-plain-text",
        "public.plain-text",
        "public.text",
        "public.url",
        "public.file-url",
    ]
    static let imageTypes = ["public.png", "public.jpeg", "public.heic", "public.tiff"]

    let kind = ClipSourceKind.pastebot
    private let db: SQLiteDatabase

    init(url: URL = PastebotDatabase.defaultURL) {
        db = SQLiteDatabase(url: url, appName: "Pastebot")
    }

    func open() throws { try db.open(validationQuery: "SELECT count(*) FROM entries") }
    func close() { db.close() }
    func dataVersion() throws -> Int { try db.dataVersion() }
    func entryCount() throws -> Int { try db.scalarInt("SELECT count(*) FROM entries") }

    // MARK: Queries

    func manifest() throws -> [ManifestEntry] {
        let stmt = try db.prepare("SELECT uuid, version FROM entries ORDER BY created_at DESC")
        defer { sqlite3_finalize(stmt) }
        var result: [ManifestEntry] = []
        while try db.step(stmt) {
            result.append(ManifestEntry(id: SQLiteDatabase.columnText(stmt, 0) ?? "",
                                        version: Int(sqlite3_column_int64(stmt, 1))))
        }
        return result
    }

    func cloudClip(id: String, maxTextBytes: Int) throws -> CloudClip? {
        let stmt = try db.prepare("""
            SELECT uuid, created_at, source_name, source_bundle_identifier, version FROM entries WHERE uuid = ?1
            """)
        defer { sqlite3_finalize(stmt) }
        SQLiteDatabase.bindText(stmt, 1, id)
        guard try db.step(stmt) else { return nil }
        let clip = try buildClip(
            id: SQLiteDatabase.columnText(stmt, 0) ?? id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            sourceName: SQLiteDatabase.columnText(stmt, 2),
            bundleID: SQLiteDatabase.columnText(stmt, 3),
            previewBytes: maxTextBytes
        )
        let version = Int(sqlite3_column_int64(stmt, 4))
        return CloudClip(clip: clip, version: version, image: clip.hasImage ? try fullImage(id: id) : nil)
    }

    /// The clip's best image at full resolution. PNG/JPEG/HEIC are returned as stored; anything else
    /// (usually TIFF, which can be tens of MB) is re-encoded losslessly as PNG.
    private func fullImage(id: String) throws -> Data? {
        let stmt = try db.prepare("""
            SELECT type, data FROM types_data
            WHERE entry_uuid = ?1 AND item_index = 0 AND type IN (\(SQLiteDatabase.sqlList(Self.imageTypes)))
            ORDER BY CASE type WHEN 'public.png' THEN 0 WHEN 'public.jpeg' THEN 1
                               WHEN 'public.heic' THEN 2 ELSE 3 END
            LIMIT 1
            """)
        defer { sqlite3_finalize(stmt) }
        SQLiteDatabase.bindText(stmt, 1, id)
        guard try db.step(stmt), let blob = SQLiteDatabase.columnBlob(stmt, 1) else { return nil }
        let type = SQLiteDatabase.columnText(stmt, 0) ?? ""
        if ["public.png", "public.jpeg", "public.heic"].contains(type) { return blob }
        return ClipContent.pngData(fromImage: blob)
    }

    func imageClipIDs() throws -> [String] {
        let stmt = try db.prepare("""
            SELECT DISTINCT entry_uuid FROM types_data
            WHERE item_index = 0 AND type IN (\(SQLiteDatabase.sqlList(Self.imageTypes)))
            """)
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        while try db.step(stmt) { if let id = SQLiteDatabase.columnText(stmt, 0) { ids.append(id) } }
        return ids
    }

    // MARK: Clip assembly

    private func buildClip(id: String, createdAt: Date, sourceName: String?, bundleID: String?,
                           previewBytes: Int) throws -> Clip {
        // Only pull bytes for text types; image blobs can be tens of MB.
        let stmt = try db.prepare("""
            SELECT type, length(data),
                   CASE WHEN type IN (\(SQLiteDatabase.sqlList(Self.textTypes))) THEN substr(data, 1, ?2) END
            FROM types_data WHERE entry_uuid = ?1 AND item_index = 0 ORDER BY id
            """)
        defer { sqlite3_finalize(stmt) }
        SQLiteDatabase.bindText(stmt, 1, id)
        sqlite3_bind_int(stmt, 2, Int32(clamping: previewBytes))

        var types: [String] = []
        var payloads: [String: (data: Data, fullLength: Int)] = [:]
        while try db.step(stmt) {
            let type = SQLiteDatabase.columnText(stmt, 0) ?? ""
            types.append(type)
            if let data = SQLiteDatabase.columnBlob(stmt, 2) {
                payloads[type] = (data, Int(sqlite3_column_int64(stmt, 1)))
            }
        }

        let hasImage = types.contains(where: Self.imageTypes.contains)
        var text: String?
        var truncated = false
        var kind: ClipKind = hasImage ? .image : .other

        if let fileURL = payloads["public.file-url"], let string = ClipContent.decodeUTF8(fileURL.data),
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kind = .file
            text = url.isFileURL ? url.path : string
        } else if let (type, payload) = Self.textTypes.lazy.compactMap({ t in payloads[t].map { (t, $0) } }).first {
            text = type == "public.utf16-external-plain-text"
                ? Self.decodeUTF16(payload.data)
                : (ClipContent.decodeUTF8(payload.data) ?? Self.decodeUTF16(payload.data))
            truncated = payload.data.count < payload.fullLength
            if let text {
                kind = (type == "public.url" || ClipContent.looksLikeURL(text)) ? .link : .text
            }
        }

        return Clip(id: id, createdAt: createdAt, sourceName: sourceName, sourceBundleID: bundleID,
                    kind: kind, text: text, textTruncated: truncated, types: types, hasImage: hasImage)
    }

    private static func decodeUTF16(_ data: Data) -> String? {
        var data = data
        if data.count % 2 == 1 { data = data.dropLast() }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf16LittleEndian)
    }
}
