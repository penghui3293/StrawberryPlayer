import SwiftUI
import UIKit
import CoreImage
import ImageIO
import Combine

extension Color {
    func mix(with color: Color, amount: CGFloat) -> Color {
        let clamped = min(max(amount, 0), 1)
        return Color(uiColor: UIColor(self).mix(with: UIColor(color), amount: clamped))
    }
}

extension UIColor {
    func mix(with color: UIColor, amount: CGFloat) -> UIColor {
        let clamped = min(max(amount, 0), 1)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 * (1 - clamped) + r2 * clamped,
            green: g1 * (1 - clamped) + g2 * clamped,
            blue: b1 * (1 - clamped) + b2 * clamped,
            alpha: a1 * (1 - clamped) + a2 * clamped
        )
    }
}

struct ThreeFingerPinchGesture: UIViewRepresentable {
    var onPinch: () -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = true // 必须启用才能接收手势
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        view.addGestureRecognizer(pinch)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPinch: onPinch)
    }
    
    class Coordinator: NSObject {
        var onPinch: () -> Void
        
        init(onPinch: @escaping () -> Void) {
            self.onPinch = onPinch
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .ended && gesture.numberOfTouches == 3 {
                onPinch()
            }
        }
    }
}


struct PlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct LyricsCardView: View {
    let lyrics: String
    let accentColor: Color
    
    var body: some View {
        VStack {
            Text(lyrics)
                .font(.custom("PingFangSC-Semibold", size: 24))
                .foregroundColor(.white)
                .padding()
                .background(accentColor)
                .cornerRadius(12)
        }
        .frame(width: 300, height: 200)
        .background(Color.black.opacity(0.8))
        .cornerRadius(16)
    }
}

// MARK: - 自定义胶囊图标（细长）
struct CapsuleIcon: View {
    var width: CGFloat = 24
    var height: CGFloat = 10
    var color: Color = .white
    
    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: height)
    }
}



