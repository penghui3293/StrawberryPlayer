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
    
    // MARK: - 分享入口
    func share(to platform: SharePlatform,
               text: String,
               image: UIImage?,
               url: String?,
               completion: @escaping (Bool) -> Void) {
        
        currentCompletion = completion
        switch platform {
        case .weibo: shareToWeibo(text: text, image: image, url: url)
        case .qq:    shareToQQ(text: text, image: image, url: url)
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
        
        // ✅ 直接发送，SDK 会在代理中回调结果
        QQApiInterface.send(req)
    }
    
    // MARK: - 回调处理
    func handleOpenURL(_ url: URL) -> Bool {
        if WeiboSDK.handleOpen(url, delegate: self) { return true }
        if QQApiInterface.handleOpen(url, delegate: self) { return true }
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
    func onReq(_ req: QQBaseReq!) {}
    
    func onResp(_ resp: QQBaseResp!) {
        if let sendResp = resp as? SendMessageToQQResp {
            let success = (sendResp.result == "0")
            currentCompletion?(success)
        }
    }
    
    func isOnlineResponse(_ response: [AnyHashable : Any]!) {}
}

// 👇 新增这一块
extension ShareManager: TencentSessionDelegate {
    func tencentDidLogin() {}
    func tencentDidNotLogin(_ cancelled: Bool) {}
    func tencentDidNotNetWork() {}
}
