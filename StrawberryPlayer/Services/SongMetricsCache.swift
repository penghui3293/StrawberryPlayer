import Foundation

//管理所有歌曲的三个计数
class SongMetricsCache {
    static let shared = SongMetricsCache()
    private var cache: [String: (likes: Int, comments: Int, shares: Int, timestamp: Date)] = [:]
    private let cacheDuration: TimeInterval = 300 // 5分钟有效期
    
    func get(songId: String) -> (likes: Int, comments: Int, shares: Int)? {
        if let entry = cache[songId], Date().timeIntervalSince(entry.timestamp) < cacheDuration {
            return (entry.likes, entry.comments, entry.shares)
        }
        return nil
    }
    
    func set(songId: String, likes: Int? = nil, comments: Int? = nil, shares: Int? = nil) {
        var entry = cache[songId] ?? (0, 0, 0, Date())
        if let likes = likes { entry.likes = likes }
        if let comments = comments { entry.comments = comments }
        if let shares = shares { entry.shares = shares }
        entry.timestamp = Date()
        cache[songId] = entry
    }
    
    func clear() { cache.removeAll() }
}