struct FullPlayerView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @EnvironmentObject var userService: UserService
    @Binding var isTabBarHidden: Bool
    
    @Environment(\.dismiss) var dismiss  // 新增：用于关闭 sheet
    
    
    @State private var showLibrary = false
    @State private var showComments = false
    @State private var showCommentAlert = false
    @State private var commentText = ""
    @State private var blurOpacity: Double = 0.6
    @State private var showPlaylist = false
    @State private var showLoginSheet = false
    
    @State private var currentColorExtractionTask: Task<Void, Never>?
    @State private var lyricsMode: LyricsDisplayMode = .compact
    @AppStorage("lastLyricsMode") private var lastLyricsModeRaw: String = "compact"
    
    // 1. 添加状态变量
    @State private var isLoginSheetPresented = false
    @State private var isLoginPresented = false
    @State private var showSharePanel = false
    @State private var isGestureEnabled = true   // ✅ 控制全屏滑动手势的启用
    
    @State private var showAudioEffectPicker = false
    @State private var displayedSong: Song?  // 保持歌曲信息不被清空
    
    init(isTabBarHidden: Binding<Bool>) {
        self._isTabBarHidden = isTabBarHidden
    }
    
    @State private var screenSize: CGSize = {
        let bounds = UIScreen.main.bounds
        return CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
    }()
    
    @State private var safeAreaInsets: UIEdgeInsets = {
        let insets = UIApplication.shared.windows.first?.safeAreaInsets ?? .zero
        return UIEdgeInsets(
            top: max(insets.top, 0),
            left: max(insets.left, 0),
            bottom: max(insets.bottom, 0),
            right: max(insets.right, 0)
        )
    }()
    
    @State private var lyricsModeChangeTask: DispatchWorkItem?
    @State private var memoryWarningToken: AnyCancellable?
    @State private var lyricsRefreshToken = UUID()
    
    
    var body: some View {
        mainZStackContent
            .allowsHitTesting(!isLoginPresented)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if lyricsMode == .fullScreen {
                    GeometryReader { geometry in
                        fullScreenModeControls(safeTop: geometry.safeAreaInsets.top, safeBottom: geometry.safeAreaInsets.bottom)
                    }
                    .transition(.opacity)   // ✅ 平滑淡出，避免滚动跳变
                }
            }
            .gesture(playbackDragGesture)
            .onChange(of: lyricsMode) { newMode in
                lyricsModeChangeTask?.cancel()
                let task = DispatchWorkItem {
                    handleLyricsModeChange(newMode)
                }
                lyricsModeChangeTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
            }
            .onChange(of: playbackService.currentSong) { newSong in
                handleCurrentSongChange(newSong)
            }
            .onChange(of: playbackService.currentTime) { newTime in
                lyricsService.currentPlaybackTime = newTime
                lyricsService.updateCurrentIndex(with: newTime)
            }
            .onChange(of: lyricsService.currentLyricIndex) { _ in
                updateBlurOpacity()
            }
            .onChange(of: playbackService.accentColor) { newColor in
                // 当主色从 clear 变为有效颜色时，强制刷新视图
                if newColor != .clear {
                    print("🎨 [FullPlayerView] 主色更新: \(newColor)")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .requireLogin)) { _ in
                showLoginSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .lyricsDidUpdate)) { notification in
                handleLyricsDidUpdate(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .currentSongChanged)) { notification in
                guard let song = notification.object as? Song,
                      song.id == playbackService.currentSong?.id else { return }
                print("🎵 [FullPlayerView] 收到 currentSongChanged 通知，刷新歌词")
                handleCurrentSongChange(song)
            }
            .fullScreenCover(isPresented: $showLoginSheet) {
                LoginView()
                    .environmentObject(userService)
                    .environmentObject(playbackService)
                    .environmentObject(lyricsService)
                    .interactiveDismissDisabled(true)
                    .onAppear { lyricsService.pauseDriver() }
                    .onDisappear { lyricsService.resumeDriver() }
            }
            .sheet(isPresented: $showLibrary) {
                SongListView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showComments) {
                if let song = playbackService.currentSong {
                    CommentsView(song: song)
                        .environmentObject(playbackService)
                        .environmentObject(userService)
                }
            }
            .sheet(isPresented: $showPlaylist) {
                PlaylistView()
                    .environmentObject(playbackService)
            }
            .alert("写评论", isPresented: $showCommentAlert) {
                TextField("写下你的评论...", text: $commentText)
                Button("提交", action: submitComment)
                Button("取消", role: .cancel) { commentText = "" }
            }
            .onAppear {
                handleOnAppear()
            }
            .onDisappear {
                lyricsService.pauseDriver()
                handleOnDisappear()
            }
            .overlay(
                Group {
                    if showSharePanel {
                        SharePanelView(
                            onWeibo: { shareToWeibo() },
                            onQQ: { shareToQQ() },
                            onCopyLink: { copyShareLink() },
                            onClose: { showSharePanel = false }
                        )
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: showSharePanel)
                    }
                }
            )
            .overlay(
                Group {
                    if showAudioEffectPicker {
                        AudioEffectPickerView(
                            currentEffect: playbackService.currentAudioEffect,
                            onSelect: { effect in
                                playbackService.currentAudioEffect = effect
                                showAudioEffectPicker = false
                            },
                            onClose: { showAudioEffectPicker = false }
                        )
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: showAudioEffectPicker)
                    }
                }
            )
    }
    
    // MARK: - 拆分后的辅助视图与逻辑
    
    @ViewBuilder
    private var mainZStackContent: some View {
        ZStack {
            
            // 如果主色还未提取完成(clear)，就用深色背景代替，避免白色闪烁
            (playbackService.accentColor == .clear ? Color.black : playbackService.accentColor)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3), value: playbackService.accentColor)
            
            lyricsArea
                .allowsHitTesting(false)
                .zIndex(0)
            
            ThreeFingerPinchGesture(onPinch: favoriteCurrentSong)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .allowsHitTesting(!isLoginSheetPresented)
            
            if lyricsMode == .compact {
                compactModeControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
    
    private var playbackDragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                guard isGestureEnabled else { return }   // ✅ 新增
                guard !isLoginSheetPresented else { return }
                guard !playbackService.isLoadingSong else { return }
                
                // ✅ 新增：如果拖拽起点在屏幕底部 80pt 以内，直接忽略（系统手势）
                let screenHeight = UIScreen.main.bounds.height
                guard value.startLocation.y < screenHeight - 80 else { return }
                
                let translation = value.translation
                let horizontal = abs(translation.width)
                let vertical = abs(translation.height)
                
                if horizontal > vertical {
                    if translation.width > 50 {
                        withAnimation { lyricsMode = .compact }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } else if translation.width < -50 {
                        withAnimation { lyricsMode = .fullScreen }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    return
                }
                
                
                guard vertical > 80 else { return }
                guard lyricsMode == .compact else { return }   // ✅ 新增：仅在紧凑模式下上下滑动才切歌
                
                
                if translation.height > 0 {
                    playbackService.playNext()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    playbackService.playPrevious()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
    
    private func handleLyricsModeChange(_ newMode: LyricsDisplayMode) {
        print("🎵 lyricsMode changed to: \(newMode)")
        if newMode == .fullScreen {
            print("当前歌曲: \(playbackService.currentSong?.title ?? "nil")")
        }
        isTabBarHidden = (newMode == .fullScreen)
        setTabBarHidden(newMode == .fullScreen)
        DispatchQueue.main.async {
            UIApplication.shared.windows.first?.rootViewController?.view.setNeedsLayout()
        }
        print("🎵 isTabBarHidden set to: \(isTabBarHidden)")
    }
    
    private func handleCurrentSongChange(_ newSong: Song?) {
        guard let song = newSong else {
            // 歌曲变为 nil：保持 displayedSong 不变，避免 UI 空白
            return
        }
        
        // 更新显示的歌曲信息
        displayedSong = song
        
        // 如果歌词不属于当前歌曲，或者歌词为空，或者歌曲 ID 发生了变化 → 重新加载歌词
        let needReload = lyricsService.currentSongId != song.id || lyricsService.lyrics.isEmpty
        
        if needReload {
            print("🎵 [FullPlayerView] 加载歌词: \(song.title)")
            lyricsService.fetchLyrics(for: song, songDuration: song.duration)
        } else {
            // 同一首歌，但需要强制刷新 UI（DeepLink 场景下视图可能是全新的）
            print("🎵 [FullPlayerView] 同一首歌，刷新歌词索引: \(song.title)")
            lyricsService.updateCurrentIndex(with: playbackService.currentTime + lyricsService.lyricOffset)
            // ✅ 强制触发一次 UI 刷新（通过修改 lyricsRefreshToken）
            lyricsRefreshToken = UUID()
        }
                
        // 加载分享数
        playbackService.fetchShareCount(for: song)
    }
    
    private func updateBlurOpacity() {
        let total = lyricsService.lyrics.count
        let progress = total > 0 ? Double(lyricsService.currentLyricIndex) / Double(total) : 0.5
        blurOpacity = 0.3 + 0.3 * (1 - abs(progress - 0.5) * 2)
    }
    
    private func handleLyricsDidUpdate(_ notification: Notification) {
        guard let songId = notification.object as? String,
              songId == playbackService.currentSong?.id else { return }
        lyricsService.fetchLyrics(for: playbackService.currentSong!)
    }
    
    private func handleOnAppear() {
        print("💾 [FullPlayerView appear] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")

        // 缓存屏幕尺寸和安全区域
        screenSize = UIScreen.main.bounds.size
        safeAreaInsets = UIApplication.shared.windows.first?.safeAreaInsets ?? .zero

        // 防御：确保服务状态为全屏
        if playbackService.playerUIMode != .full {
            playbackService.setPlayerUIMode(.full)
        }

        // 恢复歌词模式
        if let mode = LyricsDisplayMode(rawValue: lastLyricsModeRaw) {
            lyricsMode = mode
        } else {
            lyricsMode = .fullScreen
        }

        // 恢复歌词驱动
        lyricsService.resumeDriver()

        if let song = playbackService.currentSong {
            // 先同步歌曲信息
            displayedSong = song
            // 强制触发 UI 刷新（解决 DeepLink 弹出后黑屏问题）
            handleCurrentSongChange(song)
            lyricsRefreshToken = UUID()
        } else {
            lyricsService.reset()
        }

        print("🎨 当前封面主色: \(playbackService.accentColor)")

        // 禁用滑动手势 0.3 秒
        isGestureEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isGestureEnabled = true
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name("WechatShareSuccess"), object: nil, queue: .main) { _ in
            self.playbackService.shareCount += 1
            self.showShareSuccessAlert()
            self.showSharePanel = false
        }

        memoryWarningToken = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak lyricsService] _ in
                lyricsService?.clearAllParsedCache()
                lyricsService?.reset()
            }
        
        // ✅ 关键修复：DeepLink 弹出后延迟刷新，确保所有绑定数据已到位
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let song = playbackService.currentSong {
                    displayedSong = song
                    handleCurrentSongChange(song)
                    lyricsRefreshToken = UUID()
                    print("🎵 [FullPlayerView] 延迟刷新完成，歌曲: \(song.title), 时长: \(playbackService.duration)")
                }
            }
        
    }
    
