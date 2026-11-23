import CloudKit
import Foundation

struct CloudStatus: Equatable, Sendable {
    /// Nil when iCloud is available; otherwise why it isn't.
    var accountProblem: String?
    var started = false
    var pending = 0
    var uploaded = 0
    /// Clips deleted on iPhone that stay in Pastebot but are no longer uploaded.
    var deletedOnPhone = 0
    var lastUpload: Date?
    var error: String?
}

/// One-way mirror of Pastebot's history into the user's private CloudKit database.
///
/// Pastebot is the source of truth. `reconcile()` diffs it against `uploaded` (what iCloud holds,
/// persisted locally) and queues saves/deletes; CKSyncEngine batches, schedules and retries them.
actor CloudUploader: CKSyncEngineDelegate {
    private let store: ClipStore
    private let onStatus: @Sendable (CloudStatus) -> Void
    private let container = CKContainer(identifier: CloudSchema.containerID)
    private var engine: CKSyncEngine?
    private var startTask: Task<Void, Never>?

    /// clip id → Pastebot version currently in iCloud.
    private var uploaded: [String: Int]
    /// Clips deleted from iPhone (via tombstone records). Never uploaded while they remain in Pastebot.
    private var excluded: Set<String>
    /// Server copies of records that failed with serverRecordChanged; used as the base for the retry.
    private var serverRecords: [String: CKRecord] = [:]
    private var status = CloudStatus()
    private var isSending = false

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dev.pastebotbridge.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        return dir
    }()
    /// Must match the `com.apple.developer.icloud-container-environment` entitlement.
    private static let environment = "production"
    private static let stateURL = directory.appendingPathComponent("syncstate.json")
    private static let uploadedURL = directory.appendingPathComponent("uploaded.json")
    private static let excludedURL = directory.appendingPathComponent("excluded.json")

    init(store: ClipStore, onStatus: @escaping @Sendable (CloudStatus) -> Void) {
        self.store = store
        self.onStatus = onStatus
        uploaded = (try? Data(contentsOf: Self.uploadedURL))
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        excluded = (try? Data(contentsOf: Self.excludedURL))
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    // MARK: Lifecycle

    func start() async {
        if startTask == nil { startTask = Task { await self.startEngine() } }
        await startTask?.value
    }

    private func startEngine() async {
        guard await checkAccount() else {
            startTask = nil   // allow retrying later
            return
        }
        // Moving to another CloudKit environment: its data is separate, so upload everything again.
        // `excluded` (clips deleted on iPhone) is kept so they stay out.
        if UserDefaults.standard.string(forKey: "cloudEnvironment") != Self.environment {
            try? FileManager.default.removeItem(at: Self.stateURL)
            UserDefaults.standard.set(Self.environment, forKey: "cloudEnvironment")
        }
        let state = (try? Data(contentsOf: Self.stateURL))
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        if state == nil {
            // No engine state means we can't trust `uploaded`; re-upload everything (saves are idempotent).
            uploaded = [:]
            saveUploaded()
        }
        let engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: state, delegate: self))
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
        self.engine = engine
        status.started = true
        if state == nil {
            // Learn about clips deleted on iPhone before re-uploading anything.
            try? await engine.fetchChanges()
        }
        await migrateContent(engine)
        await reconcile()
    }

    /// Bumped when the uploaded representation changes, so existing records get re-sent.
    /// 2: images are uploaded at full resolution (previously downscaled to 2048 px).
    private static let contentRevision = 2
    private static let contentRevisionKey = "contentRevision"

    private func migrateContent(_ engine: CKSyncEngine) async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.contentRevisionKey) < Self.contentRevision,
              let imageIDs = try? await store.imageClipIDs() else { return }
        let resend = imageIDs.filter { uploaded[$0] != nil && !excluded.contains($0) }
        if !resend.isEmpty {
            engine.state.add(pendingRecordZoneChanges: resend.map { .saveRecord(CloudSchema.recordID(for: $0)) })
        }
        defaults.set(Self.contentRevision, forKey: Self.contentRevisionKey)
    }

    /// Checks iCloud for deletions made on iPhone. Called periodically; the Mac doesn't get pushes.
    func fetchNow() async {
        guard let engine else { return }
        try? await engine.fetchChanges()
    }

    /// Re-checks the iCloud account; returns whether it's usable.
    @discardableResult
    func checkAccount() async -> Bool {
        let problem: String?
        do {
            problem = switch try await container.accountStatus() {
            case .available: nil
            case .noAccount: "Sign in to iCloud in System Settings."
            case .restricted: "iCloud is restricted on this Mac."
            case .temporarilyUnavailable: "iCloud is temporarily unavailable."
            default: "Couldn't determine iCloud status."
            }
        } catch {
            problem = error.localizedDescription
        }
        status.accountProblem = problem
        report()
        return problem == nil
    }

    /// Queues uploads for new/edited clips and deletes for removed ones.
    func reconcile() async {
        guard let engine else {
            await start()
            return
        }
        let manifest = await store.manifest()
        guard !manifest.readSources.isEmpty else { return }
        let current = Dictionary(manifest.entries.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let pendingIDs = Set(engine.state.pendingRecordZoneChanges.map(\.recordName))
        // Only treat a clip as gone if its source was read; an unreadable database isn't an empty one.
        func isGone(_ id: String) -> Bool {
            current[id] == nil && manifest.readSources.contains(ClipSourceKind.of(clipID: id))
        }

        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for entry in manifest.entries where !excluded.contains(entry.id)
            && uploaded[entry.id] != entry.version && !pendingIDs.contains(entry.id) {
            changes.append(.saveRecord(CloudSchema.recordID(for: entry.id)))
        }
        for id in uploaded.keys where (isGone(id) || excluded.contains(id)) && !pendingIDs.contains(id) {
            changes.append(.deleteRecord(CloudSchema.recordID(for: id)))
        }
        // Once a phone-deleted clip is gone from the Mac's history too, its tombstone is no longer needed.
        for id in excluded where isGone(id) {
            let tombstone = CloudSchema.tombstoneID(for: id)
            if !pendingIDs.contains(tombstone.recordName) { changes.append(.deleteRecord(tombstone)) }
        }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
        report()
        if !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty {
            await sendNow()
        }
    }

    /// Sends queued changes immediately rather than waiting for the engine's scheduler,
    /// which can hold off for a long time in a background (menu bar) app.
    ///
    /// Keeps sending while the queue shrinks, so saves re-queued after a conflict (e.g. "record already
    /// exists" when an earlier upload committed but its reply was lost) go out straight away.
    private func sendNow() async {
        guard let engine, !isSending else { return }
        isSending = true
        defer { isSending = false }
        var lastPending = Int.max
        while true {
            let pending = engine.state.pendingRecordZoneChanges.count + engine.state.pendingDatabaseChanges.count
            guard pending > 0, pending < lastPending else { break }
            lastPending = pending
            do {
                try await engine.sendChanges()
                status.error = nil
            } catch let error as CKError where error.code == .partialFailure {
                // Per-record failures were handled in `handleSent` (conflicts re-queued); try again.
                NSLog("CloudUploader partial failure; \(engine.state.pendingRecordZoneChanges.count) still pending")
            } catch {
                NSLog("CloudUploader send failed: \(error)")
                status.error = (error as? CKError)?.code == .networkUnavailable ? nil : error.localizedDescription
                break
            }
        }
        report()
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? data.write(to: Self.stateURL, options: .atomic)
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                await reconcile()
            case .signOut, .switchAccounts:
                uploaded = [:]
                saveUploaded()
            @unknown default:
                break
            }
            await checkAccount()

        case .fetchedDatabaseChanges(let changes):
            // Zone deleted (e.g. iCloud data cleared in Settings): upload everything again.
            if changes.deletions.contains(where: { $0.zoneID == CloudSchema.zoneID }) {
                uploaded = [:]
                saveUploaded()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
                await reconcile()
            }

        case .fetchedRecordZoneChanges(let changes):
            handleFetched(changes, syncEngine: syncEngine)

        case .sentRecordZoneChanges(let sent):
            handleSent(sent, syncEngine: syncEngine)

        case .didSendChanges:
            status.lastUpload = Date()
            report()

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.record(for: recordID, syncEngine: syncEngine)
        }
    }

    // MARK: Records

    private func record(for recordID: CKRecord.ID, syncEngine: CKSyncEngine) async -> CKRecord? {
        let id = recordID.recordName
        if excluded.contains(id) {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        let cloudClip: CloudClip?
        do {
            cloudClip = try await store.cloudClip(id: id)
        } catch {
            // Database unreadable right now: keep the save queued and try again later.
            NSLog("CloudUploader couldn't read \(id): \(error)")
            return nil
        }
        guard let cloudClip else {
            // Deleted from the Mac's history before it was sent: drop the save, delete it from iCloud if it got there.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            if uploaded[id] != nil { syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)]) }
            return nil
        }

        var imageFile: URL?
        if let image = cloudClip.image {
            let url = Self.assetURL(id, "img")
            if (try? image.write(to: url, options: .atomic)) != nil { imageFile = url }
        }
        var textFile: URL?
        if let text = cloudClip.clip.text, text.utf8.count > CloudSchema.inlineTextLimit {
            let url = Self.assetURL(id, "txt")
            if (try? Data(text.utf8).write(to: url, options: .atomic)) != nil { textFile = url }
        }

        let record = serverRecords[id] ?? CKRecord(recordType: CloudSchema.recordType, recordID: recordID)
        CloudSchema.fill(record, with: cloudClip.clip, version: cloudClip.version, imageFile: imageFile, textFile: textFile)
        return record
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) {
        for record in sent.savedRecords {
            let id = record.recordID.recordName
            uploaded[id] = record[CloudSchema.Field.version] as? Int
            serverRecords[id] = nil
            Self.removeAssets(id)
        }
        for recordID in sent.deletedRecordIDs {
            if let clipID = CloudSchema.clipID(fromTombstone: recordID) {
                excluded.remove(clipID)
                continue
            }
            uploaded[recordID.recordName] = nil
            Self.removeAssets(recordID.recordName)
        }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var lastError: String?
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            NSLog("CloudUploader save failed \(recordID.recordName): \(failure.error)")
            switch failure.error.code {
            case .serverRecordChanged:
                // Exists in iCloud already (edited clip, or local state was reset): overwrite it.
                serverRecords[recordID.recordName] = failure.error.serverRecord
                retry.append(.saveRecord(recordID))
            case .zoneNotFound:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID))])
                retry.append(.saveRecord(recordID))
            case .unknownItem:
                serverRecords[recordID.recordName] = nil
                retry.append(.saveRecord(recordID))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .operationCancelled, .requestRateLimited:
                break   // CKSyncEngine retries these itself
            case .quotaExceeded:
                lastError = "iCloud storage is full."
            default:
                lastError = failure.error.localizedDescription
            }
        }
        for (recordID, error) in sent.failedRecordDeletes where error.code == .unknownItem {
            // Already gone.
            if let clipID = CloudSchema.clipID(fromTombstone: recordID) {
                excluded.remove(clipID)
            } else {
                uploaded[recordID.recordName] = nil
            }
        }
        if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
        status.error = lastError
        saveUploaded()
        saveExcluded()
        report()
    }

    /// Applies deletions made on iPhone: tombstones exclude clips; deleted Clip records leave `uploaded`.
    private func handleFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, syncEngine: CKSyncEngine) {
        guard !changes.modifications.isEmpty || !changes.deletions.isEmpty else { return }
        for modification in changes.modifications {
            guard let clipID = CloudSchema.clipID(fromTombstone: modification.record.recordID) else { continue }
            excluded.insert(clipID)
            let recordID = CloudSchema.recordID(for: clipID)
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            // If it was (re)uploaded before we saw the tombstone, remove it again.
            if uploaded[clipID] != nil { syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)]) }
        }
        for deletion in changes.deletions {
            if let clipID = CloudSchema.clipID(fromTombstone: deletion.recordID) {
                excluded.remove(clipID)
            } else if deletion.recordType == CloudSchema.recordType {
                uploaded[deletion.recordID.recordName] = nil
            }
        }
        saveUploaded()
        saveExcluded()
        report()
    }

    // MARK: Helpers

    private func report() {
        status.pending = engine?.state.pendingRecordZoneChanges.count ?? 0
        status.uploaded = uploaded.count
        status.deletedOnPhone = excluded.count
        onStatus(status)
    }

    private func saveUploaded() {
        if let data = try? JSONEncoder().encode(uploaded) {
            try? data.write(to: Self.uploadedURL, options: .atomic)
        }
    }

    private func saveExcluded() {
        if let data = try? JSONEncoder().encode(excluded) {
            try? data.write(to: Self.excludedURL, options: .atomic)
        }
    }

    private static func assetURL(_ id: String, _ ext: String) -> URL {
        directory.appendingPathComponent("Assets/\(id).\(ext)")
    }

    private static func removeAssets(_ id: String) {
        try? FileManager.default.removeItem(at: assetURL(id, "img"))
        try? FileManager.default.removeItem(at: assetURL(id, "txt"))
    }
}

extension CKSyncEngine.PendingRecordZoneChange {
    var recordName: String {
        switch self {
        case .saveRecord(let id), .deleteRecord(let id): id.recordName
        @unknown default: ""
        }
    }
}
