import Foundation
import Observation

/// The offline copy of the Mac's clipboard history, kept current by `CloudSync`.
/// The UI always reads from here; search and filters run on-device.
@MainActor @Observable
final class ClipsModel {
    static let shared = ClipsModel()

    private(set) var allClips: [Clip] = []
    private(set) var lastSynced: Date?
    private(set) var hasLoadedCache = false
    private(set) var isSyncing = false
    /// Nil when iCloud is usable; otherwise why it isn't.
    private(set) var accountProblem: String?
    private(set) var errorMessage: String?

    var search = ""
    var kindFilter: ClipKind? {
        didSet { UserDefaults.standard.set(kindFilter?.rawValue, forKey: "filter.kind") }
    }
    /// Bundle identifier of the source app to show, or nil for all apps.
    var sourceFilter: String? {
        didSet { UserDefaults.standard.set(sourceFilter, forKey: "filter.source") }
    }

    @ObservationIgnored private let store = OfflineStore.shared

    private init() {
        kindFilter = UserDefaults.standard.string(forKey: "filter.kind").flatMap(ClipKind.init(rawValue:))
        sourceFilter = UserDefaults.standard.string(forKey: "filter.source")
    }

    // MARK: Derived

    var items: [Clip] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allClips.filter { clip in
            (kindFilter == nil || clip.kind == kindFilter)
                && (sourceFilter == nil || clip.sourceBundleID == sourceFilter)
                && (query.isEmpty
                    || clip.text?.localizedCaseInsensitiveContains(query) == true
                    || clip.sourceName?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var sources: [SourceApp] {
        Dictionary(grouping: allClips.filter { $0.sourceBundleID != nil }, by: { $0.sourceBundleID! })
            .map { SourceApp(bundleID: $0.key, name: $0.value.first?.sourceName ?? $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var isFiltered: Bool { kindFilter != nil || sourceFilter != nil }

    var sourceFilterName: String? {
        guard let sourceFilter else { return nil }
        return allClips.first { $0.sourceBundleID == sourceFilter }?.sourceName ?? sourceFilter
    }

    func clip(id: Clip.ID) -> Clip? {
        allClips.first { $0.id == id }
    }

    func clearFilters() {
        kindFilter = nil
        sourceFilter = nil
    }

    // MARK: Updates from CloudSync

    func loadCache() async {
        guard !hasLoadedCache else { return }
        let snapshot = await store.load()
        allClips = snapshot.clips
        lastSynced = snapshot.lastSynced
        hasLoadedCache = true
    }

    func clearLocal() async {
        allClips = []
        lastSynced = nil
        hasLoadedCache = true
        await store.removeImages(keeping: [])
        await persist()
    }

    func apply(upserts: [Clip], deletions: [String]) async {
        await loadCache()
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        var byID = Dictionary(allClips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in deletions {
            byID[id] = nil
            OfflineStore.removeImage(id: id)
        }
        for clip in upserts { byID[clip.id] = clip }
        allClips = byID.values.sorted { $0.createdAt > $1.createdAt }
        await persist()
    }

    func setSyncing(_ syncing: Bool) {
        isSyncing = syncing
    }

    func didFetch(error: String?) async {
        isSyncing = false
        errorMessage = error
        if error == nil && accountProblem == nil {
            lastSynced = Date()
            await persist()
        }
    }

    func setAccountProblem(_ problem: String?) {
        accountProblem = problem
    }

    private func persist() async {
        await store.save(OfflineSnapshot(clips: allClips, lastSynced: lastSynced))
    }
}
