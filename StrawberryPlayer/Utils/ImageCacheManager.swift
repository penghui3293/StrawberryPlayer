import UIKit

final class ImageCacheManager {
    static let shared = ImageCacheManager()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        // 严格限制：内存中最多放 50 张图，总大小不超过 50MB
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        return cache.object(forKey: url as NSURL)
    }

    func setImage(_ image: UIImage, for url: URL) {
        // 使用数据长度来估算内存成本
        let cost = image.jpegData(compressionQuality: 0.8)?.count ?? 0
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
