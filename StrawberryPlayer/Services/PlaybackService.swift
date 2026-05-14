//
//  PlaybackService.swift
//  StrawberryPlayer
//  该模块负责播放列表、播放模式、歌曲切换，并暴露给 UI 层使用。
//  Created by penghui zhang on 2026/2/19.
//

import Foundation
import Combine
import AVFoundation
import SwiftUI
import UIKit

enum PlaybackMode {
    case sequential  // 顺序播放（可上下滑切换）
    case loopOne     // 单曲循环
}

enum PlayerUIMode {
    case hidden
    case mini
    case full
}

enum AudioEffect: String, CaseIterable {
    case off = "关闭"
    case surround3D = "3D环绕"
}

func currentMemoryInMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kerr == KERN_SUCCESS ? Double(info.resident_size) / 1048576.0 : -1
}

@MainActor
class PlaybackService: ObservableObject {
    @Published var currentSong: Song? {
        didSet {
            if let song = currentSong, let metrics = SongMetricsCache.shared.get(songId: song.stableId) {
                self.likeCount = metrics.likes
                self.commentCount = metrics.comments
                self.shareCount = metrics.shares
            }
            if currentSong == nil {
                isPublicPlaylistActive = false
            }
            if !Thread.isMainThread {
                print("❌ currentSong 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
            if let song = currentSong {
                NotificationCenter.default.post(name: .currentSongChanged, object: song)
            }
        }
    }
    @Published var isPlaying = false {
        didSet {
            if !Thread.isMainThread {
                print("❌ isPlaying 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    
    @Published var currentTime: TimeInterval = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ currentTime 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    
    @Published var duration: TimeInterval = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ duration 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var playbackMode: PlaybackMode = .sequential {
        didSet {
            if !Thread.isMainThread {
                print("❌ playbackMode 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var recentlyPlayed: [Song] = [] {
        didSet {
            if !Thread.isMainThread {
                print("❌ recentlyPlayed 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var favorites: [Song] = [] {
        didSet {
            if !Thread.isMainThread {
                print("❌ favorites 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var songComments: [String: [String]] = [:] {
        didSet {
            if !Thread.isMainThread {
                print("❌ songComments 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var likeCount: Int = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ likeCount 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var commentCount: Int = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ commentCount 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var shareCount: Int = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ shareCount 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var accentColor: Color = .clear {
        didSet {
            if !Thread.isMainThread {
                print("❌ accentColor 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var forceCompactOnNextOpen: Bool = false {
        didSet {
            if !Thread.isMainThread {
                print("❌ forceCompactOnNextOpen 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published private(set) var isLoadingSong = false {
        didSet {
            print("🔄 [状态] isLoadingSong: \(isLoadingSong)")
        }
    }
    @Published var currentAudioEffect: AudioEffect = .off {
        didSet {
            applyAudioEffect()
        }
    }
    
    private var currentPlayTask: Task<Void, Never>?  // 存储当前播放任务，用于取消
    
    @Published private(set) var currentIndex = 0
    @Published var playbackErrorMessage: String?
    @Published private(set) var showFullPlayer: Bool = false
    @Published private(set) var isMiniPlayerVisible: Bool = false
    @Published var suppressMiniOnDismiss = false
    
    private var coverDownloadTask: URLSessionTask?
    private var notificationObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private let nowPlayingService = NowPlayingService()
    private var core: PlayerCore
    private var currentTempAudioURL: URL?          // 当前播放的临时音频文件
    private var currentDownloadTask: URLSessionDataTask? // 当前下载任务（用于取消）
    // MARK: - 自动歌词校准
    private var calibratedSongIds = Set<String>()  // 记录已校准的歌曲ID，避免重复
    var libraryService: LibraryService?
    var userService: UserService?   // 用于获取 token
    var songs: [Song] = []
    
    var lyricsService: LyricsService
    private var isSwitchingSong = false
    private var lastSwitchTime: TimeInterval = 0
    private let minSwitchInterval: TimeInterval = 0.5
    // 新增标志位：标记当前播放列表是否为公共版权列表（可被自动刷新）
    private var isPublicPlaylistActive = false
    private var wasPlayingBeforeInterruption = false
    private var isAudioSessionActive = false
    
    private var isInterrupted = false
    private var isPerformingSkip = false
    private var suppressAutoNext = false
    
    // 是否允许迷你播放器显示的标志（由页面控制）
    private var allowMiniPlayerInCurrentPage = false
    private var isSwitchingPlaylist = false
    private var isPlayingNext = false
    
    private var currentLikeTask: URLSessionDataTask?
    private var currentCommentTask: URLSessionDataTask?
    private var audioDownloadTask: URLSessionDownloadTask?
    private var uiModeChangeWorkItem: DispatchWorkItem?
    // 新增常量
    private static let maxCachedAudioFiles = 3   // 原 10 → 3
    private static let maxCachedAudioSize: Int64 = 100 * 1024 * 1024 // 200 MB → 100 MB
    private var loadToken: UUID?
    
    private var colorExtractionTask: Task<Void, Never>?
    private let colorCache = NSCache<NSString, UIColor>()
    
    @Published var lastHandledSongId: String?
    @Published var lastHandledTime: Date = .distantPast
    
    // 专门下载封面，不参与切歌时的 cancel，保证主色提取
    private let coverDownloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 15   // 缩短超时，避免长时间挂起
        return URLSession(configuration: config)
    }()
    
    private var dataSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30   // 原 8 秒改为 30 秒
        config.httpMaximumConnectionsPerHost = 1
        // ✅ 直接跟随全局 URLCache，不再单独创建
        return URLSession(configuration: config)
    }()
    
    @Published var playerUIMode: PlayerUIMode = .hidden {
        didSet {
            // 发送消失通知（当从 mini 变为 hidden 时）
            if oldValue == .mini && playerUIMode == .hidden {
                NotificationCenter.default.post(name: .miniPlayerDidDisappear, object: nil)
            }
            
            switch playerUIMode {
            case .hidden:
                showFullPlayer = false
                isMiniPlayerVisible = false
            case .mini:
                showFullPlayer = false
                isMiniPlayerVisible = true
            case .full:
                showFullPlayer = true
                isMiniPlayerVisible = false
            }
            updateMiniPlayerWindow()
            
            // 发送出现通知（当切换到迷你模式时）
            if playerUIMode == .mini {
                NotificationCenter.default.post(name: .miniPlayerDidAppear, object: nil)
            }
            
            if playerUIMode == .full {
                NotificationCenter.default.post(name: .presentFullPlayer, object: nil)
            }
        }
    }
    
    private func applyAudioEffect() {
        guard let song = currentSong else { return }
        let wasPlaying = isPlaying
        let shouldEnable = currentAudioEffect == .surround3D
        core.setSurroundEnabled(shouldEnable, wasPlaying: wasPlaying, onEnd: { [weak self] in
            self?.playNext()
        })
    }
    
    func setPlayerUIMode(_ mode: PlayerUIMode) {
        // 切换全屏时，强制清除紧凑模式标志
        if mode == .full {
            forceCompactOnNextOpen = false
        }
        
        // 直接设置目标模式，不做中间状态切换
        playerUIMode = mode
        
    }
    
    
    private func resetInternalState() {
        print("🧹 [重置] 清理内部状态标志")
        
        // 取消所有下载任务
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        currentPlayTask?.cancel()
        currentPlayTask = nil
        coverDownloadTask?.cancel()
        coverDownloadTask = nil
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        currentLikeTask?.cancel()
        currentLikeTask = nil
        currentCommentTask?.cancel()
        currentCommentTask = nil
        
        // 清理临时音频文件
        if let tempURL = currentTempAudioURL {
            try? FileManager.default.removeItem(at: tempURL)
            currentTempAudioURL = nil
        }
        
        // 清空主色缓存
        colorCache.removeAllObjects()
        
        // 清理全局 URL 缓存
        URLCache.shared.removeAllCachedResponses()
        
        // 清理歌词缓存
        lyricsService.parsedWordLyricsCache.removeAllObjects()
        lyricsService.clearAllParsedCache()
        
        
        // ✅ 强制取消dataSession的所有任务，并重置dataSession以释放底层buffer
        dataSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        
        
        // 重置状态标志
        isLoadingSong = false
        isSwitchingSong = false
        isPerformingSkip = false
        isPublicPlaylistActive = false
        forceCompactOnNextOpen = false
        
        core.pause()
        isPlaying = false
        
    }
    
    private func updateMiniPlayerWindow() {
        DispatchQueue.main.async {
            let shouldShow = self.isMiniPlayerVisible && !self.showFullPlayer && self.allowMiniPlayerInCurrentPage
            if shouldShow {
                let userService = self.userService ?? UserService()   // 安全解包，避免崩溃
                let content = MiniPlayerContainer()
                    .environmentObject(self)
                    .environmentObject(self.lyricsService)
                    .environmentObject(userService)
                let hosting = UIHostingController(rootView: AnyView(content))
                hosting.view.backgroundColor = .clear
                MiniPlayerWindow.shared.rootViewController = hosting
                MiniPlayerWindow.shared.updateFrame()
                MiniPlayerWindow.shared.isHidden = false
            } else {
                MiniPlayerWindow.shared.isHidden = true
            }
            print("🪟 [MiniPlayerWindow] shouldShow = \(shouldShow), isHidden = \(MiniPlayerWindow.shared.isHidden)")
        }
    }
    
    
    func setAllowMiniPlayer(_ allowed: Bool) {
        allowMiniPlayerInCurrentPage = allowed
        updateMiniPlayerWindow()
    }
    
    
    // 修改 stop() 方法
    func stop() {
        print("🔴 stop() called")
        wasPlayingBeforeInterruption = false
        
        core.pause()
        isPlaying = false
        
        setPlayerUIMode(.hidden)  // 统一隐藏
        
        currentSong = nil
        resetInternalState()
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        core.stop()
        core.resetEngine()   // 新增：彻底清理 AVAudioEngine
        currentTime = 0   // ← 新增
        duration = 0      // ← 新增
        isPlaying = false
    }
    
    func switchToPlaylist(songs: [Song], startIndex: Int = 0, openFullPlayer: Bool = true) {
        
        print("🔄 [switchToPlaylist] 被调用，openFullPlayer=\(openFullPlayer), isSwitchingPlaylist=\(isSwitchingPlaylist)")
        
        guard !isSwitchingPlaylist else {
            print("⚠️ switchToPlaylist 被并发调用，忽略")
            return
        }
        
        isSwitchingPlaylist = true
        
        
        let targetMode: PlayerUIMode = openFullPlayer ? .full : .mini
        // 先关闭当前 UI
        setPlayerUIMode(.hidden)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isSwitchingPlaylist = false
            self?.performSwitchToPlaylist(songs: songs, startIndex: startIndex, targetMode: targetMode)
        }
    }
    
    private func performSwitchToPlaylist(songs: [Song], startIndex: Int, targetMode: PlayerUIMode) {
        print("🎯 [performSwitchToPlaylist] 开始执行，targetMode=\(targetMode), songs.count=\(songs.count)")
        
        resetInternalState()
        forceCompactOnNextOpen = false
        self.songs = songs
        self.currentIndex = startIndex
        self.isPublicPlaylistActive = songs.allSatisfy { $0.virtualArtistId == nil }
        
        setPlayerUIMode(targetMode)
        playSong(at: currentIndex)
    }
    
    
    convenience init() {
        self.init(core: PlayerCore(), userService: nil, lyricsService: LyricsService())
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.colorCache.removeAllObjects()
            self.lyricsService.clearAllParsedCache()
            URLCache.shared.removeAllCachedResponses()
            self.currentDownloadTask?.cancel()
            self.currentLikeTask?.cancel()
            self.currentCommentTask?.cancel()
            self.coverDownloadTask?.cancel()
            self.dataSession.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
        
        // 启动时清理旧文件
        DispatchQueue.global(qos: .background).async {
            Self.cleanLegacyFiles()
        }
        
        // ✅ 强制摧毁所有底层连接，重建洁净的 dataSession
        dataSession.invalidateAndCancel()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60   // 超时时间修改为 60 秒
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = URLCache(memoryCapacity: 2*1024*1024, diskCapacity: 0) // 内存缓存，不写磁盘
        dataSession = URLSession(configuration: config)
        
        // 同时清理 URLSession.shared 上可能存在的所有任务
        URLSession.shared.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        
        // 在 PlaybackService 的 init 或其相关退出登录逻辑中
        NotificationCenter.default.addObserver(forName: .userDidLogout, object: nil, queue: .main) { _ in
            ShareManager.shared.cleanupTencent()
            ShareManager.shared.cleanupWeibo()
        }
    }
    
    static func cleanLegacyFiles() {
        let dir = localAudioDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let keepExts = Set(["mp3", "m4a", "wav", "flac", "aac"])  // ✅ 保留常见音频格式
        for file in files {
            let ext = file.pathExtension.lowercased()
            if !keepExts.contains(ext) {
                try? FileManager.default.removeItem(at: file)
                print("🧹 清理旧缓存: \(file.lastPathComponent)")
            }
        }
    }
    
    
    private func updateAccentColor(for song: Song) {
        let songId = song.stableId
        
        // 1. 内存缓存
        if let cachedColor = colorCache.object(forKey: songId as NSString) {
            DispatchQueue.main.async { [weak self] in
                self?.accentColor = Color(cachedColor)
            }
            return
        }
        
        // 2. UserDefaults 缓存
        if let cachedColor = cachedDominantColor(for: songId) {
            colorCache.setObject(UIColor(cachedColor), forKey: songId as NSString)
            DispatchQueue.main.async { [weak self] in
                self?.accentColor = cachedColor
            }
            return
        }
        
        colorExtractionTask?.cancel()
        coverDownloadTask?.cancel()
        
        guard let url = song.coverURL else {
            DispatchQueue.main.async { [weak self] in
                self?.accentColor = .clear
            }
            return
        }
        
        colorExtractionTask = Task { [weak self] in
            guard let self = self else { return }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".jpg")
            
            // ✅ 修复后的 processDownloadedCover
            func processDownloadedCover(_ fileURL: URL) {
                do {
                    try FileManager.default.moveItem(at: fileURL, to: tempURL)
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    
                    guard let image = UIImage(contentsOfFile: tempURL.path) else { return }
                    let size = CGSize(width: 20, height: 20)
                    let renderer = UIGraphicsImageRenderer(size: size)
                    let thumbnail = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    guard let uiColor = thumbnail.averageColor else { return }
                    let color = Color(uiColor)
                    
                    // ✅ 切换到主线程，直接操作 MainActor 属性和缓存
                    DispatchQueue.main.async {
                        self.colorCache.setObject(uiColor, forKey: songId as NSString)
                        self.cacheDominantColor(color, for: songId)
                        self.accentColor = color
                    }
                } catch {
                    print("封面下载后处理失败: \(error.localizedDescription)")
                }
            }
            
            let task = coverDownloadSession.downloadTask(with: url) { fileURL, _, error in
                if error != nil {
                    let retryTask = self.coverDownloadSession.downloadTask(with: url) { retryURL, _, retryError in
                        guard let retryURL = retryURL, retryError == nil else { return }
                        processDownloadedCover(retryURL)
                    }
                    retryTask.resume()
                    return
                }
                guard let fileURL = fileURL else { return }
                processDownloadedCover(fileURL)
            }
            self.coverDownloadTask = task
            task.resume()
        }
    }
    
    private func cacheDominantColor(_ color: Color, for songId: String) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let dict: [String: CGFloat] = ["r": r, "g": g, "b": b]
        UserDefaults.standard.set(dict, forKey: "dominantColor_\(songId)")
    }
    
    private func cachedDominantColor(for songId: String) -> Color? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "dominantColor_\(songId)") as? [String: CGFloat],
              let r = dict["r"], let g = dict["g"], let b = dict["b"] else { return nil }
        return Color(red: r, green: g, blue: b)
    }
    
    // 修改 cleanupAudioCacheIfNeeded 方法（在 PlaybackService.swift 中）
    private func cleanupAudioCacheIfNeeded() {
        let audioDir = PlaybackService.localAudioDirectory
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]) else { return }
        
        // ✅ 保护所有已在库中且音频指向本地的歌曲文件
        let allLibrarySongs = libraryService?.songs ?? []
        
        // 🔥 关键修复：如果库还没加载，暂时不清理任何文件
        guard !allLibrarySongs.isEmpty else {
            print("⚠️ 歌曲库尚未加载，跳过音频缓存清理")
            return
        }
        
        let protectedPaths = Set(allLibrarySongs.compactMap { song -> String? in
            guard let urlString = song.audioUrl,
                  let url = URL(string: urlString),
                  url.isFileURL else { return nil }
            return url.path
        })
        
        // 按创建时间排序
        let sortedFiles = files.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 < date2
        }
        
        var totalSize: Int64 = 0
        var filesToDelete: [URL] = []
        
        for file in sortedFiles {
            if protectedPaths.contains(file.path) { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            totalSize += Int64(size)
            if sortedFiles.count > Self.maxCachedAudioFiles || totalSize > Self.maxCachedAudioSize {
                filesToDelete.append(file)
            }
        }
        
        for file in filesToDelete {
            try? fileManager.removeItem(at: file)
            print("🧹 清理过期音频缓存: \(file.lastPathComponent)")
        }
    }
    
    // 获取当前歌曲的喜欢数
    func fetchLikeCount(for song: Song, completion: ((Int) -> Void)? = nil) {
        Task {
            do {
                guard let token = userService?.accessToken else {
                    print("❌ fetchLikeCount: 未登录")
                    return
                }
                let encoded = song.stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.stableId
                let urlString = baseURL + "/api/favorites/count?identifier=" + encoded
                let data = try await performAuthenticatedRequest(urlString: urlString, token: token)
                if let count = try? JSONDecoder().decode(Int.self, from: data) {
                    
                    await MainActor.run {
                        SongMetricsCache.shared.set(songId: song.stableId, likes: count)
                        if self.currentSong?.stableId == song.stableId {
                            self.likeCount = count
                        }
                        completion?(count)
                    }
                    
                    //                    await MainActor.run { self.likeCount = count }
                } else {
                    print("❌ fetchLikeCount 解析失败")
                }
            } catch {
                print("❌ fetchLikeCount 失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 获取当前歌曲的评论数
    func fetchCommentCount(for song: Song, completion: ((Int) -> Void)? = nil) {
        Task {
            do {
                guard let token = userService?.accessToken else {
                    print("❌ fetchCommentCount: 未登录")
                    return
                }
                let encoded = song.stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.stableId
                let urlString = baseURL + "/api/comments/count?identifier=" + encoded
                let data = try await performAuthenticatedRequest(urlString: urlString, token: token)
                if let count = try? JSONDecoder().decode(Int.self, from: data) {
                    
                    await MainActor.run {
                        SongMetricsCache.shared.set(songId: song.stableId, comments: count)
                        if self.currentSong?.stableId == song.stableId {
                            self.commentCount = count
                        }
                        completion?(count)
                    }
                    //                    await MainActor.run { self.commentCount = count }
                } else {
                    print("❌ fetchCommentCount 解析失败")
                }
            } catch {
                print("❌ fetchCommentCount 失败: \(error.localizedDescription)")
            }
        }
    }
    
    // 获取当前歌曲的分享数
    func fetchShareCount(for song: Song, completion: ((Int) -> Void)? = nil) {
        Task {
            do {
                guard let token = userService?.accessToken else {
                    print("❌ fetchShareCount: 未登录")
                    return
                }
                let encoded = song.stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.stableId
                let urlString = baseURL + "/api/shares/count?identifier=" + encoded
                let data = try await performAuthenticatedRequest(urlString: urlString, token: token)
                if let count = try? JSONDecoder().decode(Int.self, from: data) {
                    
                    await MainActor.run {
                        SongMetricsCache.shared.set(songId: song.stableId, shares: count)
                        if self.currentSong?.stableId == song.stableId {
                            self.shareCount = count
                        }
                        completion?(count)
                    }
                    //                    await MainActor.run { self.shareCount = count }
                } else {
                    print("❌ fetchShareCount 解析失败")
                }
            } catch {
                print("❌ fetchShareCount 失败: \(error.localizedDescription)")
            }
        }
    }
    
    func refreshMetrics(for song: Song, completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        fetchLikeCount(for: song) { _ in group.leave() }
        group.enter()
        fetchCommentCount(for: song) { _ in group.leave() }
        group.enter()
        fetchShareCount(for: song) { _ in group.leave() }
        group.notify(queue: .main) { completion?() }
    }
    
    func incrementShareCount(for song: Song) {
        Task {
            do {
                guard let token = userService?.accessToken else { return }
                let encoded = song.stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.stableId
                let urlString = baseURL + "/api/shares/increment?identifier=" + encoded
                guard let url = URL(string: urlString) else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await dataSession.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    // 成功后重新拉取准确计数
//                    await MainActor.run { self.fetchShareCount(for: song) }

                    let newCount = (SongMetricsCache.shared.get(songId: song.stableId)?.shares ?? 0) + 1
                        SongMetricsCache.shared.set(songId: song.stableId, shares: newCount)
                        if self.currentSong?.stableId == song.stableId {
                            await MainActor.run { self.shareCount = newCount }
                        }
                    
                }
            } catch {
                print("❌ incrementShareCount 失败: \(error)")
            }
        }
    }
    
    private var baseURL: String {
        AppConfig.baseURL
    }
    
    
    
    private func reloadCurrentSong() {
        guard let song = currentSong,
              let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        
        // 记录当前播放状态
        let wasPlaying = isPlaying
        
        // 重新加载并播放（playSong 内部会调用 core.play()）
        playSong(at: index)
        
        // 如果之前是暂停状态，则立即暂停
        if !wasPlaying {
            core.pause()
            isPlaying = false
        }
    }
    
    
    
    func configure(userService: UserService, libraryService: LibraryService) {
        self.userService = userService
        self.libraryService = libraryService
        if userService.isLoggedIn {
            syncFavorites()
        }
        
    }
    
    
    // 从后端同步当前用户的收藏列表
    func syncFavorites() {
        Task {
            do {
                guard let token = userService?.accessToken else {
                    print("❌ syncFavorites: 未登录")
                    return
                }
                let urlString = baseURL + "/api/favorites"
                let data = try await performAuthenticatedRequest(urlString: urlString, token: token)
                let decoder = JSONDecoder()
                // 确保 FavoriteResponse 结构体存在（已在文件全局定义）
                let favoritesResponse = try decoder.decode([FavoriteResponse].self, from: data)
                var fetchedSongs: [Song] = []
                for fav in favoritesResponse {
                    if let existing = libraryService?.songs.first(where: { $0.stableId == fav.songIdentifier }) {
                        fetchedSongs.append(existing)
                    } else {
                        let placeholder = Song(
                            id: fav.songIdentifier,
                            title: fav.songTitle,
                            artist: fav.songArtist,
                            album: "",
                            duration: 0,
                            audioUrl: "strawberry://placeholder/\(fav.songIdentifier)",
                            coverUrl: nil,
                            lyrics: nil,
                            virtualArtist: nil,
                            creatorId: nil,
                            isUserGenerated: false,
                            wordLyrics: nil,
                            createdAt: nil,
                            style: nil
                        )
                        fetchedSongs.append(placeholder)
                    }
                }
                await MainActor.run {
                    self.favorites = fetchedSongs
                }
                print("✅ syncFavorites 完成，共 \(fetchedSongs.count) 首收藏")
            } catch {
                print("❌ syncFavorites 失败: \(error.localizedDescription)")
                // ✅ 静默失败，不发送任何通知，保持已登录状态
            }
        }
    }
    // 解析收藏列表
    struct FavoriteResponse: Codable {
        let songIdentifier: String
        let songTitle: String
        let songArtist: String
    }
    
    // 发表评论
    func postComment(_ text: String, for song: Song, completion: @escaping (Result<Comment, Error>) -> Void) {
        guard let token = userService?.accessToken else {
            completion(.failure(APIError.unauthorized))
            return
        }
        
        
        let urlString = baseURL + "/api/comments"
        guard let url = URL(string: urlString) else {
            completion(.failure(APIError.invalidURL))
            return
        }
        print("🌐 postComment URL: \(urlString)")
        
        
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        
        let body: [String: String] = [
            "identifier": song.stableId,
            "content": text
        ]
        request.httpBody = try? JSONEncoder().encode(body)
        
        
        dataSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ [postComment] 网络错误: \(error)")
                    completion(.failure(error))
                    return
                }
                
                
                // 确保能获取到 HTTP 响应
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ [postComment] 无效响应")
                    completion(.failure(APIError.noData))
                    return
                }
                
                // ✅ 首先检查 401 未授权
                if httpResponse.statusCode == 401 {
                    // 静默刷新 token，不弹窗
                    Task {
                        do {
                            _ = try await self.userService?.refreshAccessToken(silent: true)
                        } catch {
                            // 刷新失败，忽略，等用户下一次主动操作时自然会提示
                        }
                    }
                    completion(.failure(APIError.unauthorized))
                    return
                }
                
                guard let data = data else {
                    print("❌ [postComment] 无数据")
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 打印调试信息
                if let responseStr = String(data: data, encoding: .utf8) {
                    print("📥 [postComment] 状态码: \(httpResponse.statusCode), 响应: \(responseStr)")
                    
                }
                
                // 处理非成功状态码
                guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                    // 尝试从响应中提取错误信息
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let reason = errorJson["reason"] as? String {
                        completion(.failure(NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: reason])))
                    } else {
                        completion(.failure(NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败"])))
                    }
                    return
                }
                
                
                // 正常解析
                
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let comment = try decoder.decode(Comment.self, from: data)
                    
                    
                    // ✅ 新增：更新评论计数缓存
                    // 更新评论计数缓存
                        let currentComments = SongMetricsCache.shared.get(songId: song.stableId)?.comments ?? 0
                        SongMetricsCache.shared.set(songId: song.stableId, comments: currentComments + 1)
                        if self.currentSong?.stableId == song.stableId {
                            self.commentCount = currentComments + 1   // ✅ 直接赋值，已在主线程
                        }
                    
                    completion(.success(comment))
                } catch {
                    print("❌ 解析评论失败: \(error)")
                    completion(.failure(error))
                }
                
            }
        }.resume()
    }
    
    
    
    // 添加评论
    func addComment(_ text: String, for song: Song) {
        let key = song.id
        var comments = songComments[key] ?? []
        comments.append(text)
        songComments[key] = comments
        print("评论已保存到键 \(key)，当前评论数：\(comments.count)")
    }
    
    func comments(for song: Song) -> [String] {
        return songComments[song.id] ?? []
    }
    
    
    func setUserService(_ userService: UserService) {
        self.userService = userService
    }
    
    // 收藏歌曲
    func toggleFavorite(_ song: Song, completion: @escaping (Result<Bool, Error>) -> Void) {
        // 未登录时直接提示登录
        guard let token = userService?.accessToken else {
            NotificationCenter.default.post(name: .requireLogin, object: nil)
            completion(.failure(APIError.unauthorized))
            return
        }
        
        let urlString = baseURL + "/api/favorites"
        let body: [String: String] = [
            "identifier": song.stableId,
            "title": song.title,
            "artist": song.artist
        ]
        guard let jsonData = try? JSONEncoder().encode(body) else {
            completion(.failure(APIError.badRequest))
            return
        }
        
        Task {
            do {
                // 使用统一的认证请求，自动处理 401 刷新 + 重试
                let data = try await performAuthenticatedRequest(
                    urlString: urlString,
                    method: "POST",
                    body: jsonData,
                    token: token
                )
                
                // 服务器返回 2xx 即视为操作成功
                await MainActor.run {
                    // 更新本地收藏状态
                    if self.isFavorite(song) {
                        self.favorites.removeAll { $0.id == song.id }
                        self.likeCount = max(0, self.likeCount - 1)
                    } else {
                        self.favorites.append(song)
                        self.likeCount += 1
                    }
                    completion(.success(true))
                    // 可选：异步请求精确计数（保持原有行为）
                    self.fetchLikeCount(for: song)
                }
                
            } catch {
                await MainActor.run {
                    print("toggleFavorite failed: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }
    
    // 检查收藏状态（现在需要从服务器同步，但本地已维护 favorites 数组）
    func isFavorite(_ song: Song) -> Bool {
        return favorites.contains { $0.stableId == song.stableId }
    }
    
    // 同步收藏列表（可以在登录成功后调用）
    func syncFavorites(completion: ((Bool) -> Void)? = nil) {
        guard let token = userService?.accessToken else {
            completion?(false)
            return
        }
        let urlString = baseURL + "/api/favorites"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        dataSession.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data else { return }
            do {
                let favoriteItems = try JSONDecoder().decode([FavoriteResponse].self, from: data)
                // 将 FavoriteResponse 转换为 Song 对象（可能需要从 LibraryService 获取完整 Song）
                // 简单起见，你可以只存储标识，然后在 isFavorite 中检查标识
                DispatchQueue.main.async {
                    // 这里需要将 favoriteItems 转换为本地的 Song 列表
                    // 你可能需要根据歌曲 URL 从 LibraryService 中查找对应的 Song
                    // 暂时可以只存储 URL 字符串到另一个 Set 中，用于快速判断
                }
            } catch {
                print("解析收藏列表失败: \(error)")
            }
        }.resume()
    }
    
    
    init(core: PlayerCore = PlayerCore(), userService: UserService? = nil, lyricsService: LyricsService) {
        colorCache.countLimit = 5
        colorCache.totalCostLimit = 512 * 1024   // 1 MB → 512 KB
        self.core = core
        self.userService = userService
        self.lyricsService = lyricsService
        
        // 以下为原有初始化逻辑，保持不变
        core.$isPlaying.assign(to: &$isPlaying)
        // ✅ 修正：传入 lyricsService 参数
        nowPlayingService.startObserving(playbackService: self, lyricsService: lyricsService)
        
        // 恢复进度订阅：10fps 更新，避免过度刷新，同时驱动歌词索引
        core.$currentTime
            .throttle(for: .seconds(1.0 / 30.0), scheduler: DispatchQueue.main, latest: true)   // 30fps，丝滑且不爆内存
            .removeDuplicates(by: { abs($0 - $1) < 0.0005 })   // 忽略极微小变化，避免无意义刷新
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
                self?.lyricsService.updateCurrentIndex(with: time)
            }
            .store(in: &cancellables)
        
        core.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.duration = duration
            }
            .store(in: &cancellables)
        
        
        $currentSong
            .compactMap { $0 }
            .sink { [weak self] song in
                self?.updateAccentColor(for: song)
            }
            .store(in: &cancellables)
        
        let loginObserver = NotificationCenter.default.addObserver(forName: .userDidLogin, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.userService != nil else { return }
            self.syncFavorites()
        }
        notificationObservers.append(loginObserver)
        
        
        // 监听歌曲列表变化（公共版权作品增删）
        let songsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .songsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPublicPlaylist()
        }
        notificationObservers.append(songsDidChangeObserver)
        
        // 启动时清理过期的音频缓存
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.cleanupAudioCacheIfNeeded()
        }
        
    }
    
    
    
    private func refreshPublicPlaylist() {
        // ✅ 只有在当前播放列表确实是公共版权列表时才刷新
        guard isPublicPlaylistActive else { return }
        
        guard let librarySongs = libraryService?.songs else { return }
        
        let newPublicSongs = librarySongs.filter { $0.virtualArtistId == nil }
        let oldIds = self.songs.map { $0.id }
        let newIds = newPublicSongs.map { $0.id }
        
        // 只有列表真正变化时才更新
        guard oldIds != newIds else { return }
        
        // ✅ 只更新 songs 数组，不干扰当前播放状态
        self.songs = newPublicSongs
    }
    
    @objc private func handleUserDidLogin() {
        // 只有 userService 已注入时才同步，否则等待 configure
        guard userService != nil else { return }
        syncFavorites()
    }
    
    func ensureAudioSessionIsActive() {
        if !isAudioSessionActive {
            setupAudioSession()
        }
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // 如果已经配置且激活，直接返回
        if session.category == .playback && session.isOtherAudioPlaying == false {
            // 已经激活，无需重复设置
            isAudioSessionActive = true
            return
        }
        do {
            print("🔊 [音频会话] 开始配置，当前状态: \(session.isOtherAudioPlaying ? "其他音频播放中" : "空闲")")
            // 如果会话已激活，先尝试停用（但通常不需要）
            if session.isOtherAudioPlaying {
                print("🎧 其他音频正在播放，尝试兼容")
            }
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            print("✅ 音频会话激活成功，采样率: \(session.sampleRate)")
            isAudioSessionActive = true
        } catch {
            print("❌ 音频会话激活失败: \(error)")
            // 不再立即重试，等待用户手动播放时再次尝试
            isAudioSessionActive = false
        }
        
        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            
            if type == .began {
                print("🔇 音频中断开始")
                self.wasPlayingBeforeInterruption = self.isPlaying
                self.isInterrupted = true
                self.suppressAutoNext = true
                self.core.pause()
            } else if type == .ended {
                print("🔊 音频中断结束")
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    print("✅ 中断后会话重新激活成功")
                } catch {
                    print("❌ 中断后会话激活失败: \(error)")
                    self.wasPlayingBeforeInterruption = false
                    self.isInterrupted = false
                    self.suppressAutoNext = false
                    return
                }
                let shouldResume = self.wasPlayingBeforeInterruption &&
                self.currentSong != nil &&
                !self.isLoadingSong &&
                !self.isSwitchingSong &&
                !self.isPerformingSkip
                if shouldResume {
                    let songId = self.currentSong?.stableId
                    // ✅ 恢复前先抑制自动切歌，延迟后恢复播放
                    self.suppressAutoNext = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        if self.currentSong?.stableId == songId,
                           !self.isLoadingSong,
                           !self.isSwitchingSong {
                            self.core.play()
                            self.isPlaying = true
                            print("🎵 中断后恢复播放: \(self.currentSong?.title ?? "")")
                        }
                        self.suppressAutoNext = false
                    }
                } else {
                    print("⚠️ 不满足恢复条件，不自动播放")
                    self.suppressAutoNext = false
                }
                self.wasPlayingBeforeInterruption = false
                self.isInterrupted = false
            }
        }
        
        //        let interruptionObserver = NotificationCenter.default.addObserver(
        //            forName: AVAudioSession.interruptionNotification,
        //            object: nil,
        //            queue: .main
        //        ) { [weak self] notification in
        //            guard let self = self,
        //                  let userInfo = notification.userInfo,
        //                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
        //                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        //
        //            if type == .began {
        //                print("🔇 音频中断开始")
        //                self.wasPlayingBeforeInterruption = self.isPlaying
        //                self.isInterrupted = true
        //                self.suppressAutoNext = true
        //                self.core.pause()
        //
        //            } else if type == .ended {
        //                print("🔊 音频中断结束")
        //
        //                // 重新激活音频会话
        //                do {
        //                    try AVAudioSession.sharedInstance().setActive(true)
        //                    print("✅ 中断后会话重新激活成功")
        //                } catch {
        //                    print("❌ 中断后会话激活失败: \(error)")
        //                    self.wasPlayingBeforeInterruption = false
        //                    self.isInterrupted = false
        //                    self.suppressAutoNext = false
        //                    return
        //                }
        //
        //                // 检查是否需要恢复播放
        //                let shouldResume = self.wasPlayingBeforeInterruption &&
        //                self.currentSong != nil &&
        //                !self.isLoadingSong &&
        //                !self.isSwitchingSong &&
        //                !self.isPerformingSkip
        //
        //                if shouldResume {
        //                    let songId = self.currentSong?.stableId
        //                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        //                        if self.currentSong?.stableId == songId,
        //                           !self.isLoadingSong,
        //                           !self.isSwitchingSong {
        //                            self.core.play()
        //                            self.isPlaying = true
        //                            print("🎵 中断后恢复播放: \(self.currentSong?.title ?? "")")
        //                        }
        //                        // 恢复播放后立即允许切歌，不再延迟
        //                        self.suppressAutoNext = false
        //                    }
        //                } else {
        //                    print("⚠️ 不满足恢复条件，不自动播放")
        //                    self.suppressAutoNext = false
        //                }
        //
        //                // 重置中断标志
        //                self.wasPlayingBeforeInterruption = false
        //                self.isInterrupted = false
        //            }
        //        }
        notificationObservers.append(interruptionObserver)
    }
    
    private func recalibrateLyricsAfterInterruption() {
        guard let currentSong = currentSong else { return }
        
        // 获取音频 URL（本地文件）
        guard let audioUrlString = currentSong.audioUrl,
              let audioURL = URL(string: audioUrlString),
              audioURL.isFileURL || FileManager.default.fileExists(atPath: audioURL.path) else {
            print("⚠️ 无法获取本地音频文件，跳过歌词重校准")
            return
        }
        
        // 获取第一个词的开始时间
        guard let firstWord = currentSong.cachedWordLyrics?.first?.first else {
            print("⚠️ 无逐词数据，跳过重校准")
            return
        }
        
        // 重置校准标记（允许重新校准）
        calibratedSongIds.remove(currentSong.id)
        
        Task {
            await lyricsService.autoCalibrateOffset(
                for: currentSong,
                audioURL: audioURL,
                firstWordStartTime: firstWord.startTime
            )
            print("✅ 中断后歌词重校准完成")
        }
    }
    
    func setPlaylist(songs: [Song], startIndex: Int) {
        print("📋 setPlaylist 被调用，歌曲数: \(songs.count), 起始索引: \(startIndex)")
        
        // 清理当前临时文件
        if let tempURL = currentTempAudioURL {
            try? FileManager.default.removeItem(at: tempURL)
            currentTempAudioURL = nil
        }
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        
        // 彻底停止当前播放
        core.pause()
        isPlaying = false
        currentTime = 0
        duration = 0
        
        
        // 更新播放列表
        self.songs = songs
        self.currentIndex = startIndex
        
        // ✅ 判断是否为公共版权列表（所有歌曲的 virtualArtistId 均为 nil）
        isPublicPlaylistActive = songs.allSatisfy { $0.virtualArtistId == nil }
        
        // 开始新歌曲加载
        playSong(at: startIndex)
    }
    
    internal func playSong(at index: Int) {
        
        print("💾 [playSong入口] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB, 歌曲: \(songs[index].title)")
        
        // 取消正在进行的音频下载
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        
        // 清理上一次的临时音频
        if let tempURL = currentTempAudioURL {
            try? FileManager.default.removeItem(at: tempURL)
            currentTempAudioURL = nil
        }
        
        // 如果是同一首歌且正在播放，才跳过
        if index == currentIndex, currentSong != nil, isPlaying {
            print("⏭️ 重复加载检测：索引相同且正在播放，跳过")
            return
        }
        
        // 如果正在加载或切换，但请求的是不同歌曲，则强制取消并继续
        if (isLoadingSong || isSwitchingSong) && index != currentIndex {
            print("🔄 检测到新歌曲请求，取消当前加载")
            currentPlayTask?.cancel()
            currentPlayTask = nil
            isLoadingSong = false
            isSwitchingSong = false
        }
        
        // 原有入口检查
        guard !isLoadingSong, !isSwitchingSong else {
            print("⚠️ 防重入拦截：未能自动恢复，请检查状态")
            return
        }
        
        let oldIndex = currentIndex
        let oldSongTitle = currentSong?.title ?? "nil"
        let isPlayingNow = isPlaying
        print("🎬 playSong 入口: index=\(index), oldIndex=\(oldIndex), currentSong=\(oldSongTitle), isPlaying=\(isPlayingNow), isLoadingSong=\(isLoadingSong)")
        
        // 重复加载检查：只有目标索引与旧索引相同且已有歌曲在播放时才跳过
        if index == oldIndex, currentSong != nil, isPlaying {
            print("⏭️ 重复加载检测：索引相同且正在播放，跳过")
            return
        }
        
        // 确保在主线程
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.playSong(at: index)
            }
            return
        }
        
        // 防重入
        guard !isLoadingSong, !isSwitchingSong else {
            print("⚠️ 防重入拦截: isLoadingSong=\(isLoadingSong), isSwitchingSong=\(isSwitchingSong)")
            return
        }
        
        // 索引校验
        guard index >= 0 && index < songs.count else {
            print("❌ 索引越界: index=\(index), songs.count=\(songs.count)")
            if !songs.isEmpty {
                currentIndex = 0
                playSong(at: 0)
            } else {
                pause()
            }
            return
        }
        
        let song = songs[index]
        print("🎵 准备播放歌曲: \(song.title), audioUrl: \(song.audioUrl ?? "nil")")
        
        
        // ─── 新增：生成新的加载令牌，并立即停止所有旧音频 ───
        let token = UUID()
        loadToken = token
        
        core.stop()
        
        // ✅ 强制触发内存回收
        if let warning = UIApplication.didReceiveMemoryWarningNotification as? Notification.Name {
            NotificationCenter.default.post(name: warning, object: nil)
        }
        
        // ✅ 仅取消任务，不重建 session
        URLSession.shared.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        
        
        // 清空颜色缓存
        colorCache.removeAllObjects()
        
        // 取消所有网络任务，释放内存
        coverDownloadTask?.cancel()
        coverDownloadTask = nil
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        currentLikeTask?.cancel()
        currentLikeTask = nil
        currentCommentTask?.cancel()
        currentCommentTask = nil
        colorExtractionTask?.cancel()
        colorExtractionTask = nil
        
        URLSession.shared.getAllTasks { tasks in tasks.forEach { $0.cancel() } } // 已有的
        
        // 同曲重播保护：如果目标歌曲与当前相同且已有逐字歌词，则不清空，避免歌词消失
        let sameSong = (currentSong?.id == song.id) && !lyricsService.wordLyrics.isEmpty
        if !sameSong {
            lyricsService.reset()
        }
        
        // 立即停止当前播放状态
        isPlaying = false
        currentTime = 0
        duration = 0
        
        // 取消旧的下载任务
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        
        // 切歌时清除上一首歌的解析缓存
        if let oldSongId = currentSong?.id {
            lyricsService.clearParsedCache(for: oldSongId)
        }
        
        let previousSongId = currentSong?.id
        
        currentSong = song
        
        // 只有歌曲实际变化时才重置偏移，同曲重播保留已校准的偏移
        if previousSongId != song.id {
            lyricsService.lyricOffset = 0
        }
        
        
        // 取消之前的播放任务
        currentPlayTask?.cancel()
        
        // 创建新任务
        currentPlayTask = Task { [weak self] in
            guard let self = self else { return }
            
            // ─── 令牌检查点 1 ───
            guard self.loadToken == token else {
                print("⏹️ 播放任务过期，令牌不匹配（点1）")
                return
            }
            
            await MainActor.run {
                self.setLoading(true)
                self.setCurrentIndex(index)
            }
            
            defer {
                Task { @MainActor in
                    self.setLoading(false)
                }
            }
            
            if Task.isCancelled {
                print("⏹️ 任务被取消")
                return
            }
            
            // 获取封面主色
            self.updateAccentColor(for: song)
            
            if Task.isCancelled { return }
            
            // 切换歌曲时取消所有进行中的网络请求
            currentLikeTask?.cancel()
            currentLikeTask = nil
            currentCommentTask?.cancel()
            currentCommentTask = nil
            
            // 获取收藏/评论数
            if let userService = self.userService, userService.isLoggedIn {
                self.fetchLikeCount(for: song)
                self.fetchCommentCount(for: song)
            } else {
                await MainActor.run {
                    self.likeCount = 0
                    self.commentCount = 0
                }
            }
            
            if Task.isCancelled { return }
            
            // 更新最近播放
            await MainActor.run {
                self.recentlyPlayed.removeAll { $0.id == song.id }
                self.recentlyPlayed.insert(song, at: 0)
                if self.recentlyPlayed.count > 20 {
                    self.recentlyPlayed.removeLast()
                }
            }
            
            if Task.isCancelled { return }
            
            // ─── 令牌检查点 2：准备解析音频 URL ───
            guard self.loadToken == token else {
                print("⏹️ 播放任务过期，令牌不匹配（点2）")
                return
            }
            
            // ─── 音频 URL 解析 ───
            let playURL: URL
            if let streamStr = song.streamURL, let sURL = absoluteURL(from: streamStr) {
                print("🎵 使用后端转码链接: \(sURL)")
                playURL = sURL
            } else if let rawUrl = song.audioUrl, let remoteURL = absoluteURL(from: rawUrl) {
                print("⚠️ 无转码链接，使用原始音频: \(remoteURL)")
                playURL = remoteURL
            } else {
                print("❌ 歌曲音频URL无效")
                await MainActor.run {
                    self.playbackErrorMessage = "歌曲“\(song.title)”的音频链接无效"
                    self.pause()
                }
                return
            }
            
            // ✅ 构造本地缓存路径，优先使用本地文件
            let localURL = PlaybackService.localAudioURL(for: song.id, extension: playURL.pathExtension)
            let finalPlayURL: URL          // 仍然声明为 let，但确保所有路径赋值
            
            
            // 增加关键判断：如果 playURL 已经是本地文件，直接使用
            if playURL.isFileURL {
                finalPlayURL = playURL
                print("📁 使用本地音频文件: \(finalPlayURL.path)")
            } else if FileManager.default.fileExists(atPath: localURL.path) {
                finalPlayURL = localURL
                print("💾 命中本地缓存: \(localURL)")
            } else {
                print("🎧 本地无缓存，直接流播: \(playURL.absoluteString)")
                finalPlayURL = playURL   // 直接使用远程 URL
                // 后台静默下载（不阻塞播放）
                if !playURL.isFileURL {
                    downloadInBackground(from: playURL, to: localURL, for: song.id)
                }
            }
            
            // 统一更新歌曲的 audioUrl（只需要执行一次）
            await MainActor.run {
                var updatedSong = song
                updatedSong.audioUrl = playURL.absoluteString
                var updatedSongs = self.songs
                if let idx = updatedSongs.firstIndex(where: { $0.id == song.id }) {
                    updatedSongs[idx] = updatedSong
                }
                self.songs = updatedSongs
                if self.currentSong?.id == song.id {
                    self.currentSong = updatedSong
                }
            }
            
            if Task.isCancelled { return }
            
            // ─── 令牌检查点 3：准备加载到 core 之前 ───
            guard self.loadToken == token else {
                print("⏹️ 播放任务过期，令牌不匹配（点3）")
                return
            }
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.loadToken == token else {
                    print("⏹️ 播放任务过期，令牌不匹配（core.load 前）")
                    return
                }
                
                do {
                    print("💾 [加载到PlayerCore前] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")
                    try self.core.load(
                        url: finalPlayURL,
                        onEnd: { [weak self] in
                            DispatchQueue.main.async {
                                guard let self = self,
                                      self.loadToken == token,
                                      !self.suppressAutoNext,
                                      !self.isSwitchingSong,
                                      !self.isPlayingNext else { return }
                                self.playNext()
                            }
                        },
                        onReady: { [weak self] in
                            guard let self = self,self.loadToken == token else { return }
                            
                            // ✅ 确保音频会话激活（stop可能已将其停用）
                            //                            if !self.isAudioSessionActive {
                            //                                self.setupAudioSession()
                            //                            }
                            
                            if self.lyricsService.wordLyrics.isEmpty {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    self.lyricsService.applyImmediateAlignment(currentPlaybackTime: self.currentTime)
                                    self.lyricsService.updateCurrentIndex(with: self.currentTime)
                                }
                            } else {
                                self.lyricsService.applyImmediateAlignment(currentPlaybackTime: self.currentTime)
                                self.lyricsService.updateCurrentIndex(with: self.currentTime)
                            }
                            
                            self.core.play()
                        }
                    )
                    print("💾 [加载到PlayerCore后] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")
                } catch {
                    print("❌ 加载歌曲失败: \(error)")
                    self.pause()
                }
            }
        }
    }
    
    func playSongInCurrentList(_ song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            // ❌ 移除这行：currentIndex = index
            playSong(at: index)  // 此方法内部会设置 currentSong 并播放
        } else {
            // 如果不在当前列表，则替换为单曲列表（降级方案）
            setPlaylist(songs: [song], startIndex: 0)
            play()
        }
    }
    
    func play() {
        // 1. 清除可能阻塞重播的状态
        if isLoadingSong || isSwitchingSong {
            currentPlayTask?.cancel()
            currentPlayTask = nil
            isLoadingSong = false
            isSwitchingSong = false
        }
        
        self.suppressAutoNext = false
        print("▶️ [播放] 调用, isAudioSessionActive=\(isAudioSessionActive), currentTime=\(currentTime), duration=\(duration), isPlaying=\(isPlaying)")
        
        // 2. 若音频会话未激活，先激活再播放
        if !isAudioSessionActive {
            isAudioSessionActive = true
        }
        
        // 3. 检查是否播放完毕
        let finished = (duration > 0 && currentTime >= duration - 0.5) || core.isAtEnd
        if let song = currentSong, !isPlaying, finished {
            print("🔄 歌曲已播放完毕，重新开始: \(song.title)")
            playSong(at: currentIndex)
            return
        }
        
        core.play()
    }
    
    
    private func downloadFromICloud(_ url: URL, completion: @escaping (Bool) -> Void) {
        // 1. 检查文件是否已在本地（完全下载）
        if FileManager.default.fileExists(atPath: url.path) {
            completion(true)
            return
        }
        
        // 2. 启动下载（如果尚未开始）
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            print("无法启动 iCloud 下载: \(error)")
            completion(false)
            return
        }
        
        // 3. 使用 NSMetadataQuery 监听下载进度
        let query = NSMetadataQuery()
        // 只观察这一个文件的状态
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, url as NSURL)
        query.valueListAttributes = [NSMetadataUbiquitousItemDownloadingStatusKey]
        
        var observer: NSObjectProtocol?
        var timeoutWorkItem: DispatchWorkItem?
        
        // 超时处理（例如 30 秒）
        timeoutWorkItem = DispatchWorkItem { [weak query] in
            observer.flatMap { NotificationCenter.default.removeObserver($0) }
            query?.stop()
            DispatchQueue.main.async { completion(false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeoutWorkItem!)
        
        // 监听查询结果
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak query] notification in
            guard let query = query else { return }
            for idx in 0..<query.resultCount {
                guard let item = query.result(at: idx) as? NSMetadataItem else { continue }
                if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String {
                    switch status {
                    case NSMetadataUbiquitousItemDownloadingStatusCurrent,
                    NSMetadataUbiquitousItemDownloadingStatusDownloaded:
                        // 下载完成
                        timeoutWorkItem?.cancel()
                        observer.flatMap { NotificationCenter.default.removeObserver($0) }
                        query.stop()
                        DispatchQueue.main.async { completion(true) }
                        return
                    case NSMetadataUbiquitousItemDownloadingStatusNotDownloaded:
                        // 尚未下载，继续等待
                        continue
                    default:
                        break
                    }
                }
            }
        }
        
        query.start()
    }
    
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
    
    private func downloadInBackground(from remoteURL: URL, to localURL: URL, for songId: String) {
        let task = downloadSession.downloadTask(with: remoteURL) { tempURL, _, error in
            guard let tempURL = tempURL, error == nil else { return }
            try? FileManager.default.moveItem(at: tempURL, to: localURL)
            print("✅ 后台缓存完成: \(localURL.lastPathComponent)")
        }
        task.resume()
    }
    
    private func showDownloadErrorAlert() {
        // 通过某种方式展示 Alert，可以使用全局状态或 delegate
    }
    
    func pause() {
        wasPlayingBeforeInterruption = false
        core.pause()
    }
    
    
    
    func togglePlay() {
        isPlaying ? pause() : play()
    }
    
    
    /// 直接播放单首歌曲（会清空当前播放列表，只播放这一首）
    /// - Parameters:
    ///   - song: 要播放的歌曲
    ///   - uiMode: 播放后显示的 UI 模式，默认迷你
    ///   - skipStopUIReset: 若为 true，则跳过 stop() 中重置 UI 为 .hidden 的步骤（外部 Deep Link 使用）
    func play(song: Song, uiMode: PlayerUIMode = .mini, skipStopUIReset: Bool = false) {
        if skipStopUIReset {
            // 仅清理播放状态，不改变 UI 模式
            core.pause()
            core.stop()
            core.resetEngine()
            wasPlayingBeforeInterruption = false
            
            // 取消下载等清理，但保留 UI 状态
            audioDownloadTask?.cancel()
            audioDownloadTask = nil
            currentPlayTask?.cancel()
            currentPlayTask = nil
            coverDownloadTask?.cancel()
            coverDownloadTask = nil
            currentDownloadTask?.cancel()
            currentDownloadTask = nil
            currentLikeTask?.cancel()
            currentLikeTask = nil
            currentCommentTask?.cancel()
            currentCommentTask = nil
            
            // 清理临时文件
            if let tempURL = currentTempAudioURL {
                try? FileManager.default.removeItem(at: tempURL)
                currentTempAudioURL = nil
            }
            
            // 重置部分状态
            isLoadingSong = false
            isSwitchingSong = false
            isPerformingSkip = false
            isPublicPlaylistActive = false
            forceCompactOnNextOpen = false
            core.pause()
            isPlaying = false
        } else {
            stop()   // 原有行为：彻底停止并隐藏 UI
        }
        
        currentSong = nil
        self.songs = [song]
        self.currentIndex = 0
        
        playSong(at: currentIndex)
        
        // ✅ 关键修复1：当目标模式是 mini 时，强制允许迷你播放器显示
        if uiMode == .mini {
            self.allowMiniPlayerInCurrentPage = true
        }
        setPlayerUIMode(uiMode)   // 最终设置为目标 UI 模式
        
        // ✅ 关键：如果是迷你模式，延迟一帧后强制更新窗口位置并确保可见
        if uiMode == .mini {
            DispatchQueue.main.async {
                MiniPlayerWindow.shared.updateFrame()       // 重新计算适配当前屏幕的位置
                MiniPlayerWindow.shared.isHidden = false    // 确保显示
            }
        }
    }
    
    
    func seek(to time: TimeInterval) {
        core.seek(to: time)
    }
    
    private func canSwitchSong() -> Bool {
        let now = CACurrentMediaTime()
        if now - lastSwitchTime < minSwitchInterval {
            return false
        }
        lastSwitchTime = now
        return true
    }
    
    // 2. 修改 playNext/playPrevious
    func playNext() {
        guard !suppressAutoNext, !isPerformingSkip, !isPlayingNext else {
            print("⚠️ playNext 被抑制或已在执行")
            return
        }
        isPlayingNext = true
        defer { isPlayingNext = false }
        
        guard !suppressAutoNext else {
            print("⏸️ 自动切歌被抑制（语音输入期间）")
            return
        }
        guard !isPerformingSkip else {
            print("⚠️ playNext 防重入拦截")
            return
        }
        isPerformingSkip = true
        defer { isPerformingSkip = false }
        
        print("🎬 [playNext] 调用栈: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n"))")
        guard canSwitchSong() else { return }
        guard !songs.isEmpty, !isLoadingSong else { return }
        
        let nextIndex: Int
        switch playbackMode {
        case .sequential:
            nextIndex = (currentIndex + 1) % songs.count
        case .loopOne:
            nextIndex = currentIndex
        }
        
        if nextIndex == currentIndex && playbackMode == .sequential && songs.count == 1 {
            core.pause()
            isPlaying = false
            core.seek(to: 0)      // 进度归零
            currentTime = 0
            return
        }
        
        // ✅ 不更新 currentIndex，直接传递目标索引给 playSong
        playSong(at: nextIndex)
    }
    
    func playPrevious() {
        guard !suppressAutoNext else {
            print("⏸️ 自动切歌被抑制")
            return
        }
        guard !isPerformingSkip else {
            print("⚠️ playPrevious 防重入拦截")
            return
        }
        isPerformingSkip = true
        defer { isPerformingSkip = false }
        
        print("🎬 [playPrevious] 调用栈: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n"))")
        guard canSwitchSong() else { return }
        guard !songs.isEmpty, !isLoadingSong else { return }
        
        let prevIndex: Int
        switch playbackMode {
        case .sequential:
            prevIndex = (currentIndex - 1 + songs.count) % songs.count
        case .loopOne:
            prevIndex = currentIndex
        }
        
        if prevIndex == currentIndex && playbackMode == .sequential && songs.count == 1 {
            return
        }
        
        // ✅ 不更新 currentIndex，直接传递目标索引
        playSong(at: prevIndex)
    }
    
    func updatePlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
    }
    
    
    deinit {
        print("🟢 PlaybackService deinit")
        coverDownloadTask?.cancel()
        coverDownloadTask = nil
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
        currentLikeTask?.cancel()
        currentLikeTask = nil
        currentCommentTask?.cancel()
        currentCommentTask = nil
        currentPlayTask?.cancel()
        currentPlayTask = nil
        // 移除通知观察者
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        // 取消所有 Combine 订阅
        cancellables.removeAll()
    }
    
