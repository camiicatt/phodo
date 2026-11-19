import SwiftUI
import UIKit

/// Keeps photos on the phone so they show instantly after the first time.
///
/// Photo links are temporary (they expire after an hour), so a new link for the
/// same photo looks like a new file. We cache by the link's *path* instead
/// (".../posts/<user>/<photo>-thumb.jpg"), which never changes for a photo.
///
/// Two layers: memory (instant, cleared when iOS needs room) and a small disk
/// folder in Caches (survives relaunches; iOS may clear it when space is low).
actor ImageCache {
    static let shared = ImageCache()

    /// Memory layer, readable without waiting (so cached photos never flash).
    nonisolated(unsafe) private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024        // ~120 MB of decoded pixels
        return c
    }()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let folder: URL
    private var trimmed = false
    private static let diskLimit = 250 * 1024 * 1024   // bytes on disk before old photos are cleared

    init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phodo-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The part of a link that stays the same for a photo (no expiring token).
    nonisolated static func key(for url: URL) -> String {
        url.isFileURL ? url.path : (url.host ?? "") + url.path
    }

    /// Already in memory? (No waiting — used so cached photos appear on the first frame.)
    nonisolated static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: key(for: url) as NSString)
    }

    /// Memory → disk → download. Two requests for the same photo share one download.
    func image(for url: URL) async -> UIImage? {
        let key = Self.key(for: url)
        if let hit = Self.memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let file = folder.appendingPathComponent(Self.fileName(key))
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: file), let img = Self.decode(data) { return img }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = Self.decode(data) else { return nil }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img { Self.memory.setObject(img, forKey: key as NSString, cost: Self.cost(img)) }
        trimIfNeeded()
        return img
    }

    /// Start downloading these in the background (feed thumbnails), so they're
    /// ready before you scroll to them.
    func prefetch(_ urls: [URL]) {
        for url in urls where Self.memory.object(forKey: Self.key(for: url) as NSString) == nil {
            Task { _ = await image(for: url) }
        }
    }

    // MARK: helpers

    /// Decode now (off the main thread) so scrolling doesn't stutter.
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        UIImage(data: data)?.preparingForDisplay()
    }

    private nonisolated static func cost(_ img: UIImage) -> Int {
        Int(img.size.width * img.scale * img.size.height * img.scale * 4)
    }

    /// A safe file name for a key.
    private nonisolated static func fileName(_ key: String) -> String {
        key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
            .suffix(180) + ".img"
    }

    /// Once per launch: if the folder got big, delete the oldest photos.
    private func trimIfNeeded() {
        guard !trimmed else { return }
        trimmed = true
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let info = files.compactMap { f -> (URL, Int, Date)? in
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { return nil }
            return (f, v.fileSize ?? 0, v.contentAccessDate ?? .distantPast)
        }
        var total = info.reduce(0) { $0 + $1.1 }
        for (file, size, _) in info.sorted(by: { $0.2 < $1.2 }) where total > Self.diskLimit {
            try? fm.removeItem(at: file)
            total -= size
        }
    }
}

/// Shows a photo from the cache, fading in over whatever's behind it the first
/// time it downloads. Cached photos appear immediately with no fade.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var fromNetwork = false

    init(url: URL?, contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping () -> Placeholder = { Color.clear }) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
        _image = State(initialValue: ImageCache.cached(url))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity.animation(.easeOut(duration: fromNetwork ? 0.25 : 0)))
            } else {
                placeholder()
            }
        }
        .task(id: url.map(ImageCache.key(for:))) {
            guard let url else { image = nil; return }
            if let hit = ImageCache.cached(url) { image = hit; return }
            let loaded = await ImageCache.shared.image(for: url)
            fromNetwork = true
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}
