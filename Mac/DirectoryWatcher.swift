import CoreServices
import Foundation

/// FSEvents watcher for a directory. Calls `onChange` on the main queue when a matching file changes.
final class DirectoryWatcher {
    private let directory: URL
    private let latency: TimeInterval
    private let matches: (String) -> Bool
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(directory: URL, latency: TimeInterval = 0.25,
         matching matches: @escaping (String) -> Bool, onChange: @escaping () -> Void) {
        self.directory = directory
        self.latency = latency
        self.matches = matches
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if changed.contains(where: watcher.matches) { watcher.onChange() }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(nil, callback, &context, [directory.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