    private func absoluteURL(from string: String) -> URL? {
        // 如果已经是完整 URL，直接返回
        if let url = URL(string: string), url.scheme != nil {
            return url
        }
        // 否则，使用 baseURL 拼接
        let base = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        let path = string.hasPrefix("/") ? String(string.dropFirst()) : string
        return URL(string: base + path)
    }
    
}

// 定义通知
extension Notification.Name {
    static let switchToPlayerTab = Notification.Name("switchToPlayerTab")
    static let handleIncomingURL = Notification.Name("handleIncomingURL")
    static let requireLogin = Notification.Name("requireLogin")
    static let userDidLogin = Notification.Name("userDidLogin")
    static let userDidLogout = Notification.Name("userDidLogout")
    static let currentSongChanged = Notification.Name("currentSongChanged")
    // ✅ 新增歌词更新通知
    static let lyricsDidUpdate = Notification.Name("lyricsDidUpdate")
    // ✅ 新增：迷你播放器出现通知
    static let miniPlayerDidAppear = Notification.Name("miniPlayerDidAppear")
    static let miniPlayerDidDisappear = Notification.Name("miniPlayerDidDisappear")
    static let presentFullPlayer = Notification.Name("presentFullPlayer")
    static let presentFullPlayerFromDeepLink = Notification.Name("presentFullPlayerFromDeepLink")
}

