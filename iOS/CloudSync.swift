import CloudKit
import Foundation

/// Pulls clips from the private CloudKit database into the offline copy. Read-only: never uploads.
///
/// CKSyncEngine tracks change tokens, subscribes to pushes, and fetches automatically; this class
/// turns fetched records into `Clip`s and hands them to `ClipsModel`.
actor CloudSync: CKSyncEngineDelegate {
    static let shared = CloudSync()

    private let container = CKContainer(identifier: CloudSchema.containerID)
    private var engine: CKSyncEngine?
    private var startTask: Task<Void, Never>?

    private var stateURL: URL { OfflineStore.directory.appendingPathComponent("syncstate.json") }

    /// Idempotent; safe to call from app launch, background pushes and views.
    func start() async {
        if startTask == nil { startTask = Task { await self.startEngine() } }
        await startTask?.value
    }

    /// Bump when the app moves to a different CloudKit environment; the old sync state and local copy
    /// belong to the previous environment's data.
    private static let environment = "production"

    private func startEngine() async {
        await refreshAccountStatus()
        if UserDefaults.standard.string(forKey: "cloudEnvironment") != Self.environment {
            try? FileManager.default.removeItem(at: stateURL)   // no state → local copy is rebuilt below
            UserDefaults.standard.set(Self.environment, forKey: "cloudEnvironment")
        }
        var state = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        await ClipsModel.shared.loadCache()
        if state != nil, await ClipsModel.shared.allClips.isEmpty {
            // A change token with nothing stored locally means an early fetch saw an empty database
            // (e.g. before the zone was visible) and later fetches only ask for changes since then.
            // Starting over is cheap when there's nothing to keep.
            state = nil
            try? FileManager.default.removeItem(at: stateURL)
        }
        if state == nil {
            // First sync (or a reset): rebuild the local copy entirely from iCloud.
            await ClipsModel.shared.clearLocal()
        }
        engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: state, delegate: self))
    }

    /// Fetches now (pull to refresh, foregrounding, background push).
    func fetchNow() async {
        await start()
        guard let engine else { return }
        await ClipsModel.shared.setSyncing(true)
        do {
            try await engine.fetchChanges()
            await ClipsModel.shared.didFetch(error: nil)
        } catch {
            await ClipsModel.shared.didFetch(error: Self.describe(error))
        }
        await refreshAccountStatus()
    }

    /// Throws away the local copy and sync state, then downloads everything again.
    func redownloadEverything() async {
        await start()
        engine = nil
        try? FileManager.default.removeItem(at: stateURL)
        startTask = nil
        await start()
        await fetchNow()
    }

    private func refreshAccountStatus() async {
        let problem: String?
        do {
            problem = switch try await container.accountStatus() {
            case .available: nil
            case .noAccount: "Sign in to iCloud with the same Apple Account as your Mac."
            case .restricted: "iCloud is restricted on this device."
            case .temporarilyUnavailable: "iCloud is temporarily unavailable."
            default: "Couldn't determine iCloud status."
            }
        } catch {
            problem = Self.describe(error)
        }
        await ClipsModel.shared.setAccountProblem(problem)
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signOut, .switchAccounts:
                await ClipsModel.shared.clearLocal()
            default:
                break
            }
            await refreshAccountStatus()

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudSchema.zoneID }) {
                await ClipsModel.shared.clearLocal()
            }

        case .fetchedRecordZoneChanges(let changes):
            // Asset files are temporary: copy images out before returning.
            var upserts: [Clip] = []
            var deletions = changes.deletions.map(\.recordID.recordName)
            for modification in changes.modifications {
                let record = modification.record
                // Deleted on another device.
                if let deletedID = CloudSchema.clipID(fromTombstone: record.recordID) {
                    deletions.append(deletedID)
                    continue
                }
                guard let clip = CloudSchema.clip(from: record) else { continue }
                if let url = (record[CloudSchema.Field.image] as? CKAsset)?.fileURL {
                    OfflineStore.storeImage(from: url, id: clip.id)
                } else {
                    OfflineStore.removeImage(id: clip.id)
                }
                upserts.append(clip)
            }
            let deletedSet = Set(deletions)
            await ClipsModel.shared.apply(upserts: upserts.filter { !deletedSet.contains($0.id) },
                                          deletions: deletions)

        case .willFetchChanges:
            await ClipsModel.shared.setSyncing(true)

        case .didFetchChanges:
            await ClipsModel.shared.didFetch(error: nil)

        default:
            break
        }
    }

    /// The only thing iOS writes: deletions. Each one removes the Clip record (all devices) and saves a
    /// tombstone so the Mac stops uploading that clip. Queued in the engine, so it works offline.
    func delete(_ ids: [String]) async {
        await ClipsModel.shared.apply(upserts: [], deletions: ids)
        await start()
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: ids.flatMap { id -> [CKSyncEngine.PendingRecordZoneChange] in
            [.saveRecord(CloudSchema.tombstoneID(for: id)), .deleteRecord(CloudSchema.recordID(for: id))]
        })
        try? await engine.sendChanges()
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard CloudSchema.clipID(fromTombstone: recordID) != nil else {
                // iOS never uploads clips themselves.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let tombstone = CKRecord(recordType: CloudSchema.tombstoneRecordType, recordID: recordID)
            tombstone[CloudSchema.tombstoneDeletedAt] = Date()
            return tombstone
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        return switch ckError.code {
        case .networkUnavailable, .networkFailure: "You're offline."
        case .notAuthenticated: "Sign in to iCloud to sync clips."
        case .quotaExceeded: "iCloud storage is full."
        default: ckError.localizedDescription
        }
    }
}
