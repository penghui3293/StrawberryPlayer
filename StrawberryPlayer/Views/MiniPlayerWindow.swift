import SwiftUI
import UIKit

class MiniPlayerWindow: UIWindow {
    static let shared: MiniPlayerWindow = {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            fatalError("No window scene found")
        }
        return MiniPlayerWindow(windowScene: windowScene)
    }()
    
    private override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        self.windowLevel = .alert + 1
        self.backgroundColor = .clear
        self.isUserInteractionEnabled = true
        print("🪟 [MiniPlayerWindow] init 完成")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let rootView = rootViewController?.view else { return false }
        let localPoint = rootView.convert(point, from: self)
        let hitView = rootView.hitTest(localPoint, with: event)
        return hitView != nil && hitView != rootView
    }
    
    func updateFrame() {
        let screenBounds = UIScreen.main.bounds
        let playerWidth: CGFloat = 130   // 宽度适当增加
        let playerHeight: CGFloat = 70   // 高度适当增加
        let trailingPadding: CGFloat = 16
        let bottomPadding: CGFloat = 200 //
        let newFrame = CGRect(
            x: screenBounds.width - playerWidth - trailingPadding,
            y: screenBounds.height - playerHeight - bottomPadding,
            width: playerWidth,
            height: playerHeight
        )
        
        if frame != newFrame {
            frame = newFrame
            print("🪟 [MiniPlayerWindow] frame 已更新: \(frame)")
        }
        
        // 新增日志：输出关键状态
        print("🪟 [MiniPlayerWindow] 状态 -> screenBounds: \(screenBounds), isHidden: \(isHidden), alpha: \(alpha), windowLevel: \(windowLevel.rawValue), rootVC: \(rootViewController != nil ? "存在" : "nil")")
    }
    
    override func makeKeyAndVisible() {
        self.isHidden = false
        print("🪟 [MiniPlayerWindow] makeKeyAndVisible 调用，isHidden 设为 false")
        
        // 让主窗口重新成为 key window，避免迷你窗口抢占焦点导致音频中断
        if let mainWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.windowLevel == .normal && $0 != self }) {
            mainWindow.makeKeyAndVisible()
        }
    }
    
    override var isHidden: Bool {
        didSet {
            print("🪟 [MiniPlayerWindow] isHidden 变化: \(isHidden)")
            if isHidden {
                if let mainWindow = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap({ $0.windows })
                    .first(where: { $0.windowLevel == .normal && $0 != self }) {
                    mainWindow.makeKeyAndVisible()
                }
            }
        }
    }
    
    static func configure(with contentView: some View) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        shared.windowScene = windowScene
        
        let hostingController = UIHostingController(rootView: AnyView(contentView))
        hostingController.view.backgroundColor = .clear
        
        shared.rootViewController = hostingController
        print("🪟 [MiniPlayerWindow] configure: rootViewController 已设置")
        shared.updateFrame()
        shared.isHidden = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // 新增日志：每布局时输出
        print("🪟 [MiniPlayerWindow] layoutSubviews 触发")
        updateFrame()
    }
}
