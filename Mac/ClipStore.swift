import Foundation

enum DatabaseStatus: Equatable, Sendable {
    case unknown
    case ok(count: Int)
    /// The app (or its clipboard history) isn't on this Mac.
    case notInstalled
    case accessDenied
    case error(String)
}

struct SourceStatus: Equatable, Identifiable, Sendable {
    var kind: ClipSourceKind
    var status: DatabaseStatus
    var id: ClipSourceKind { kind }
}

/// A clip ready to upload, with its source version and optional image.
struct CloudClip: Sendable {
    var clip: Clip
    var version: Int
    var image: Data?
}

/// Read-only access to one clipboard manager's database. Not thread-safe; serialized by `ClipStore`.
protocol ClipSource: AnyObject {
    var kind: ClipSourceKind { get }
    func open() throws
    func close()
    /// Changes whenever the app commits to its database.
    func dataVersion() throws -> Int
    func entryCount() throws -> Int
    func manifest() throws -> [ManifestEntry]
    /// Everything needed to upload one clip, or nil if it no longer exists.
    func cloudClip(id: String, maxTextBytes: Int) throws -> CloudClip?
    func imageClipIDs() throws -> [String]
}

/// The clips of every source that could be read. Sources that couldn't be read are left out of
/// `readSources`, so their clips aren't mistaken for deleted.
struct Manifest: Sendable {
    var entries: [ManifestEntry]
    var readSources: Set<ClipSourceKind>
}

/// Serializes all clipboard database access off the main thread.
actor ClipStore {
    private let sources: [any ClipSource] = [PastebotDatabase(), AlfredDatabase()]
    private var lastDataVersions: [ClipSourceKind: Int] = [:]

    private static let maxTextBytes = 20_000_000

    /// Opens each database if needed and reports whether any has committed changes since the last call.
    func checkForChanges() -> (changed: Bool, statuses: [SourceStatus]) {
        var changed = false
        var statuses: [SourceStatus] = []
        for source in sources {
            let status: DatabaseStatus
            do {
                try source.open()
                let version = try source.dataVersion()
                let count = try source.entryCount()
                if version != lastDataVersions[source.kind] { changed = true }
                lastDataVersions[source.kind] = version
                status = .ok(count: count)
            } catch {
                // Reopen on the next check (e.g. the file was replaced or access was granted).
                source.close()
                if lastDataVersions.removeValue(forKey: source.kind) != nil { changed = true }
                status = switch error {
                case ClipDatabaseError.notFound: .notInstalled
                case ClipDatabaseError.accessDenied: .accessDenied
                default: .error(error.localizedDescription)
                }
            }
            statuses.append(SourceStatus(kind: source.kind, status: status))
        }
        return (changed, statuses)
    }

    func manifest() -> Manifest {
        var manifest = Manifest(entries: [], readSources: [])
        for source in sources {
            guard let entries = try? openSource(source).manifest() else { continue }
            manifest.entries += entries
            manifest.readSources.insert(source.kind)
        }
        return manifest
    }

    /// Everything needed to upload one clip, or nil if it no longer exists.
    func cloudClip(id: String) throws -> CloudClip? {
        try openSource(source(for: id)).cloudClip(id: id, maxTextBytes: Self.maxTextBytes)
    }

    /// Throws if an installed source can't be read, so callers can try again later.
    func imageClipIDs() throws -> [String] {
        try sources.flatMap { source -> [String] in
            do {
                return try openSource(source).imageClipIDs()
            } catch ClipDatabaseError.notFound {
                return []
            }
        }
    }

    private func source(for clipID: String) -> any ClipSource {
        let kind = ClipSourceKind.of(clipID: clipID)
        return sources.first { $0.kind == kind }!
    }

    private func openSource(_ source: any ClipSource) throws -> any ClipSource {
        try source.open()
        return source
    }
}