extension PlaybackService {
    
    /// 等待 libraryService 可用，最长 10 秒，每 0.5 秒检查一次
    private func waitForLibraryService(timeout: TimeInterval = 60.0) async -> Bool {
        let start = CACurrentMediaTime()
        while libraryService == nil || libraryService!.songs.isEmpty {
            if CACurrentMediaTime() - start >= timeout { return false }
            // 如果库服务已注入但数据为空，主动触发加载（内部有防重入，不会重复请求）
            if let lib = libraryService, lib.songs.isEmpty {
                try? await lib.loadAISongsFromServer()
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒
        }
        return true
    }
    
    func handleUniversalLink(url: URL) {
        
        print("🔗 handleUniversalLink 收到 URL: \(url.absoluteString)")
        
        // QQ/微博回调先交给 ShareManager 处理，以触发分享结果回调
        if url.absoluteString.contains("response_from_qq") || url.absoluteString.contains("callback_name") {
            _ = ShareManager.shared.handleOpenURL(url)   // 让 ShareManager 回调分享成功/失败
            print("⏭️ 忽略 QQ/微博回调")
            return
        }
        
        var songIdentifier: String?
        
        // 解析自定义 scheme: strawberryplayer://song/xxx
        if url.scheme == "strawberryplayer" {
            if url.absoluteString.hasPrefix("strawberryplayer://song/") {
                songIdentifier = String(url.absoluteString.dropFirst("strawberryplayer://song/".count))
                if songIdentifier?.hasSuffix("/") == true { songIdentifier?.removeLast() }
                print("✅ 从自定义 scheme 解析到歌曲 ID: \(songIdentifier ?? "")")
            }
        }
        
        // 解析 HTTP 格式: https://caomei.pro/song/xxx 或 /play?song=xxx
        if songIdentifier == nil {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if components.host == "caomei.pro" {
                    if components.path == "/play",
                       let queryItems = components.queryItems,
                       let songId = queryItems.first(where: { $0.name == "song" })?.value {
                        songIdentifier = songId
                    } else if components.path.hasPrefix("/song/") {
                        songIdentifier = String(components.path.dropFirst("/song/".count))
                        if songIdentifier?.hasSuffix("/") == true { songIdentifier?.removeLast() }
                    }
                }
            }
        }
        
        guard let songId = songIdentifier, !songId.isEmpty else {
            print("❌ 无效的分享链接")
            return
        }
        
        print("🔍 解析到歌曲标识: \(songId)")
        
        // ✅ 防抖：同一首歌 5 秒内只处理一次
        let now = Date()
        if let lastId = lastHandledSongId,
           lastId == songId,
           now.timeIntervalSince(lastHandledTime) < 5.0 {
            print("⏳ 防抖忽略重复链接: \(songId)")
            return
        }
        lastHandledSongId = songId
        lastHandledTime = now
        
        
        // 防重复：如果当前已经是这首歌的全屏模式，就不再重复触发
        if let current = currentSong, current.stableId == songId, playerUIMode == .full {
            print("🎵 当前已在该歌曲的全屏播放中，忽略重复链接")
            return
        }
        
        
        func attemptToPlay(retryCount: Int = 0) {   // 参数保留可兼容已有调用
            Task {
                let ready = await waitForLibraryService()
                // 在库就绪或超时后再处理
                await MainActor.run {
                    if ready, let song = libraryService?.songs.first(where: { $0.stableId == songId }) {
                        print("🎵 曲库已准备好，找到歌曲: \(song.title)")
                        playThemePlaylist(for: song)
                    } else {
                        print("⚠️ 曲库未就绪或未找到歌曲，尝试网络查询")
                        fetchSongFromNetwork(stableId: songId)
                    }
                }
            }
        }
        
        attemptToPlay()
    }
    
