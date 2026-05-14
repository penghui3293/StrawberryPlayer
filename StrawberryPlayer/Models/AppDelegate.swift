import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // ✅ 彻底禁用磁盘缓存，避免 SQLite 损坏导致内存泄漏
        let cache = URLCache(memoryCapacity: 20 * 1024 * 1024,
                             diskCapacity: 0,
                             diskPath: nil)
        URLCache.shared = cache
        
        // ✅ 主动删除可能已经损坏的旧缓存文件夹
        removeLegacyCacheDirectories()
        
        ShareManager.shared.setup()
        
        return true
    }
    
    
    // 处理 Universal Link（点击 HTTPS 链接唤起 App）
    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            return false
        }
        
        print("🔗 [Universal Link] 收到链接: \(url.absoluteString)")
        // 将完整的 URL 通过通知发送给 PlaybackService，由其统一解析
        NotificationCenter.default.post(name: .handleIncomingURL, object: url)
        return true
    }
    
    
    /// 清理所有可能的 URL 缓存残留目录
    private func removeLegacyCacheDirectories() {
        let fileManager = FileManager.default
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let contents = (try? fileManager.contentsOfDirectory(at: cachesDir,
                                                             includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            if url.lastPathComponent.hasPrefix("com.apple.nsurlsessiond") ||
                url.lastPathComponent.contains("Ur lCache") ||
                url.lastPathComponent.contains("strawberry_cache") {
                try? fileManager.removeItem(at: url)
                print("🧹 已移除损坏的缓存目录: \(url.lastPathComponent)")
            }
        }
    }
    
    
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        // 先交给分享 SDK
        if ShareManager.shared.handleOpenURL(url) {
            return true
        }
        
        // ✅ 处理自己的 scheme
        if url.scheme == "strawberryplayer" {
            print("🔗 AppDelegate 收到 scheme: \(url)")
            NotificationCenter.default.post(name: .handleIncomingURL, object: url)
            return true
        }
        return false
    }
}
