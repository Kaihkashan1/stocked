import CryptoKit
import ImageIO
import UIKit

/// Memory + disk thumbnail cache. SwiftUI's AsyncImage re-downloads on every
/// cell recycle, which makes the list stutter as you scroll.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let folder: URL
    private let session: URLSession

    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 25 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        folder = caches.appendingPathComponent("RecipeThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func image(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = memory.object(forKey: url as NSURL) {
            return hit
        }

        let file = diskURL(for: url)
        if let data = try? Data(contentsOf: file),
           let image = Self.downsample(data, maxPixel: maxPixel)
        {
            remember(image, for: url)
            return image
        }

        do {
            let (data, _) = try await session.data(from: url)
            if let image = Self.downsample(data, maxPixel: maxPixel) {
                remember(image, for: url)
                try? data.write(to: file, options: .atomic)
                return image
            }
        } catch {
            return nil
        }
        return nil
    }

    private func remember(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
        memory.setObject(image, forKey: url as NSURL, cost: cost)
    }

    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.compactMap { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let size = max(maxPixel, 64)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
