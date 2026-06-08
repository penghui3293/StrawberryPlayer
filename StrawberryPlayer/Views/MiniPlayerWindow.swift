import SwiftUI
import UIKit

// 定义通知名称（可以放在单独的文件，这里直接写在 MiniPlayerWindow 顶部）
extension Notification.Name {
    static let closeMiniPlayer = Notification.Name("closeMiniPlayer")
    static let switchToFullPlayer = Notification.Name("switchToFullPlayer")
}

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
        let playerWidth: CGFloat = 130
        let playerHeight: CGFloat = 70
        let trailingPadding: CGFloat = 16
        let bottomPadding: CGFloat = 200
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
        
        print("🪟 [MiniPlayerWindow] 状态 -> screenBounds: \(screenBounds), isHidden: \(isHidden), alpha: \(alpha), windowLevel: \(windowLevel.rawValue), rootVC: \(rootViewController != nil ? "存在" : "nil")")
    }
    
    override func makeKeyAndVisible() {
        self.isHidden = false
        print("🪟 [MiniPlayerWindow] makeKeyAndVisible 调用，isHidden 设为 false")
        
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
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrame()
    }
    
    // MARK: - UIKit 手势处理（解决 SwiftUI 触摸失效）
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let rootView = self.rootViewController?.view else { return }
        let location = gesture.location(in: rootView)
        
        // 关闭按钮的区域（根据 MiniPlayerView 布局：右侧 40x40 区域）
        let closeButtonRect = CGRect(
            x: rootView.bounds.width - 40 - 8,
            y: 0,
            width: 40,
            height: rootView.bounds.height
        )
        
        if closeButtonRect.contains(location) {
            // 点击关闭按钮
            print("❌ [MiniPlayerWindow] 手势检测到关闭按钮点击")
            NotificationCenter.default.post(name: .closeMiniPlayer, object: nil)
        } else {
            // 点击其他区域（封面或空白）→ 切换到全屏
            print("🎵 [MiniPlayerWindow] 手势检测到点击其他区域，切换到全屏")
            NotificationCenter.default.post(name: .switchToFullPlayer, object: nil)
        }
    }
    
    static func configure(with contentView: some View) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        shared.windowScene = windowScene
        
        let hostingController = UIHostingController(rootView: AnyView(contentView))
        hostingController.view.backgroundColor = .clear
        hostingController.view.isUserInteractionEnabled = true
        
        shared.rootViewController = hostingController
        shared.updateFrame()
        
        // 移除已有的手势避免重复添加
        hostingController.view.gestureRecognizers?.forEach { hostingController.view.removeGestureRecognizer($0) }
        
        let tapGesture = UITapGestureRecognizer(target: shared, action: #selector(shared.handleTap(_:)))
        hostingController.view.addGestureRecognizer(tapGesture)
        print("✅ [MiniPlayerWindow] 手势识别器已添加，手势个数: \(hostingController.view.gestureRecognizers?.count ?? 0)")
        
        shared.isHidden = true
    }
    
}
