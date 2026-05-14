//
// DiscoveredView.swift
// 最终稳定版：使用 UIKit 手势处理点击，彻底解决穿透问题
//通过 UIKit 透明覆盖层方案彻底解决了主题卡片无法点击的问题
//

import SwiftUI

struct DiscoveredView: View {
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @EnvironmentObject var tabSelection: TabSelection

    let onPlayTheme: (_ songs: [Song], _ firstSong: Song) -> Void
    
    @State private var isLoading = false
    @State private var hasInitiallyLoaded = false
    @State private var bottomInset: CGFloat = 0
    @State private var loadFailed = false   // 新增：标记加载是否失败
    
    struct Theme: Identifiable {
        var id: String { title }   // ✅ 使用标题作为稳定标识，不再每次生成新 UUID
        let title: String
        let subtitle: String?
        let coverURL: URL?
        let songs: [Song]
    }
    
    private var themes: [Theme] {
        var newThemes: [Theme] = []
        let allSongs = libraryService.songs
        let classicalSongs = allSongs.filter { song in
            song.style?.lowercased() == "古典" && song.virtualArtistId == nil
        }
        if !classicalSongs.isEmpty {
            newThemes.append(Theme(
                title: "古典音乐",
                subtitle: "经典咏流传",
                coverURL: classicalSongs.first?.coverURL,
                songs: classicalSongs
            ))
        }
        let aiSongs = allSongs.filter { $0.virtualArtistId != nil }
        if !aiSongs.isEmpty {
            newThemes.append(Theme(
                title: "AI音乐",
                subtitle: "创造新感受",
                coverURL: aiSongs.first?.coverURL,
                songs: aiSongs
            ))
        }
        return newThemes
    }
    
    private func cardAreaFrame(in geometry: GeometryProxy) -> CGRect {
        let titleHeight: CGFloat = 120
        let startY = titleHeight
        let cardHeight: CGFloat = 160
        let rowSpacing: CGFloat = 12
        let rows = ceil(CGFloat(themes.count) / 2.0)
        let areaHeight = rows * (cardHeight + rowSpacing)
        return CGRect(x: 0, y: startY, width: geometry.size.width, height: areaHeight)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("发现")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color(UIColor.systemBackground))
            