//    private func handleOnAppear() {
//        print("💾 [FullPlayerView appear] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")
//        
//        // 缓存屏幕尺寸和安全区域，避免 body 中反复计算
//        screenSize = UIScreen.main.bounds.size
//        safeAreaInsets = UIApplication.shared.windows.first?.safeAreaInsets ?? .zero
//        
//        // 防御：确保服务状态为全屏
//        if playbackService.playerUIMode != .full {
//            playbackService.setPlayerUIMode(.full)
//        }
//        
//        // 恢复歌词模式
//        if let mode = LyricsDisplayMode(rawValue: lastLyricsModeRaw) {
//            lyricsMode = mode
//        } else {
//            lyricsMode = .fullScreen
//        }
//        
//        // ✅ 恢复歌词驱动
//        lyricsService.resumeDriver()
//        
//        if let song = playbackService.currentSong {
//            // 仅当歌词不属于当前歌曲，或歌词为空时才加载
//            let needLoad = lyricsService.currentSongId != song.id || lyricsService.lyrics.isEmpty
//            if needLoad && !lyricsService.isLoading {
//                lyricsService.fetchLyrics(for: song, songDuration: song.duration)
//            }
//        } else {
//            lyricsService.reset()   // 无歌曲时清空歌词
//        }
//        
//        displayedSong = playbackService.currentSong
//        
//        print("🎨 当前封面主色: \(playbackService.accentColor)")
//        
//        
//        // 禁用滑动手势 0.3 秒，避免打开动画期间误触
//        isGestureEnabled = false
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
//            isGestureEnabled = true
//        }
//        
//        NotificationCenter.default.addObserver(forName: NSNotification.Name("WechatShareSuccess"), object: nil, queue: .main) { _ in
//            self.playbackService.shareCount += 1
//            self.showShareSuccessAlert()
//            self.showSharePanel = false
//        }
//        
//        memoryWarningToken = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
//            .sink { [weak lyricsService] _ in
//                lyricsService?.clearAllParsedCache()
//                lyricsService?.reset()
//            }
//        
//    }
    
    private func performCleanupAfterDisappear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.cleanupMainWindowInteraction()
        }
    }
    private func cleanupMainWindowInteraction() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootView = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view else { return }
        enableUserInteractionRecursively(rootView)
        restoreMainWindowKeyStatus()
    }
    private func enableUserInteractionRecursively(_ view: UIView) {
        view.isUserInteractionEnabled = true
        view.subviews.forEach { enableUserInteractionRecursively($0) }
    }
    private func restoreMainWindowKeyStatus() {
        if let mainWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.windowLevel == .normal && $0.isKeyWindow == false }) {
            mainWindow.makeKeyAndVisible()
        }
    }
    
    // MARK: - 公共模式切换按钮组
    @ViewBuilder
    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            // 切换到紧凑模式的按钮
            Button(action: { withAnimation { lyricsMode = .compact } }) {
                if lyricsMode == .compact {
                    CapsuleIcon(width: 12, height: 5, color: .white)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(6)
            
            // 切换到全屏模式的按钮
            Button(action: { withAnimation { lyricsMode = .fullScreen } }) {
                if lyricsMode == .fullScreen {
                    CapsuleIcon(width: 12, height: 5, color: .white)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(6)
        }
    }
    
    // MARK: - 紧凑模式控件（按钮位置与全屏顶部栏精确对齐）
    @ViewBuilder
    private var compactModeControls: some View {
        GeometryReader { geometry in
            let safeTop = geometry.safeAreaInsets.top
            let safeBottom = geometry.safeAreaInsets.bottom
            
            VStack(spacing: 0) {
                // 顶部控件（与全屏模式完全相同的贴顶方式）
                compactTopBar
                    .padding(.top, safeTop)
                
                Spacer()
                
                // 底部控件（与全屏模式完全相同的贴底方式）
                bottomControls
                    .padding(.bottom, safeBottom + 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)   // 透明，让下层歌词可见
        }
    }
    
    // MARK: - 全屏模式控件（重构后，顶部贴顶、底部贴底）
    @ViewBuilder
    private func fullScreenModeControls(safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        let hasSong = playbackService.currentSong != nil
        
        VStack(spacing: 0) {
            // 顶部栏：直接贴顶，不再使用固定高度
            compactTopBar
                .padding(.top, safeTop)          // 紧贴安全区顶部
                .padding(.horizontal, 16)        // 水平内边距与紧凑模式一致（可选）
            
            // 歌词区域：占据所有剩余空间
            if lyricsService.lyrics.isEmpty {
                if let song = playbackService.currentSong, song.virtualArtistId != nil {
                    Spacer()
                } else {
                    VStack(spacing: 12) {
                        if let song = playbackService.currentSong {
                            Text(song.artist)
                                .font(.title2)
                                .foregroundColor(.white)
                            Text("纯音乐，请欣赏")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.7))
                        } else {
                            Text("暂无歌词")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                TraditionalLyricsView(
                    isFullScreen: true,
                    onDismiss: { withAnimation { lyricsMode = .compact } }
                )
                .id("fullLyrics-\(playbackService.currentSong?.id ?? "nil")-\(lyricsRefreshToken)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // 底部控制栏：直接贴底，移除固定高度
            if let song = displayedSong {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // 收藏按钮
                    Button(action: {
                        guard userService.isLoggedIn else {
                            NotificationCenter.default.post(name: .requireLogin, object: nil)
                            return
                        }
                        guard let currentSong = playbackService.currentSong else { return }
                        playbackService.toggleFavorite(currentSong) { result in
                            switch result {
                            case .success: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            case .failure(let error): print("toggleFavorite failed: \(error)")
                            }
                        }
                    }) {                        
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: playbackService.isFavorite(playbackService.currentSong ?? song) ? "heart.fill" : "heart")
                                .font(.system(size: 22))
                                .foregroundColor(playbackService.isFavorite(playbackService.currentSong ?? song) ? playbackService.accentColor.mix(with: .white, amount: 0.5) : .white)
                            Text(formattedCount(playbackService.likeCount))
                                .font(.caption2)
                                .foregroundColor(.white)
                                .offset(x: 8, y: -8)
                        }
                        .frame(width: 44, height: 44)
                    }
                    
                    Spacer().frame(width: 18)
                    
                    // 播放/暂停
                    Button(action: playbackService.togglePlay) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                        }
                        .frame(width: 44, height: 44)
                    }
                    
                    Spacer().frame(width: 18)
                    
                    // 下一首
                    Button(action: { playbackService.playNext() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, safeBottom + 8)   // 紧贴屏幕底部
            } else {
                // 无歌曲时留空
                Color.clear.frame(height: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 紧凑模式顶部栏（公共组件）
    @ViewBuilder
    private var compactTopBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {dismiss()}) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Circle().fill(Color.secondary.opacity(0.3)))
                }
                .frame(width: 44, alignment: .leading)
                .padding(.leading, 16)
                
                Spacer()
                modeSwitcher
                Spacer()
                
                Color.clear.frame(width: 44).padding(.trailing, 16)
            }
            .frame(height: 44)
            .padding(.bottom, 8)
            
            // 紧凑模式时显示歌曲信息（全屏模式下会被隐藏，但这里通过外部条件控制）
            if lyricsMode == .compact, let song = displayedSong {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.headline).foregroundColor(.white)
                        Text(song.artist).font(.subheadline).foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    Button(action: { showAudioEffectPicker = true }) {
                        Image(systemName: playbackService.currentAudioEffect == .off ? "hifispeaker" : "hifispeaker.fill")
                            .font(.system(size: 16))
                            .foregroundColor(playbackService.currentAudioEffect == .off ? .white.opacity(0.7) : .white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.15)))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        lyricsArea
            .scaleEffect(lyricsMode == .compact ? 1 : 0.98)
            .opacity(lyricsMode == .compact ? 1 : 0.95)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: lyricsMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var topNavigationBar: some View {
        HStack {
            Spacer()
            Image(systemName: lyricsMode == .compact ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.primary)
                .padding(8)
                .background(Circle().fill(Color.secondary.opacity(0.1)))
                .id(lyricsMode)
                .transition(.scale.combined(with: .opacity))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    @ViewBuilder
    private var songInfoArea: some View {
        if let song = playbackService.currentSong {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
    }
    
    @ViewBuilder
    private var lyricsArea: some View {
        if lyricsMode == .compact {
            if lyricsService.lyrics.isEmpty && lyricsService.isLoading {
                ZStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if lyricsService.lyrics.isEmpty {
                // ✅ 修复：直接根据歌曲类型显示内容，不再显示多余的进度条
                if let song = playbackService.currentSong, song.virtualArtistId != nil {
                    // AI 音乐：无歌词时显示空白
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 古典音乐或非 AI 音乐：显示纯音乐提示
                    VStack(spacing: 12) {
                        Text(playbackService.currentSong?.artist ?? "未知艺术家")
                            .font(.title2).foregroundColor(.white)
                        Text("纯音乐，请欣赏")
                            .font(.body).foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            } else {
                GeometryReader { geometry in
                    WordByWordLyricsView(
                        onTap: {
                            withAnimation { lyricsMode = .fullScreen }
                        }
                    )
                    .id("wordLyrics-\(playbackService.currentSong?.id ?? "nil")-\(lyricsRefreshToken)")
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        } else {
            Color.clear
        }
    }
    
    @ViewBuilder
    private var bottomControls: some View {
        let secondaryAccent = Color.white
        let hasCurrentSong = playbackService.currentSong != nil
        let screenWidth = UIScreen.main.bounds.width
        let sliderWidth = max(screenWidth - 40, 100)
        
        VStack(spacing: 4) {
            if let song = playbackService.currentSong {
                HStack(spacing: 30) {
                    // 收藏按钮
                    Button(action: {
                        guard userService.isLoggedIn else {
                            NotificationCenter.default.post(name: .requireLogin, object: nil)
                            return
                        }
                        playbackService.toggleFavorite(song) { result in
                            switch result {
                            case .success:
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                //                                playbackService.fetchLikeCount(for: song)
                            case .failure(let error):
                                print("toggleFavorite failed: \(error)")
                            }
                        }
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: playbackService.isFavorite(song) ? "heart.fill" : "heart")
                                .font(.system(size: 32))
                                .foregroundColor(playbackService.isFavorite(song) ? playbackService.accentColor.mix(with: .white, amount: 0.5) : secondaryAccent)
                            Text(formattedCount(playbackService.likeCount))
                                .font(.caption2)
                                .foregroundColor(secondaryAccent)
                                .offset(x: 8, y: -8)
                        }
                    }
                    .disabled(playbackService.currentSong == nil)
                    
                    // 评论按钮
                    Button(action: {
                        if userService.isLoggedIn {
                            showComments = true
                        } else {
                            NotificationCenter.default.post(name: .requireLogin, object: nil)
                        }
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 32))
                                .foregroundColor(secondaryAccent)
                            Text(formattedCount(playbackService.commentCount))
                                .font(.caption2)
                                .foregroundColor(secondaryAccent)
                                .offset(x: 8, y: -8)
                        }
                    }
                    
                    // 分享按钮
                    Button(action: {
                        guard userService.isLoggedIn else {
                            NotificationCenter.default.post(name: .requireLogin, object: nil)
                            return
                        }
                        showSharePanel = true
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 32))
                                .foregroundColor(secondaryAccent)
                            Text(formattedCount(playbackService.shareCount))
                                .font(.caption2)
                                .foregroundColor(secondaryAccent)
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 0)
            }
            
            // 进度条与时间显示（保持不变）
            VStack(spacing: 2) {
                CustomSlider(
                    value: $playbackService.currentTime,
                    range: 0...max(playbackService.duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            playbackService.seek(to: playbackService.currentTime)
                        }
                    },
                    accentColor: secondaryAccent
                )
                .frame(width: sliderWidth, height: 12)
                .disabled(!hasCurrentSong)
                
                HStack {
                    Text(formatTime(playbackService.currentTime))
                        .font(.caption)
                        .foregroundColor(secondaryAccent)
                        .frame(minWidth: 40, alignment: .leading)
                    Spacer()
                    Text(formatTime(playbackService.duration))
                        .font(.caption)
                        .foregroundColor(secondaryAccent)
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal, 0)
            
            // 播放控制按钮组（只保留模式切换、播放/暂停、列表）
            HStack {
                Spacer()
                Button(action: togglePlaybackMode) {
                    Image(systemName: playbackModeIcon)
                        .font(.title)
                        .foregroundColor(secondaryAccent)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Button(action: playbackService.togglePlay) {
                    ZStack {
                        Circle()
                            .fill(playbackService.accentColor.opacity(0.1))
                            .frame(width: 68, height: 68)
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36))
                            .foregroundColor(secondaryAccent)
                            .id(playbackService.isPlaying)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .buttonStyle(PlaybackButtonStyle())
                .animation(.easeInOut(duration: 0.2), value: playbackService.isPlaying)
                Spacer()
                Button(action: { showPlaylist = true }) {
                    Image(systemName: "list.bullet")
                        .font(.title)
                        .foregroundColor(secondaryAccent)
                        .frame(width: 44, height: 44)
                }
                Spacer()
            }
            .padding(.top, 0)
            .padding(.bottom, 4)
        }
        .background(Color.clear)
        .shadow(radius: 1)
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 辅助方法
    
    private func showShareSuccessAlert() {
        let alert = UIAlertController(title: "分享成功", message: nil, preferredStyle: .alert)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                alert.dismiss(animated: true)
            }
        }
    }
    
    private func showCopySuccessAlert() {
        let alert = UIAlertController(title: "链接已复制", message: nil, preferredStyle: .alert)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                alert.dismiss(animated: true)
            }
        }
    }
    
    // 分享处理函数（含计数累加）
    private func setTabBarHidden(_ hidden: Bool) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                print("❌ 无法获取根视图控制器")
                return
            }
            
            // 递归查找 UITabBarController
            func findTabBarController(from vc: UIViewController) -> UITabBarController? {
                if let tabBar = vc as? UITabBarController {
                    return tabBar
                }
                for child in vc.children {
                    if let found = findTabBarController(from: child) {
                        return found
                    }
                }
                return nil
            }
            
            if let tabBarVC = findTabBarController(from: rootVC) {
                tabBarVC.tabBar.isHidden = hidden
                // 强制更新布局
                tabBarVC.view.setNeedsLayout()
                print("✅ Tab Bar 隐藏状态已设置为: \(hidden)")
            } else {
                print("❌ 未找到 UITabBarController")
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private var playbackModeIcon: String {
        switch playbackService.playbackMode {
        case .sequential: return "arrow.forward.to.line"  // 顺序模式图标
        case .loopOne:    return "repeat.1"                // 单曲循环图标
        }
    }
    
    
    private func togglePlaybackMode() {
        let newMode: PlaybackMode
        switch playbackService.playbackMode {
        case .sequential:
            newMode = .loopOne
        case .loopOne:
            newMode = .sequential
        }
        playbackService.updatePlaybackMode(newMode)
    }
    
    
    private func toggleFavorite(_ song: Song) {
        playbackService.toggleFavorite(song) { _ in }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // 1. 复制链接
    private func copyShareLink() {
        guard let song = playbackService.currentSong else { return }
        let shareText = """
        🎵 我在听《\(song.title)》- \(song.artist)
        快来一起听吧！👉 \(AppConfig.baseURL)/song/\(song.stableId)
        """
        UIPasteboard.general.string = shareText
        playbackService.shareCount += 1
        showSharePanel = false
    }
    
    // 2. QQ 分享
    private func shareToQQ() {
        ShareManager.shared.setup()
        guard let song = playbackService.currentSong else { return }
        let shareText = "我在听《\(song.title)》- \(song.artist)"
        let shareURL = "\(AppConfig.baseURL)/song/\(song.stableId)"   // 直接使用 stableId
        
        print("🔍 song.stableId = \(song.stableId)")
        
        loadCoverImage(for: song) { image in
            let cover = image ?? UIImage.placeholder()                // 使用代码生成的占位图
            print("📸 分享封面数据大小: \(cover?.jpegData(compressionQuality: 0.8)?.count ?? 0) bytes")
            
            DispatchQueue.main.async {
                ShareManager.shared.share(to: .qq, text: shareText, image: cover, url: shareURL) { success in
                    print("📤 QQ分享结果: \(success), 链接: \(shareURL)")
                    
                    
                    if success {
                        // 调用服务器增加分享数
                        playbackService.incrementShareCount(for: song)
                        // 本地立即 +1 作为乐观更新（服务器也会返回最终值）
                        self.playbackService.shareCount += 1
                        
                        
                        // ✅ 新增：更新分享计数缓存
                            let currentShares = SongMetricsCache.shared.get(songId: song.stableId)?.shares ?? 0
                            SongMetricsCache.shared.set(songId: song.stableId, shares: currentShares + 1)
                            if playbackService.currentSong?.stableId == song.stableId {
                                playbackService.shareCount = currentShares + 1
                            }
                    }
                    
                    self.showSharePanel = false
                    ShareManager.shared.cleanupTencent()
                }
            }
        }
    }
    
    // 3. 微博分享
    private func shareToWeibo() {
        ShareManager.shared.setup()
        guard let song = playbackService.currentSong else { return }
        let shareText = "我在听《\(song.title)》- \(song.artist)"
        let shareURL = "\(AppConfig.baseURL)/song/\(song.stableId)"   // 直接使用 stableId
        
        loadCoverImage(for: song) { image in
            let cover = image ?? UIImage.placeholder()                // 使用代码生成的占位图
            print("📸 分享封面数据大小: \(cover?.jpegData(compressionQuality: 0.8)?.count ?? 0) bytes")
            
            DispatchQueue.main.async {
                ShareManager.shared.share(to: .weibo, text: shareText, image: cover, url: shareURL) { success in
                    if success { 
                        // 调用服务器增加分享数
                        playbackService.incrementShareCount(for: song)
                        self.playbackService.shareCount += 1
                        
                        // ✅ 新增：更新分享计数缓存
                            let currentShares = SongMetricsCache.shared.get(songId: song.stableId)?.shares ?? 0
                            SongMetricsCache.shared.set(songId: song.stableId, shares: currentShares + 1)
                            if playbackService.currentSong?.stableId == song.stableId {
                                playbackService.shareCount = currentShares + 1
                            }
                    }
                    self.showSharePanel = false
                    ShareManager.shared.cleanupWeibo()
                }
            }
        }
    }
    
    // ========== 新增：加载歌曲封面的辅助方法 ==========
    private func loadCoverImage(for song: Song, completion: @escaping (UIImage?) -> Void) {
        guard let coverURL = song.coverURL else {
            completion(UIImage.placeholder())   // ✅ 改这里
            return
        }
        URLSession.shared.dataTask(with: coverURL) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else {
                completion(UIImage.placeholder())   // ✅ 改这里
                return
            }
            let side = min(image.size.width, image.size.height)
            let rect = CGRect(x: (image.size.width - side)/2, y: 0, width: side, height: side)
            guard let cropped = image.cgImage?.cropping(to: rect) else {
                completion(UIImage.placeholder())
                return
            }
            let square = UIImage(cgImage: cropped)
            let size = CGSize(width: 120, height: 120)
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            square.draw(in: CGRect(origin: .zero, size: size))
            let thumb = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            if let thumb = thumb, let jpegData = thumb.jpegData(compressionQuality: 0.9) {
                completion(UIImage(data: jpegData))
            } else {
                completion(UIImage.placeholder())
            }
            
        }.resume()
    }
    
    private func favoriteCurrentSong() {
        guard let song = playbackService.currentSong else { return }
        toggleFavorite(song)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    
    private func shareLyricsSnippet() {
        guard lyricsService.currentLyricIndex < lyricsService.lyrics.count else { return }
        let currentLine = lyricsService.lyrics[lyricsService.currentLyricIndex].text
        let cardView = LyricsCardView(lyrics: currentLine, accentColor: playbackService.accentColor)
        let renderer = ImageRenderer(content: cardView)
        renderer.scale = UIScreen.main.scale
        if let image = renderer.uiImage {
            let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        }
    }
    
    private func submitComment() {
        guard let song = playbackService.currentSong, !commentText.isEmpty else { return }
        playbackService.addComment(commentText, for: song)
        print("提交后评论数：\(playbackService.comments(for: song).count)")
        commentText = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    
    private func formattedCount(_ count: Int) -> String {
        if count > 999 {
            return "\(count/1000)k"
        }
        return "\(count)"
    }
    
    private func handleOnDisappear() {
        
        print("💾 [FullPlayerView disappear] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")
        memoryWarningToken?.cancel()
        memoryWarningToken = nil
        
        currentColorExtractionTask?.cancel()
        
        setTabBarHidden(false)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("WechatShareSuccess"), object: nil)
        isGestureEnabled = true
        
        // ✅ 1. 清理歌词缓存（原有）
        lyricsService.clearAllParsedCache()
        
        // ✅ 2. 强制杀死所有挂起的网络连接，并重置共享会话
        URLSession.shared.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        
        // ✅ 3. 清空全局 URL 缓存，释放内存
        URLCache.shared.removeAllCachedResponses()
        
        // 模式切换：全屏 → 迷你
        if playbackService.playerUIMode == .full {
            if !playbackService.suppressMiniOnDismiss {
                playbackService.setPlayerUIMode(.mini)
            }
        }
        
        // ✅ 确保返回迷你后允许显示
        playbackService.setAllowMiniPlayer(true)
        
        
        lastLyricsModeRaw = lyricsMode.rawValue
        
        // 清理窗口交互
        DispatchQueue.main.async {
            self.performCleanupAfterDisappear()
        }
        
        lyricsRefreshToken = UUID()
        
    }
    
    
}

// MARK: - 预加载主色（供列表视图调用）

func preloadDominantColor(for song: Song) {
    guard let coverURL = song.coverURL else { return }
    let songId = song.stableId
    let cacheKey = "dominantColor_\(songId)"
    if UserDefaults.standard.dictionary(forKey: cacheKey) != nil {
        return // 已缓存
    }
    
    // 使用异步 URLSession 下载图片
    URLSession.shared.dataTask(with: coverURL) { data, response, error in
        guard let data = data, let image = UIImage(data: data) else {
            return
        }
        
        let size = CGSize(width: 50, height: 50)
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        let thumbnail = UIGraphicsGetImageFromCurrentImageContext() ?? image
        
        guard let uiColor = thumbnail.averageColor else { return }
        let color = Color(uiColor)
        
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let colorDict: [String: CGFloat] = ["r": r, "g": g, "b": b]
        UserDefaults.standard.set(colorDict, forKey: cacheKey)
    }.resume()
}

extension UIImage {
    var averageColor: UIColor? {
        
        return autoreleasepool { () -> UIColor? in
            guard let inputImage = CIImage(image: self) else { return nil }
            let extentVector = CIVector(
                x: inputImage.extent.origin.x,
                y: inputImage.extent.origin.y,
                z: inputImage.extent.size.width,
                w: inputImage.extent.size.height
            )
            guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: inputImage,
                kCIInputExtentKey: extentVector
            ]) else { return nil }
            
            guard let outputImage = filter.outputImage else { return nil }
            
            var bitmap = [UInt8](repeating: 0, count: 4)
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            context.render(outputImage,
                           toBitmap: &bitmap,
                           rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: nil)
            
            return UIColor(
                red: CGFloat(bitmap[0]) / 255,
                green: CGFloat(bitmap[1]) / 255,
                blue: CGFloat(bitmap[2]) / 255,
                alpha: 1.0
            )
        }
    }
}

struct SharePanelView: View {
    let onWeibo: () -> Void
    let onQQ: () -> Void
    let onCopyLink: () -> Void
    let onClose: () -> Void
    
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // 半透明背景
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                
                // 面板主体容器
                VStack(spacing: 0) {
                    // 拖拽指示条
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 40, height: 5)
                        .padding(.top, 12)
                    
                    // 标题
                    Text("分享给朋友")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    
                    // 按钮
                    HStack(spacing: 24) {
                        ShareOptionButton(icon: "bubble.left.fill", title: "微博", action: onWeibo)
                        ShareOptionButton(icon: "heart.fill", title: "QQ", action: onQQ)
                        ShareOptionButton(icon: "link", title: "复制链接", action: onCopyLink)
                    }
                    .padding(.horizontal, 20)
                }
                .frame(width: geometry.size.width)
                .background(
                    Color.black
                        .cornerRadius(16, corners: [.topLeft, .topRight])
                        .shadow(radius: 10)
                        .ignoresSafeArea(edges: .bottom)   // 黑色背景填满底部，不留空隙
                )
                .offset(y: max(0, dragOffset))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 80 || value.predictedEndTranslation.height > 180 {
                                onClose()
                            } else {
                                withAnimation(.spring()) { dragOffset = 0 }
                            }
                        }
                )
            }
        }
    }
}