    private func fetchSongFromNetwork(stableId: String) {
        Task {
            // 等待曲库就绪（最多 10 秒，内部会主动加载）
            let ready = await waitForLibraryService(timeout: 10)
            if ready, let song = libraryService?.songs.first(where: { $0.stableId == stableId }) {
                await MainActor.run { self.playThemePlaylist(for: song) }
            } else {
                // 兜底网络请求，但成功后仍然尝试主题播放
                let urlString = "\(baseURL)/api/songs/\(stableId)"
                guard let url = URL(string: urlString) else { return }
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let song = try decoder.decode(Song.self, from: data)
                    await MainActor.run {
                        // 网络成功后，如果此时曲库已就绪，则走主题；否则单曲
                        if let lib = self.libraryService, !lib.songs.isEmpty {
                            self.playThemePlaylist(for: song)
                        } else {
                            self.switchToPlaylist(songs: [song], startIndex: 0, openFullPlayer: true)
                        }
                    }
                } catch {
                    print("❌ fetchSongFromNetwork 失败: \(error)")
                }
            }
        }
    }
    
    
    // 位于 PlaybackService 类内部，建议放在 handleUniversalLink 下方
    private func playThemePlaylist(for song: Song) {
        // 曲库未准备好时，仅播放单曲（兜底）
        guard let library = libraryService, !library.songs.isEmpty else {
            switchToPlaylist(songs: [song], startIndex: 0, openFullPlayer: true)
            return
        }
        
        // 判定主题类型
        let isClassical = (song.style?.lowercased() == "古典" && song.virtualArtistId == nil)
        let isAI = (song.virtualArtistId != nil)
        
        var filtered: [Song]
        if isClassical {
            filtered = library.songs.filter { $0.style?.lowercased() == "古典" && $0.virtualArtistId == nil }
        } else if isAI {
            filtered = library.songs.filter { $0.virtualArtistId != nil }
        } else {
            // 无法归入任何主题，单曲播放
            switchToPlaylist(songs: [song], startIndex: 0, openFullPlayer: true)
            return
        }
        
        guard !filtered.isEmpty else {
            switchToPlaylist(songs: [song], startIndex: 0, openFullPlayer: true)
            return
        }
        
        // 确定在主题列表中的位置
        var startIndex: Int
        if let idx = filtered.firstIndex(where: { $0.stableId == song.stableId }) {
            startIndex = idx
        } else {
            filtered.insert(song, at: 0)
            startIndex = 0
        }
        
        switchToPlaylist(songs: filtered, startIndex: startIndex, openFullPlayer: true)
    }
    
    
    // MARK: - 评论相关方法（整改后）
    
    // 获取顶级评论
    func fetchComments(for song: Song, completion: @escaping (Result<[Comment], Error>) -> Void) {
        guard let token = userService?.accessToken else {
            completion(.failure(APIError.unauthorized))
            return
        }
        
        let encodedIdentifier = song.stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.stableId
        let urlString = baseURL + "/api/comments?identifier=" + encodedIdentifier
        guard let url = URL(string: urlString) else {
            completion(.failure(APIError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        dataSession.dataTask(with: request) { [weak self] data, response, error in
            
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 处理 401 未授权
                if httpResponse.statusCode == 401 {
                    Task {
                        do {
                            _ = try await self.userService?.refreshAccessToken(silent: true)
                        } catch { }
                    }
                    completion(.failure(APIError.unauthorized))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 调试日志
                if let jsonStr = String(data: data, encoding: .utf8) {
                    print("📥 fetchComments 响应: \(jsonStr)")
                }
                
                guard httpResponse.statusCode == 200 else {
                    let error = NSError(domain: "PlaybackService", code: httpResponse.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "服务器错误 \(httpResponse.statusCode)"])
                    completion(.failure(error))
                    return
                }
                
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let comments = try decoder.decode([Comment].self, from: data)
                    completion(.success(comments))
                } catch {
                    print("❌ 解析顶级评论失败: \(error)")
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // 获取回复列表
    func fetchReplies(for song: Song, parentId: String, completion: @escaping (Result<[Comment], Error>) -> Void) {
        guard let token = userService?.accessToken else {
            completion(.failure(APIError.unauthorized))
            return
        }
        
        let encodedIdentifier = song.stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.stableId
        let urlString = baseURL + "/api/comments?identifier=\(encodedIdentifier)&parentId=\(parentId)"
        guard let url = URL(string: urlString) else {
            completion(.failure(APIError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        dataSession.dataTask(with: request) { [weak self] data, response, error in
            
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 处理 401 未授权
                if httpResponse.statusCode == 401 {
                    Task {
                        do {
                            _ = try await self.userService?.refreshAccessToken(silent: true)
                        } catch { }
                    }
                    completion(.failure(APIError.unauthorized))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 调试日志
                if let jsonStr = String(data: data, encoding: .utf8) {
                    print("📥 fetchReplies 响应: \(jsonStr)")
                }
                
                guard httpResponse.statusCode == 200 else {
                    let error = NSError(domain: "PlaybackService", code: httpResponse.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "服务器错误 \(httpResponse.statusCode)"])
                    completion(.failure(error))
                    return
                }
                
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let replies = try decoder.decode([Comment].self, from: data)
                    completion(.success(replies))
                } catch {
                    print("❌ 解析回复失败: \(error)")
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // 发表评论（支持回复）
    func postComment(_ text: String, for song: Song, parentId: String? = nil, completion: @escaping (Result<Comment, Error>) -> Void) {
        guard let token = userService?.accessToken else {
            completion(.failure(APIError.unauthorized))
            return
        }
        
        let urlString = baseURL + "/api/comments"
        guard let url = URL(string: urlString) else {
            completion(.failure(APIError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        var body: [String: Any] = [
            "identifier": song.stableId,
            "content": text
        ]
        if let parentId = parentId {
            body["parentId"] = parentId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        dataSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 处理 401 未授权
                if httpResponse.statusCode == 401 {
                    Task {
                        do {
                            _ = try await self.userService?.refreshAccessToken(silent: true)
                        } catch { }
                    }
                    completion(.failure(APIError.unauthorized))
                    return
                }
                
                
                
                guard let data = data else {
                    completion(.failure(APIError.noData))
                    return
                }
                
                // 调试日志
                if let jsonStr = String(data: data, encoding: .utf8) {
                    print("📥 postComment 响应: \(jsonStr)")
                }
                
                guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                    let error = NSError(domain: "PlaybackService", code: httpResponse.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "服务器错误 \(httpResponse.statusCode)"])
                    completion(.failure(error))
                    return
                }
                
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let comment = try decoder.decode(Comment.self, from: data)
                    completion(.success(comment))
                } catch {
                    print("❌ 解析新评论失败: \(error)")
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // 点赞/取消点赞评论（返回新的点赞数）
    func likeComment(_ comment: Comment) async throws -> Int {
        guard let token = userService?.accessToken else {
            throw APIError.unauthorized
        }
        
        let urlString = baseURL + "/api/comments/\(comment.id)/like"
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await dataSession.data(for: request)
        
        // 检查 HTTP 状态码
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            // 静默刷新 token，不弹窗
            do {
                _ = try await userService?.refreshAccessToken(silent: true)
            } catch { }
            throw APIError.unauthorized
        }
        
        // 调试日志
        if let jsonStr = String(data: data, encoding: .utf8) {
            print("📥 likeComment 响应: \(jsonStr)")
        }
        
        do {
            let newLikes = try JSONDecoder().decode(Int.self, from: data)
            return newLikes
        } catch {
            print("❌ 解析点赞数失败: \(error)")
            throw error
        }
    }
    
    // 本地音频根目录
    static let localAudioDirectory: URL = {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let audioDir = paths[0].appendingPathComponent("DownloadedSongs")
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }()
}


extension PlaybackService {
    
    // 原方法仅返回固定的 .flac 路径，现改为可传入扩展名
    static func localAudioURL(for songId: String, extension ext: String? = nil) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioDir = docs.appendingPathComponent("DownloadedSongs")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let fileName = ext != nil ? "\(songId).\(ext!)" : songId
        return audioDir.appendingPathComponent(fileName)
    }
    
    // 可选：添加公开清理方法
    func clearAllAudioCache() {
        let audioDir = PlaybackService.localAudioDirectory
        try? FileManager.default.removeItem(at: audioDir)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        print("🧹 已清空所有音频缓存")
    }
    
    
    // 添加辅助方法（放在类内部任意位置）
    private func setLoading(_ loading: Bool) {
        DispatchQueue.main.async {
            self.isLoadingSong = loading
        }
    }
    
    private func setCurrentIndex(_ index: Int) {
        DispatchQueue.main.async {
            self.currentIndex = index
        }
    }
}
extension PlaybackService {
    func forceRecalibrateLyrics() {
        guard let song = currentSong,
              let audioURL = song.audioURL,          // ✅ 允许远程 URL
              let firstWord = song.cachedWordLyrics?.first?.first else { return }
        
        calibratedSongIds.remove(song.id)
        Task {
            await lyricsService.autoCalibrateOffset(
                for: song,
                audioURL: audioURL,
                firstWordStartTime: firstWord.startTime
            )
        }
    }
}

// MARK: - 统一认证请求（含自动静默刷新与重试）
extension PlaybackService {
    /// 执行需要认证的 HTTP 请求，自动处理 token 过期静默刷新与重试
    /// - Parameters:
    ///   - urlString: 请求 URL 字符串
    ///   - method: HTTP 方法，默认 GET
    ///   - body: 请求体（可选）
    ///   - token: Access Token（传入当前有效 token，如果为 nil 则直接抛出未授权）
    ///   - silentRefresh: 当 401 时是否尝试静默刷新（默认 true）
    ///   - retryOn401: 是否在刷新后重试一次（默认 true，调用方首次应设为 true）
    /// - Returns: 服务器响应的 Data
    /// - Throws: 网络错误、认证失败等
    private func performAuthenticatedRequest(
        urlString: String,
        method: String = "GET",
        body: Data? = nil,
        token: String?,
        silentRefresh: Bool = true,
        retryOn401: Bool = true
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        guard let token = token else { throw APIError.unauthorized }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        let (data, response) = try await dataSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown
        }
        
        // 如果是 401 并且允许静默刷新，则尝试刷新后重试一次
        if httpResponse.statusCode == 401, retryOn401, silentRefresh {
            print("🔄 [Auth] 收到 401，尝试静默刷新 token 后重试")
            do {
                let newToken = try await userService?.refreshAccessToken(silent: true)
                guard let newToken = newToken else { throw APIError.unauthorized }
                // 使用新 token 重试，并禁止再次刷新以避免无限循环
                return try await performAuthenticatedRequest(
                    urlString: urlString,
                    method: method,
                    body: body,
                    token: newToken,
                    silentRefresh: false,
                    retryOn401: false
                )
            } catch {
                print("❌ [Auth] 静默刷新失败: \(error.localizedDescription)")
                throw APIError.unauthorized
            }
        }
        
        // 检查最终状态码
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reason = errorJson["reason"] as? String {
                throw NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: reason])
            } else {
                throw NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败"])
            }
        }
        return data
    }
}
