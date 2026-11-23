import CloudKit
import Foundation

/// CloudKit layout shared by the Mac uploader and the iOS reader.
///
/// One `Clip` record per Pastebot entry, in a custom zone of the user's private database.
/// Everything describing the clip is stored in `encryptedValues` (end-to-end encrypted when the
/// account uses Advanced Data Protection). Only `version` is a plain field. Images and very long
/// text are CKAssets, which CloudKit always stores encrypted.
enum CloudSchema {
    static let containerID = "iCloud.dev.pastebotbridge"
    static let zoneID = CKRecordZone.ID(zoneName: "Clips", ownerName: CKCurrentUserDefaultName)
    static let recordType = "Clip"

    /// Text longer than this (UTF-8 bytes) goes in an asset; records are capped at 1 MB.
    static let inlineTextLimit = 100_000

    enum Field {
        // Encrypted
        static let createdAt = "createdAt"
        static let kind = "kind"
        static let text = "text"
        static let textTruncated = "textTruncated"
        static let sourceName = "sourceName"
        static let sourceBundleID = "sourceBundleID"
        static let types = "types"
        static let hasImage = "hasImage"
        // Plain
        static let version = "version"
        // Assets
        static let textAsset = "textAsset"
        static let image = "image"
    }

    static func recordID(for clipID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: clipID, zoneID: zoneID)
    }

    // MARK: Deletions from iOS

    /// Written by iOS when a clip is deleted there. Tells the Mac never to upload that clip again
    /// (it stays in Pastebot). The clip id is in the record name; `deletedAt` exists because CloudKit
    /// won't deploy a record type with no fields to production.
    static let tombstoneRecordType = "DeletedClip"
    static let tombstoneDeletedAt = "deletedAt"
    private static let tombstonePrefix = "deleted-"

    static func tombstoneID(for clipID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: tombstonePrefix + clipID, zoneID: zoneID)
    }

    static func clipID(fromTombstone recordID: CKRecord.ID) -> String? {
        let name = recordID.recordName
        return name.hasPrefix(tombstonePrefix) ? String(name.dropFirst(tombstonePrefix.count)) : nil
    }

    /// Writes a clip into `record`. `textFile` must be set when the text exceeds `inlineTextLimit`.
    static func fill(_ record: CKRecord, with clip: Clip, version: Int, imageFile: URL?, textFile: URL?) {
        let values = record.encryptedValues
        values[Field.createdAt] = clip.createdAt
        values[Field.kind] = clip.kind.rawValue
        values[Field.textTruncated] = clip.textTruncated ? 1 : 0
        values[Field.sourceName] = clip.sourceName
        values[Field.sourceBundleID] = clip.sourceBundleID
        values[Field.types] = clip.types
        values[Field.hasImage] = clip.hasImage ? 1 : 0
        if let textFile {
            values[Field.text] = nil
            record[Field.textAsset] = CKAsset(fileURL: textFile)
        } else {
            values[Field.text] = clip.text
            record[Field.textAsset] = nil
        }
        record[Field.image] = imageFile.map(CKAsset.init(fileURL:))
        record[Field.version] = version
    }

    /// Reads a clip from a fetched record. Asset files must be read before the fetch event returns.
    static func clip(from record: CKRecord) -> Clip? {
        let values = record.encryptedValues
        guard record.recordType == recordType, let createdAt = values[Field.createdAt] as? Date else { return nil }
        var text = values[Field.text] as? String
        if text == nil, let url = (record[Field.textAsset] as? CKAsset)?.fileURL {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return Clip(
            id: record.recordID.recordName,
            createdAt: createdAt,
            sourceName: values[Field.sourceName] as? String,
            sourceBundleID: values[Field.sourceBundleID] as? String,
            kind: (values[Field.kind] as? String).flatMap(ClipKind.init(rawValue:)) ?? .other,
            text: text,
            textTruncated: (values[Field.textTruncated] as? Int ?? 0) != 0,
            types: values[Field.types] as? [String] ?? [],
            hasImage: (values[Field.hasImage] as? Int ?? 0) != 0
        )
    }
}