// 扩展 View，支持指定圆角
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

struct ShareOptionButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(minWidth: 60)
        }
    }
}
// 辅助方法：压缩图片
extension UIImage {
    func resize(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        self.draw(in: CGRect(origin: .zero, size: size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }
}

struct AudioEffectPickerView: View {
    let currentEffect: AudioEffect
    let onSelect: (AudioEffect) -> Void
    let onClose: () -> Void
    
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // 半透明背景
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 40, height: 5)
                        .padding(.top, 12)
                    
                    Text("音质音效")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    
                    HStack(spacing: 16) {
                        effectCard(
                            title: "关闭",
                            subtitle: "无音效",
                            isSelected: currentEffect == .off,
                            action: { onSelect(.off) }
                        )
                        effectCard(
                            title: "3D环绕",
                            subtitle: "全景声场体验",
                            isSelected: currentEffect == .surround3D,
                            action: { onSelect(.surround3D) }
                        )
                    }
                    .padding(.horizontal, 20)
                }
                .frame(width: geometry.size.width)
                .background(
                    Color.black
                        .cornerRadius(16, corners: [.topLeft, .topRight])
                        .shadow(radius: 10)
                        .ignoresSafeArea(edges: .bottom)
                )
                .offset(y: max(0, dragOffset))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 80 || value.predictedEndTranslation.height > 180 {
                                onClose()
                            } else {
                                withAnimation(.spring()) { dragOffset = 0 }
                            }
                        }
                )
            }
        }
    }
    
    private func effectCard(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

extension UIImage {
    /// 生成纯色占位图，用于分享时封面缺失的兜底
    /// - Parameters:
    ///   - size: 建议 120x120 符合 QQ 规范
    ///   - color: 占位色，可使用暗灰色
    static func placeholder(size: CGSize = CGSize(width: 120, height: 120),
                            color: UIColor = UIColor.darkGray) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        color.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image
    }
}
