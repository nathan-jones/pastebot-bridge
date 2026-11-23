import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class BridgeController {
    private(set) var sources: [SourceStatus] = ClipSourceKind.allCases.map { SourceStatus(kind: $0, status: .unknown) }
    private(set) var cloudStatus = CloudStatus()
    private(set) var lastChange: Date?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let store = ClipStore()
    @ObservationIgnored private var uploader: CloudUploader!
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var fetchTimer: Timer?

    init() {
        uploader = CloudUploader(store: store) { [weak self] status in
            Task { @MainActor in self?.cloudStatus = status }
        }
        start()
    }

    // MARK: Actions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func retryCloud() {
        Task {
            await uploader.checkAccount()
            await uploader.reconcile()
        }
    }

    // MARK: Lifecycle

    private func start() {
        // FSEvents gives near-instant updates; the timer covers missed events and permission changes.
        let pastebotWatcher = DirectoryWatcher(
            directory: PastebotDatabase.defaultURL.deletingLastPathComponent(),
            matching: { $0.hasSuffix("/sql") || $0.hasSuffix("/sql-wal") },
            onChange: { [weak self] in MainActor.assumeIsolated { self?.checkDatabase() } }
        )
        let alfredWatcher = DirectoryWatcher(
            directory: AlfredDatabase.defaultURL.deletingLastPathComponent(),
            matching: { $0.contains("/clipboard.alfdb") },
            onChange: { [weak self] in MainActor.assumeIsolated { self?.checkDatabase() } }
        )
        watchers = [pastebotWatcher, alfredWatcher]
        watchers.forEach { $0.start() }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDatabase() }
        }
        // Pick up clips deleted on iPhone (the Mac app doesn't receive CloudKit pushes).
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let uploader = self?.uploader else { return }
            Task { await uploader.fetchNow() }
        }

        Task {
            await uploader.start()
            checkDatabase()
        }
    }

    private func checkDatabase() {
        Task {
            let result = await store.checkForChanges()
            if sources != result.statuses { sources = result.statuses }
            if result.changed {
                lastChange = Date()
                await uploader.reconcile()
            }
        }
    }
}
