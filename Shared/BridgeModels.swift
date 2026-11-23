import Foundation

enum ClipKind: String, Codable, Sendable {
    case text, link, file, image, other
}

struct Clip: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var createdAt: Date
    var sourceName: String?
    var sourceBundleID: String?
    var kind: ClipKind
    var text: String?
    /// True when Pastebot's text was longer than the Mac uploads (20 MB).
    var textTruncated: Bool
    /// Pasteboard types (UTIs) stored for this clip.
    var types: [String]
    var hasImage: Bool
}

/// A Mac clipboard manager whose history is mirrored to iCloud.
enum ClipSourceKind: String, CaseIterable, Sendable {
    case pastebot, alfred

    var displayName: String {
        switch self {
        case .pastebot: "Pastebot"
        case .alfred: "Alfred"
        }
    }

    /// Clip ids from this source start with this prefix. Pastebot ids are bare UUIDs.
    var idPrefix: String {
        switch self {
        case .pastebot: ""
        case .alfred: "alfred-"
        }
    }

    static func of(clipID: String) -> ClipSourceKind {
        clipID.hasPrefix(ClipSourceKind.alfred.idPrefix) ? .alfred : .pastebot
    }
}

extension Clip {
    /// The clipboard manager on the Mac that recorded this clip.
    var clipboardManager: ClipSourceKind { .of(clipID: id) }
}

/// An app clips were copied from, for filtering.
struct SourceApp: Codable, Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var count: Int
}

/// One entry per clip in Pastebot's database.
struct ManifestEntry: Codable, Hashable, Sendable {
    var id: String
    /// Pastebot bumps this when a clip is edited.
    var version: Int
}

extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var bridge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
