import Foundation

struct AppConfig {
    static var baseURL: String {
        if let saved = UserDefaults.standard.string(forKey: "serverBaseURL"), !saved.isEmpty {
            return saved
        }
        return "https://caomei.pro"
    }
}

extension URL {
    /// 自动将 HTTP 的 caomei.pro 地址转为 HTTPS，并去掉 :8080 端口
    static func secure(_ string: String) -> URL? {
        var str = string
        if str.hasPrefix("https://") {
            return URL(string: str)
        }
        if str.contains("caomei.pro") {
            str = str.replacingOccurrences(of: "http://", with: "https://")
            str = str.replacingOccurrences(of: ":8080", with: "")
            return URL(string: str)
        }
        return URL(string: str)
    }
}
