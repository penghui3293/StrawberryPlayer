import Network
import UIKit

class LocalNetworkPermissionManager {
    static let shared = LocalNetworkPermissionManager()

    /// 主动触发系统本地网络权限弹窗，并返回用户是否授权
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(
                for: .bonjour(type: "_localNetwork._tcp", domain: nil),
                using: NWParameters()
            )
            var hasResumed = false

            browser.stateUpdateHandler = { state in
                // 统一在主线程处理，消除并发风险
                DispatchQueue.main.async {
                    guard !hasResumed else { return }
                    switch state {
                    case .ready:
                        hasResumed = true
                        browser.cancel()
                        continuation.resume(returning: true)
                    case .failed:
                        hasResumed = true
                        browser.cancel()
                        continuation.resume(returning: false)
                    default:
                        break
                    }
                }
            }
            browser.start(queue: .main)

            // 30 秒超时，视为未授权
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                guard !hasResumed else { return }
                hasResumed = true
                browser.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// 跳转到系统设置
    static func openLocalNetworkSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }
}
