
import Foundation
import Security

struct TestDataCleaner {
    static func clearUserDefaults() -> String {
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
        return "UserDefaults 已清空"
    }
    
    static func clearKeychain() -> String {
        let secClasses: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]
        for secClass in secClasses {
            let query: [String: Any] = [
                kSecClass as String: secClass,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            SecItemDelete(query as CFDictionary)
        }
        return "钥匙串已清空"
    }
    
    static func clearLocalFiles() -> String {
        let fileManager = FileManager.default
        let urls = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
        var messages: [String] = []
        for url in urls {
            do {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for file in contents {
                    try fileManager.removeItem(at: file)
                }
                messages.append("已清空目录: \(url.path)")
            } catch {
                messages.append("清空失败 \(url.path): \(error)")
            }
        }
        return messages.joined(separator: "\n")
    }
    
    @discardableResult
    static func performCleanup() -> String {
        var messages: [String] = []
        messages.append(clearUserDefaults())
        messages.append(clearKeychain())
        messages.append(clearLocalFiles())
        return messages.joined(separator: "\n")
    }
}