            if isLoading && libraryService.songs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if libraryService.songs.isEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
        .padding(.bottom, bottomInset)
        .overlay(
            GeometryReader { geometry in
                let cardArea = cardAreaFrame(in: geometry)
                UIKitTapOverlay(isEnabled: shouldEnableTapOverlay) { point in
                    handleTap(at: point, in: geometry)
                }
                .frame(width: cardArea.width, height: cardArea.height)
                .position(x: cardArea.midX, y: cardArea.midY)
                .allowsHitTesting(shouldEnableTapOverlay)
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .miniPlayerDidAppear)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { bottomInset = 70 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .miniPlayerDidDisappear)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { bottomInset = 0 }
        }
        .onAppear {
            playbackService.setAllowMiniPlayer(true)
            if libraryService.songs.isEmpty && !hasInitiallyLoaded {
                hasInitiallyLoaded = true
                loadDataIfNeeded()
            }
        }
        .onDisappear {
            playbackService.setAllowMiniPlayer(false)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            if loadFailed {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 48))
                    .foregroundColor(.gray)
                Text("无法连接服务器")
                    .font(.headline)
                Text("请检查网络或本地网络权限")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("重试") {
                    loadFailed = false
                    loadDataIfNeeded()
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 10)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(20)
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 48))
                    .foregroundColor(.gray.opacity(0.6))
                Text("暂无推荐内容")
                    .font(.headline)
                Text("去创作你的第一首歌吧")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("为你推荐")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
            
            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]
            
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, action: {})
                        .frame(height: 160)
                }
            }
            .padding(.horizontal, 16)
            
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
    
    private var shouldEnableTapOverlay: Bool {
        tabSelection.selectedTab == 0
    }
    
    private func handleTap(at point: CGPoint, in geometry: GeometryProxy) {
        let columnsCount = 2
        let horizontalPadding: CGFloat = 16
        let columnSpacing: CGFloat = 12
        let rowSpacing: CGFloat = 12
        let cardHeight: CGFloat = 160
        
        let screenWidth = geometry.size.width
        let availableWidth = screenWidth - 2 * horizontalPadding - CGFloat(columnsCount - 1) * columnSpacing
        let cardWidth = availableWidth / CGFloat(columnsCount)
        
        let rowIndex = Int(floor(point.y / (cardHeight + rowSpacing)))
        var colIndex: Int?
        var currentX = horizontalPadding
        for col in 0..<columnsCount {
            let cardXRange = currentX...(currentX + cardWidth)
            if cardXRange.contains(point.x) {
                colIndex = col
                break
            }
            currentX += cardWidth + columnSpacing
        }
        
        guard let colIndex = colIndex,
              rowIndex >= 0,
              rowIndex < Int(ceil(CGFloat(themes.count) / CGFloat(columnsCount))) else {
            print("⚠️ 点击位置无效: \(point), 行列索引无效")
            return
        }
        
        let themeIndex = rowIndex * columnsCount + colIndex
        guard themeIndex >= 0, themeIndex < themes.count else {
            print("⚠️ 点击索引 \(themeIndex) 超出主题数量 \(themes.count)")
            return
        }
        
        let theme = themes[themeIndex]
        triggerTheme(theme)
    }
    
    private func triggerTheme(_ theme: Theme) {
        let freshSongs: [Song]
        if theme.title == "古典音乐" {
            freshSongs = libraryService.songs.filter { $0.style?.lowercased() == "古典" && $0.virtualArtistId == nil }
        } else {
            freshSongs = libraryService.songs.filter { $0.virtualArtistId != nil }
        }
        
        guard let firstSong = freshSongs.first, firstSong.audioUrl?.isEmpty == false else {
            showNoAudioAlertStatic(for: theme.title)
            return
        }
        
        print("🎯 触发主题: \(theme.title), 实际歌曲数: \(freshSongs.count)")
        playbackService.switchToPlaylist(songs: freshSongs, startIndex: 0, openFullPlayer: true)
        lyricsService.fetchLyrics(for: firstSong)
    }
        
    private func loadDataIfNeeded() {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        Task {
            do {
                try await libraryService.loadAISongsFromServer()
            } catch {
                debugLog("⚠️ 加载歌曲失败: \(error.localizedDescription)")
                await MainActor.run { loadFailed = true }
            }
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - ThemeCard（纯 UI，无点击业务逻辑）
struct ThemeCard: View {
    let theme: DiscoveredView.Theme
    let action: () -> Void   // 不再使用
        
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图片
            if let coverURL = theme.coverURL {
                CachedAsyncImage(url: coverURL,
                                 placeholder: { defaultCover },
                                 error: { _ in defaultCover })
                .aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
            } else {
                defaultCover
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            
            // 渐变遮罩
            LinearGradient(
                gradient: Gradient(colors: [.clear, .black.opacity(0.7)]),
                startPoint: .top,
                endPoint: .bottom
            )
            
            // 文本
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let subtitle = theme.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // 按压高亮层
//            if isPressed {
//                Color.black.opacity(0.3)   // 从 0.2 改为 0.3
//                    .cornerRadius(12)
//            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(12)
//        .scaleEffect(isPressed ? 0.96 : 1.0)
//        .animation(.easeOut(duration: 0.1), value: isPressed)
        .contentShape(Rectangle())
//        .onLongPressGesture(minimumDuration: 0.05, maximumDistance: .infinity,
//                            pressing: { pressing in
//                                withAnimation(.easeOut(duration: 0.1)) {
//                                    isPressed = pressing
//                                }
//                            },
//                            perform: {})
//        .simultaneousGesture(
//            TapGesture()
//                .onEnded { }
//        )
    }
    
    private var defaultCover: some View {
        // 保持不变
        let hash = abs(theme.title.hashValue)
        let color1 = Color(hue: Double((hash >> 0) & 0xFF) / 255.0, saturation: 0.6, brightness: 0.8)
        let color2 = Color(hue: Double((hash >> 8) & 0xFF) / 255.0, saturation: 0.7, brightness: 0.7)
        return RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [color1, color2], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                Text(String(theme.title.prefix(1)))
                    .font(.largeTitle)
                    .foregroundColor(.white)
            )
    }
}

// MARK: - UIKit 透明覆盖层（稳定版）
struct UIKitTapOverlay: UIViewRepresentable {
    let isEnabled: Bool
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TapView()
        view.onTap = onTap
        view.isEnabled = isEnabled
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let tapView = uiView as? TapView else { return }
        tapView.isEnabled = isEnabled
        // 关键：当禁用时，完全关闭交互，防止任何事件传递
        uiView.isUserInteractionEnabled = isEnabled
    }
    
    class TapView: UIView {
        var onTap: ((CGPoint) -> Void)?
        var isEnabled: Bool = true {
            didSet {
                self.isUserInteractionEnabled = isEnabled
            }
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard isEnabled else { return false }
            
            // 穿透迷你播放器窗口
            let miniWindow = MiniPlayerWindow.shared
            if !miniWindow.isHidden {
                let pointInScreen = self.convert(point, to: nil)
                if miniWindow.frame.contains(pointInScreen) {
                    return false
                }
            }
            return true
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard isEnabled, let touch = touches.first else { return }
            let location = touch.location(in: self)
            
            let miniWindow = MiniPlayerWindow.shared
            if !miniWindow.isHidden {
                let pointInScreen = self.convert(location, to: nil)
                if miniWindow.frame.contains(pointInScreen) {
                    return
                }
            }
            onTap?(location)
        }
    }
}
// MARK: - 辅助函数
private func showNoAudioAlertStatic(for themeTitle: String) {
    DispatchQueue.main.async {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else { return }
        let alert = UIAlertController(
            title: "无法播放",
            message: "“\(themeTitle)”中的歌曲暂时无法播放，请稍后重试",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        rootVC.present(alert, animated: true)
    }
}
