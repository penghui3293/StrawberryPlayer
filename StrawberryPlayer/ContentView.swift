import SwiftUI
import UIKit
import Network

struct ContentView: View {
    @StateObject private var userService = UserService()
    @StateObject private var libraryService = LibraryService()
    @StateObject private var playbackService = PlaybackService()
    @StateObject private var lyricsService = LyricsService()
    @StateObject private var virtualArtistService = VirtualArtistService()
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared

    @State private var isTabBarHidden = false
    @EnvironmentObject var tabSelection: TabSelection
    @State private var isLoginPresented = false
    @Environment(\.scenePhase) var scenePhase
    
    @State private var isCheckingNetworkPermission = true
    @State private var isNetworkPermissionGranted = false
    
    // 在 ContentView 中添加状态变量
    @State private var isPresentingFullPlayer = false
        
    
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        ZStack {
            if isCheckingNetworkPermission {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在准备您的专属体验…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            } else if !isNetworkPermissionGranted {
                VStack(spacing: 20) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("需要访问本地网络")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("为了发现并连接您设备上的服务，StrawberryPlayer 需要访问您的本地网络。")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 40)
                    HStack(spacing: 20) {
                        Button("重试") {
                            isCheckingNetworkPermission = true
                            checkNetworkPermission()
                        }
                        .buttonStyle(.bordered)
                        Button("前往设置") {
                            LocalNetworkPermissionManager.openLocalNetworkSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
            } else if userService.isLoggedIn {
                mainTabView
            } else {
                Color.black
                    .ignoresSafeArea()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if !userService.isLoggedIn {
                                isLoginPresented = true
                            }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            if !isNetworkPermissionGranted && !isCheckingNetworkPermission {
                checkNetworkPermission()
            }
            if userService.isLoggedIn, let token = userService.currentToken, userService.isTokenValid,
               let exp = userService.tokenExpiration,
               Date().timeIntervalSince1970 + 5 * 60 >= exp {
                Task {
                    try? await userService.refreshAccessToken(silent: true)
                    print("🔄 前台主动预刷新 Access Token")
                }
            }
        }
        .fullScreenCover(isPresented: $isLoginPresented) {
            LoginView()
                .environmentObject(userService)
                .environmentObject(playbackService)
                .environmentObject(lyricsService)
                .interactiveDismissDisabled(true)
                .onDisappear {
                    if userService.isLoggedIn {
                        playbackService.syncFavorites()
                        if let currentSong = playbackService.currentSong {
                            playbackService.fetchLikeCount(for: currentSong)
                            playbackService.fetchCommentCount(for: currentSong)
                        }
                    }
                }
        }
        .environmentObject(playbackService)
        .environmentObject(userService)
        .environmentObject(libraryService)
        .environmentObject(lyricsService)
        .environmentObject(virtualArtistService)
        .onAppear {
            virtualArtistService.userService = userService
            playbackService.userService = userService
            playbackService.libraryService = libraryService
            playbackService.configure(userService: userService, libraryService: libraryService)
            
            if userService.isLoggedIn {
                playbackService.syncFavorites()
            }
            
            NotificationCenter.default.addObserver(
                forName: .userDidLogout,
                object: nil,
                queue: .main
            ) { _ in
                isLoginPresented = true
            }
            
            let _ = userService.$isLoggedIn.sink { loggedIn in
                if loggedIn {
                    isLoginPresented = false
                }
            }
            
            // 启动时检查本地网络权限
            checkNetworkPermission()
            
            // ✅ 在这里插入冷启动链接处理代码
                if let url = deepLinkHandler.pendingURL {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        playbackService.handleUniversalLink(url: url)
                        deepLinkHandler.pendingURL = nil
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .handleIncomingURL)) { notification in
            if let url = notification.object as? URL {
                playbackService.handleUniversalLink(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentFullPlayer)) { _ in
            guard playbackService.playerUIMode == .full else { return }
            presentFullPlayerWithRetry(attempt: 0)
        }
    }
    
    // MARK: - 本地网络权限检测
    private func checkNetworkPermission() {
        Task {
            let granted = await LocalNetworkPermissionManager.shared.requestPermission()
            await MainActor.run {
                self.isNetworkPermissionGranted = granted
                self.isCheckingNetworkPermission = false
                if granted {
                    if userService.isLoggedIn {
                        Task { await libraryService.loadAISongsFromServer() }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var mainTabView: some View {
        ZStack {
            TabView(selection: $tabSelection.selectedTab) {
                DiscoveredView(onPlayTheme: { songs, firstSong in
                    playbackService.forceCompactOnNextOpen = false
                    playbackService.switchToPlaylist(songs: songs, startIndex: 0, openFullPlayer: true)
                })
                .tabItem { Label("发现", systemImage: "music.note.list") }
                .tag(0)
                .environmentObject(libraryService)
                .environmentObject(lyricsService)
                .environmentObject(tabSelection)
                
                ProfileView()
                    .tabItem { Label("我的", systemImage: "person") }
                    .tag(2)
                    .environmentObject(userService)
            }
            .toolbar(isTabBarHidden ? .hidden : .visible, for: .tabBar)
        }
        .onAppear {
            Task { await libraryService.loadAISongsFromServer() }
            MiniPlayerWindow.configure(
                with: MiniPlayerContainer()
                    .environmentObject(playbackService)
                    .environmentObject(lyricsService)
                    .environmentObject(userService)
            )
            
            // ✅ 保留：UI就绪后，若当前已是全屏模式，立即弹出
//            if playbackService.playerUIMode == .full {
//                presentFullPlayerWithRetry(attempt: 0)
//            }
            
            
        }
        .onChange(of: playbackService.playerUIMode) { newMode in
            if newMode != .full {
                if let presentedVC = getRootViewController()?.presentedViewController,
                   presentedVC is UIHostingController<FullPlayerView> {
                    presentedVC.dismiss(animated: true)
                }
            }
        }
    }
    
    
    // 同步版：用于 dismiss 等场景（最早的稳定版本）
    private func getRootViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        // 查找第一个 windowLevel 为 normal 且有 rootViewController 的窗口
        let normalWindow = windowScene.windows.first(where: {
            $0.windowLevel == .normal && $0.rootViewController != nil
        })
        if let rootVC = normalWindow?.rootViewController {
            return rootVC
        }
        // 极少数情况 fallback：任何有 rootViewController 的窗口
        return windowScene.windows.first(where: { $0.rootViewController != nil })?.rootViewController
    }
    
    // 同步版（用于全屏弹出，避免阻塞）
    private func getRootViewControllerAsync(completion: @escaping (UIViewController?) -> Void) {
        func attempt(_ tries: Int) {
            guard tries < 10 else {
                completion(nil)
                return
            }
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first(where: {
                   $0.windowLevel == .normal && $0.rootViewController != nil
               })?.rootViewController {
                completion(rootVC)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    attempt(tries + 1)
                }
            }
        }
        attempt(0)
    }
    
    

    // 修改 presentFullPlayerWithRetry 方法
    private func presentFullPlayerWithRetry(attempt: Int) {
        guard attempt < 3 else {
            print("❌ 全屏播放器弹出失败，已达最大重试次数")
            playbackService.playerUIMode = .mini
            isPresentingFullPlayer = false
            return
        }
        
        guard playbackService.playerUIMode == .full else { return }
        guard !isPresentingFullPlayer else { return }
        isPresentingFullPlayer = true
        
        getRootViewControllerAsync { rootVC in
            guard let rootVC = rootVC else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.isPresentingFullPlayer = false
                    self.presentFullPlayerWithRetry(attempt: attempt + 1)
                }
                return
            }
            
            if self.isFullPlayerAlreadyPresented(rootVC: rootVC) {
                self.isPresentingFullPlayer = false
                return
            }
            
            let topVC = rootVC.topMostViewController()
            guard topVC.presentedViewController == nil,
                  !topVC.isBeingPresented,
                  !topVC.isBeingDismissed else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.isPresentingFullPlayer = false
                    self.presentFullPlayerWithRetry(attempt: attempt + 1)
                }
                return
            }
            
            let fullPlayerView = FullPlayerView(isTabBarHidden: self.$isTabBarHidden)
                .environmentObject(self.playbackService)
                .environmentObject(self.lyricsService)
                .environmentObject(self.userService)
            let hostingController = UIHostingController(rootView: fullPlayerView)
            hostingController.modalPresentationStyle = .fullScreen
            
            print("🎬 弹出全屏播放器 (attempt \(attempt))")
            topVC.present(hostingController, animated: true) {
                self.isPresentingFullPlayer = false
                print("✅ 全屏播放器弹出成功")
            }
        }
    }


    // 弹出全屏播放器（已修复 weak 问题）
//    private func presentFullPlayerWithRetry(attempt: Int) {
//        guard attempt < 8 else {
//            print("❌ 全屏播放器弹出失败，已达最大重试次数")
//            return
//        }
//
//        guard playbackService.playerUIMode == .full else { return }
//
//        getRootViewControllerAsync { rootVC in
//            guard let rootVC = rootVC else {
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//                    self.presentFullPlayerWithRetry(attempt: attempt + 1)
//                }
//                return
//            }
//
//            if self.isFullPlayerAlreadyPresented(rootVC: rootVC) {
//                print("⚠️ 全屏播放器已存在，取消重复弹出")
//                return
//            }
//
//            let topVC = rootVC.topMostViewController()
//            guard topVC.presentedViewController == nil,
//                  !topVC.isBeingPresented,
//                  !topVC.isBeingDismissed else {
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) {
//                    self.presentFullPlayerWithRetry(attempt: attempt + 1)
//                }
//                return
//            }
//
//            let fullPlayerView = FullPlayerView(isTabBarHidden: self.$isTabBarHidden)
//                .environmentObject(self.playbackService)
//                .environmentObject(self.lyricsService)
//                .environmentObject(self.userService)
//            let hostingController = UIHostingController(rootView: fullPlayerView)
//            hostingController.modalPresentationStyle = .fullScreen
//
//            print("🎬 弹出全屏播放器 (attempt \(attempt))")
//            topVC.present(hostingController, animated: true)
//        }
//    }
    
    // 辅助方法：递归检查是否已存在 FullPlayerView
    private func isFullPlayerAlreadyPresented(rootVC: UIViewController) -> Bool {
        if rootVC is UIHostingController<FullPlayerView> {
            return true
        }
        if let presented = rootVC.presentedViewController {
            return isFullPlayerAlreadyPresented(rootVC: presented)
        }
        for child in rootVC.children {
            if isFullPlayerAlreadyPresented(rootVC: child) {
                return true
            }
        }
        return false
    }
    
}

struct MiniPlayerContainer: View {
    @EnvironmentObject var playbackService: PlaybackService
    var body: some View {
        MiniPlayerView()
            .allowsHitTesting(true)
    }
}

extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = self.presentedViewController {
            return presented.topMostViewController()
        }
        if let nav = self as? UINavigationController {
            return nav.visibleViewController?.topMostViewController() ?? nav
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }
        return self
    }
}


