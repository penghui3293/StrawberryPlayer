import Foundation
import UIKit

enum SharePlatform {
    case weibo
    case qq
}

class ShareManager: NSObject {
    
    static let shared = ShareManager()
    
    private let weiboAppKey = "137160712"
    private let qqAppID = "1903885818"
    
    private var tencentOAuth: TencentOAuth?
    private var currentCompletion: ((Bool) -> Void)?
    
    override private init() {}
    
    // MARK: - 初始化（已在 AppDelegate 中调用）
    func setup() {
        TencentOAuth.setIsUserAgreedAuthorization(true)
        WeiboSDK.enableDebugMode(true)
        WeiboSDK.registerApp(weiboAppKey, universalLink: AppConfig.baseURL + "/")
        tencentOAuth = TencentOAuth(appId: qqAppID, andUniversalLink: AppConfig.baseURL + "/", andDelegate: self)
    }
    
    // MARK: - 分享入口（带安装检查）
    func share(to platform: SharePlatform,
               text: String,
               image: UIImage?,
               url: String?,
               completion: @escaping (Bool) -> Void) {
        
        currentCompletion = completion
        switch platform {
        case .weibo:
            shareToWeibo(text: text, image: image, url: url)
        case .qq:
            // ✅ 先检查 QQ 是否安装
            if !isQQInstalled() {
                showAlert(message: "请安装最新版手机QQ后再试")
                completion(false)
                return
            }
            shareToQQ(text: text, image: image, url: url)
        }
    }
    
    // MARK: - 检查 QQ 安装
    private func isQQInstalled() -> Bool {
        // 两种方式：URL Scheme 或 TencentOAuth 方法
        guard let qqURL = URL(string: "mqqapi://") else { return false }
        return UIApplication.shared.canOpenURL(qqURL)
    }
    
    // MARK: - 显示自定义提示（避免使用 SDK 内部 alert）
    private func showAlert(message: String) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) else { return }
            let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            window.rootViewController?.present(alert, animated: true)
        }
    }
    
    // MARK: - 微博分享
    private func shareToWeibo(text: String, image: UIImage?, url: String?) {
        let message = WBMessageObject()
        message.text = text
        
        if let img = image, let imgData = img.jpegData(compressionQuality: 0.8) {
            let imageObj = WBImageObject()
            imageObj.imageData = imgData
            message.imageObject = imageObj
        }
        
        if let link = url {
            let webObj = WBWebpageObject()
            webObj.webpageUrl = link
            webObj.objectID = UUID().uuidString
            webObj.title = text
            webObj.description = "快来看看这首歌"
            if let imgData = image?.jpegData(compressionQuality: 0.4) {
                webObj.thumbnailData = imgData
            }
            message.mediaObject = webObj
        }
        
        let request = WBSendMessageToWeiboRequest()
        request.message = message
        
        WeiboSDK.send(request) { [weak self] result in
            if !result {
                self?.currentCompletion?(false)
            }
        }
    }
    
    // MARK: - QQ 分享
    private func shareToQQ(text: String, image: UIImage?, url: String?) {
        guard let shareURL = URL(string: url ?? "") else {
            currentCompletion?(false)
            return
        }
        
        let previewData = image?.jpegData(compressionQuality: 0.4)
        let newsObj = QQApiNewsObject(
            url: shareURL,
            title: text,
            description: "快来听听这首歌",
            previewImageData: previewData,
            targetContentType: .news
        )
        let req = SendMessageToQQReq(content: newsObj)
        
        // ✅ 正确判断枚举值
        let sendResult = QQApiInterface.send(req)
        if sendResult != .EQQAPISENDSUCESS {
            print("❌ QQ 分享发送失败，错误码：\(sendResult.rawValue)")
            currentCompletion?(false)
        } else {
            print("✅ QQ 分享请求已发送，等待回调结果")
            // 等待 onResp 回调，不立即调用 completion
        }
    }
    
    // MARK: - QQ 分享
//    private func shareToQQ(text: String, image: UIImage?, url: String?) {
//        guard let shareURL = URL(string: url ?? "") else {
//            currentCompletion?(false)
//            return
//        }
//        
//        let previewData = image?.jpegData(compressionQuality: 0.4)
//        let newsObj = QQApiNewsObject(
//            url: shareURL,
//            title: text,
//            description: "快来听听这首歌",
//            previewImageData: previewData,
//            targetContentType: .news
//        )
//        let req = SendMessageToQQReq(content: newsObj)
//        
//        // ✅ 正确调用方式：直接发送，无 scene 参数
//        let sendResult = QQApiInterface.send(req)
//        
//        if sendResult != 0 {
//            print("❌ QQ 分享发送失败，错误码：\(sendResult)")
//            currentCompletion?(false)
//        } else {
//            print("✅ QQ 分享请求已发送，等待回调结果")
//            // 等待 onResp 回调，不立即调用 completion
//        }
//        
//        // ✅ 直接发送，SDK 会在代理中回调结果
//        //        QQApiInterface.send(req)
//    }
    
    // MARK: - 处理回调（AppDelegate 中调用）
    func handleOpenURL(_ url: URL) -> Bool {
        if WeiboSDK.handleOpen(url, delegate: self) {
            return true
        }
        if QQApiInterface.handleOpen(url, delegate: self) {
            return true
        }
        // TencentOAuth 回调可能需要单独处理，但通常 QQApiInterface 已覆盖
        if TencentOAuth.handleOpen(url) {
            return true
        }
        return false
    }
    func cleanupTencent() { tencentOAuth = nil }
    func cleanupWeibo() { /* 微博无显式注销 */ }
}

// MARK: - 微博代理
extension ShareManager: WeiboSDKDelegate {
    func didReceiveWeiboRequest(_ request: WBBaseRequest!) {}
    
    func didReceiveWeiboResponse(_ response: WBBaseResponse!) {
        if let sendResp = response as? WBSendMessageToWeiboResponse {
            let success = (sendResp.statusCode == .success)
            currentCompletion?(success)
        }
    }
}

// MARK: - QQ代理
extension ShareManager: QQApiInterfaceDelegate {
    func onReq(_ req: QQBaseReq!) {
        // 处理 QQ 发来的请求（如分享前查询应用信息）
        print("📨 QQ 发来请求: \(String(describing: req))")
    }
    
    func onResp(_ resp: QQBaseResp!) {
        if let sendResp = resp as? SendMessageToQQResp {
            let success = (sendResp.result == "0")
            print("📤 QQ 分享回调: result=\(sendResp.result ?? "nil"), errorDescription=\(sendResp.errorDescription ?? "nil")")
            currentCompletion?(success)
        }
    }
    
    func isOnlineResponse(_ response: [AnyHashable : Any]!) {}
}

// MARK: - TencentSessionDelegate（仅用于可能的登录回调，非必须）
extension ShareManager: TencentSessionDelegate {
    func tencentDidLogin() {}
    func tencentDidNotLogin(_ cancelled: Bool) {}
    func tencentDidNotNetWork() {}
}
