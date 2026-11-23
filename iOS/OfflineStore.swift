import Foundation
import ImageIO
import UIKit

/// What's persisted between launches.
struct OfflineSnapshot: Codable {
    var clips: [Clip] = []
    var lastSynced: Date?
}

/// Keeps synced clips (JSON) and images (files) in Application Support so they work offline.
/// Excluded from iCloud backup — everything here can be re-downloaded.
actor OfflineStore {
    static let shared = OfflineStore()

    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("OfflineClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"),
                                                 withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    nonisolated static func imageURL(for id: String) -> URL {
        directory.appendingPathComponent("images/\(id).img")
    }

    /// Copies a downloaded CloudKit asset into place (synchronously — the source is temporary).
    nonisolated static func storeImage(from source: URL, id: String) {
        let destination = imageURL(for: id)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
        ImageLoader.invalidate(id: id)
    }

    nonisolated static func removeImage(id: String) {
        try? FileManager.default.removeItem(at: imageURL(for: id))
        ImageLoader.invalidate(id: id)
    }

    private var snapshotURL: URL { Self.directory.appendingPathComponent("clips.json") }

    func load() -> OfflineSnapshot {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder.bridge.decode(OfflineSnapshot.self, from: data)
        else { return OfflineSnapshot() }
        return snapshot
    }

    func save(_ snapshot: OfflineSnapshot) {
        do {
            let data = try JSONEncoder.bridge.encode(snapshot)
            try data.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            NSLog("Offline cache save failed: \(error)")
        }
    }

    /// Deletes image files for clips that no longer exist.
    func removeImages(keeping ids: Set<String>) {
        let dir = Self.directory.appendingPathComponent("images")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where !ids.contains((file as NSString).deletingPathExtension) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}

/// Loads clip images from the offline copy, downscaled and cached in memory.
enum ImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()
    private static let sizes = [180, 2048]

    static func image(id: String, maxPixel: Int) async -> UIImage? {
        let key = "\(id)-\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = OfflineStore.imageURL(for: id)
        let image = await Task.detached(priority: .userInitiated) { downsample(url, maxPixel: maxPixel) }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Full-resolution image for copying.
    static func fullImage(id: String) -> UIImage? {
        (try? Data(contentsOf: OfflineStore.imageURL(for: id))).flatMap(UIImage.init(data:))
    }

    static func invalidate(id: String) {
        for size in sizes { cache.removeObject(forKey: "\(id)-\(size)" as NSString) }
    }

    private static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}
