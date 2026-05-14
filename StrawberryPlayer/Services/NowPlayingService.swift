//
//  NowPlayingService.swift
//  StrawberryPlayer
//  这些方案完全对标汽水音乐的控制中心实现：全量信息定时注入 + 完备 Artwork + 零延迟的 LRC 构建。
//

import MediaPlayer
import Combine
import UIKit

@MainActor
class NowPlayingService: NSObject {
    private var cancellables = Set<AnyCancellable>()
    private let commandCenter = MPRemoteCommandCenter.shared()
    
    private var currentCoverData: Data?
    private var currentCoverThumbData: Data?
    private var currentSongId: String?
    
    private weak var playbackService: PlaybackService?
    private weak var lyricsService: LyricsService?
    
    // 缓存的完整 LRC（用于原生歌词行）
    private var cachedFullLRC: String = ""
    private var lastSetCurrentLyric: String = ""
    private var lastLyricUpdateTime: TimeInterval = 0
    private let minLyricUpdateInterval: TimeInterval = 0.5
    private var hasSetLyrics: Bool = false
    
    // 封面绘制频率控制
    private var lastArtworkDrawTime: TimeInterval = 0
    private let minArtworkDrawInterval: TimeInterval = 2.0
    
    
    private var keepAliveTimer: Timer?
    
    func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateNowPlayingWithLyrics()
        }
    }
    
    func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
    
    func startObserving(playbackService: PlaybackService, lyricsService: LyricsService) {
        self.playbackService = playbackService
        self.lyricsService = lyricsService
        
        // 注册远程命令（必需）
        setupRemoteCommands(playbackService: playbackService)
        
        playbackService.$currentSong
            .sink { [weak self] song in self?.handleSongChange(song) }
            .store(in: &cancellables)
        
        playbackService.$isPlaying
            .sink { [weak self] isPlaying in
                self?.updatePlaybackState(isPlaying)
                if isPlaying {
                    self?.startKeepAlive()
                } else {
                    self?.stopKeepAlive()
                }
            }
            .store(in: &cancellables)
        
        playbackService.$currentTime
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] time in self?.updatePlaybackTime(time) }
            .store(in: &cancellables)
        
        // 歌词索引 → 更新原生动态歌词 + 封面
        lyricsService.$currentLyricIndex
            .combineLatest(lyricsService.$lyrics)
            .sink { [weak self] index, lyrics in
                guard let self, index >= 0, index < lyrics.count else { return }
                self.updateCurrentLyric(lyrics[index].text)
            }
            .store(in: &cancellables)
        
        // 歌词加载完成通知
        NotificationCenter.default.publisher(for: .lyricsDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] noti in
                guard let self,
                      let songId = noti.object as? String,
                      let currentSong = self.playbackService?.currentSong,
                      currentSong.id == songId else { return }
                self.rebuildFullLRCAndSet(for: currentSong)
                // ✅ 如果此时 duration 仍为0，延迟再次尝试
                if (self.playbackService?.duration ?? 0) <= 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.rebuildFullLRCAndSet(for: currentSong)
                    }
                }
            }
            .store(in: &cancellables)
        
        // 监听时长变化，确保 whenPlayingInfo 拥有正确的时长（控制中心歌词显示必需）
        playbackService.$duration
            .removeDuplicates()
            .filter { $0 > 0 }          // 仅在有效时长出现时处理
            .sink { [weak self] duration in
                guard let self = self else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                let oldDuration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval
                let updateNeeded = oldDuration == nil || oldDuration != duration
                
                if updateNeeded {
                    // ✅ 关键修复：不再只修补个别字段，而是完全重建 nowPlaying 信息
                    // 此时歌词（cachedFullLRC）和封面应该已经就绪
                    if !self.cachedFullLRC.isEmpty {
                        self.updateNowPlayingWithLyrics()
                    } else {
                        // 歌词尚未就绪时，仅更新时长，等其他机制后续填补
                        info[MPMediaItemPropertyPlaybackDuration] = duration
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // 远程命令（异步，避免超时）
    private func setupRemoteCommands(playbackService: PlaybackService) {
        commandCenter.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.playbackService?.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.playbackService?.pause() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.playbackService?.playNext() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.playbackService?.playPrevious() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  let self = self else { return .commandFailed }
            DispatchQueue.main.async { self.playbackService?.seek(to: event.positionTime) }
            return .success
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }
    
    // MARK: - 歌曲切换
    private func handleSongChange(_ song: Song?) {
        guard let song = song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            currentCoverData = nil; currentCoverThumbData = nil; currentSongId = nil
            
            lastSetCurrentLyric = ""  // 清空遗留歌词
            return
        }
        
        // 如果与上一首不同，重置
        if currentSongId != song.id {
            lastSetCurrentLyric = ""
        }
        
        // 确保歌词加载
        if let ls = lyricsService, ls.lyrics.isEmpty && ls.wordLyrics.isEmpty {
            ls.fetchLyrics(for: song)
        }
        // 设置基本信息
        setBasicInfo(song)
        // 下载封面
        if currentSongId != song.id {
            currentSongId = song.id
            currentCoverData = nil; currentCoverThumbData = nil
            if let coverURL = song.coverURL {
                URLSession.shared.dataTask(with: coverURL) { [weak self] data, _, _ in
                    guard let self, let data = data, let img = UIImage(data: data) else { return }
                    self.currentCoverData = data
                    self.currentCoverThumbData = img.resized(maxSide: 200)?.jpegData(compressionQuality: 0.8)
                    // 封面下载完成，尝试更新原生+封面
                    self.updateNowPlayingWithLyrics()
                }.resume()
            }
        }
        // 如果歌词已存在，直接更新
        if let ls = lyricsService, !ls.lyrics.isEmpty || !ls.wordLyrics.isEmpty {
            updateNowPlayingWithLyrics()
        }
    }
    
    // 设置基本信息（不含歌词和封面）
    private func setBasicInfo(_ song: Song) {
        let artistAlbum = "\(song.artist) - \(song.title)"   // 拼接
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: artistAlbum,            // 完整信息
            MPMediaItemPropertyAlbumTitle: song.title,         // 歌名放在底部
            MPMediaItemPropertyPlaybackDuration: song.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    
    // 构建LRC并同时设置原生歌词 + 封面
    private func rebuildFullLRCAndSet(for song: Song) {
        let lrc = buildCompleteLRC(for: song)
        guard !lrc.isEmpty else { return }
        
        // 补充歌词行数组
        if let ls = lyricsService, ls.lyrics.isEmpty, let words = song.cachedWordLyrics, !words.isEmpty {
            let lyricsLines = words.enumerated().map { index, lineWords -> LyricLine in
                let text = lineWords.map { $0.word }.joined()
                let startTime = lineWords.first?.startTime ?? 0
                let endTime = lineWords.last?.endTime ?? (index + 1 < words.count ? words[index+1].first?.startTime : nil)
                return LyricLine(startTime: startTime, endTime: endTime, text: text, words: lineWords)
            }
            ls.lyrics = lyricsLines
        }
        
        cachedFullLRC = lrc
        // 尝试设置（内部会检查时长是否有效）
        updateNowPlayingWithLyrics()
        
        // 强制设置当前歌词，确保一开始就有歌词显示
        if let currentLyric = getCurrentLyricForTime(playbackService?.currentTime ?? 0), !currentLyric.isEmpty {
            updateCurrentLyric(currentLyric)
        }
        // 移除旧的异步刷新（由 duration 监听保证后续更新）
    }
    
    // 核心：更新nowPlaying，包含封面和原生歌词
    private func updateNowPlayingWithLyrics() {
        guard let song = playbackService?.currentSong else { return }
        let fullLRC = cachedFullLRC.isEmpty ? buildCompleteLRC(for: song) : cachedFullLRC
        guard !fullLRC.isEmpty else { return }
        cachedFullLRC = fullLRC
        
        let currentTime = playbackService?.currentTime ?? 0
        let currentLyric = getCurrentLyricForTime(currentTime)
        
        let realDuration = playbackService?.duration ?? 0
        let effectiveDuration = realDuration > 0 ? realDuration : song.duration
        
        guard effectiveDuration > 0 else {
            // 时长未知时，显示歌名
            var baseInfo: [String: Any] = [
                MPMediaItemPropertyTitle: song.title,
                MPMediaItemPropertyArtist: "\(song.artist) - \(song.title)",
                MPMediaItemPropertyAlbumTitle: song.title,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                MPNowPlayingInfoPropertyPlaybackRate: 0.0
            ]
            setNormalArtwork(&baseInfo)
//            print("⏸️ [updateNowPlayingWithLyrics] effectiveDuration=0 info: \(baseInfo)")
            MPNowPlayingInfoCenter.default().nowPlayingInfo = baseInfo
            return
        }
        
        // ✅ 核心：决定 Title 内容
        let displayTitle: String
        if let currentLyric = currentLyric, !currentLyric.isEmpty {
            // 当前有歌词 → 更新遗留歌词并显示
            lastSetCurrentLyric = currentLyric
            displayTitle = currentLyric
        } else if !lastSetCurrentLyric.isEmpty {
            // 无当前歌词但之前出现过歌词 → 保留最后一句
            displayTitle = lastSetCurrentLyric
        } else {
            // 从未出现过歌词 → 显示歌名
            displayTitle = song.title
        }
        
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: displayTitle,
            MPMediaItemPropertyArtist: "\(song.artist) - \(song.title)",
            MPMediaItemPropertyAlbumTitle: song.title,             // 歌名放第二行
            MPMediaItemPropertyPlaybackDuration: effectiveDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: (playbackService?.isPlaying ?? false) ? 1.0 : 0.0,
            "MPNowPlayingInfoPropertyLyrics": fullLRC
        ]
        
        if let lyricText = currentLyric, !lyricText.isEmpty {
            info["MPNowPlayingInfoPropertyCurrentLyrics"] = lyricText
            lastSetCurrentLyric = lyricText
        } else if !lastSetCurrentLyric.isEmpty {
            info["MPNowPlayingInfoPropertyCurrentLyrics"] = lastSetCurrentLyric
        }
        
        setNormalArtwork(&info)
//        print("🎤 [updateNowPlayingWithLyrics] final info: \(info)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        hasSetLyrics = true
    }
    
    
    // 更新播放状态
    private func updatePlaybackState(_ isPlaying: Bool) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        if let song = playbackService?.currentSong {
            info[MPMediaItemPropertyArtist] = "\(song.artist) - \(song.title)"
            info[MPMediaItemPropertyAlbumTitle] = song.title
        }
        
        // ✅ 只有在已存在有效时长（>0）时，才允许注入歌词，防止 duration=0 导致系统禁用歌词
        if isPlaying,
           !cachedFullLRC.isEmpty,
           !lastSetCurrentLyric.isEmpty,
           (info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0) > 0 {
            info["MPNowPlayingInfoPropertyLyrics"] = cachedFullLRC
            info["MPNowPlayingInfoPropertyCurrentLyrics"] = lastSetCurrentLyric
            setNormalArtwork(&info)
        }
        
//        print("⏯️ [updatePlaybackState] final info: \(info)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // 更新动态歌词（原生）
    private func updateCurrentLyric(_ text: String) {
        guard !text.isEmpty, !cachedFullLRC.isEmpty else { return }
        
        let currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let currentDuration = currentInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
        guard currentDuration > 0 else { return }
        
        let now = CACurrentMediaTime()
        guard now - lastLyricUpdateTime >= minLyricUpdateInterval else { return }
        lastLyricUpdateTime = now
        lastSetCurrentLyric = text   // 更新遗留
        
        var info = currentInfo
        info[MPMediaItemPropertyTitle] = text
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackService?.currentTime ?? 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info["MPNowPlayingInfoPropertyLyrics"] = cachedFullLRC
        info["MPNowPlayingInfoPropertyCurrentLyrics"] = text
        
        setNormalArtwork(&info)
//        print("🎵 [updateCurrentLyric] final info: \(info)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    private func setNormalArtwork(_ info: inout [String: Any]) {
        if let thumbData = currentCoverThumbData, let img = UIImage(data: thumbData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        } else if let coverData = currentCoverData, let img = UIImage(data: coverData) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        } else {
            // 占位封面，避免无封面导致歌词不显示
            let placeholderSize = CGSize(width: 200, height: 200)
            let placeholderImage = UIGraphicsImageRenderer(size: placeholderSize).image { ctx in
                UIColor.darkGray.setFill()
                ctx.fill(CGRect(origin: .zero, size: placeholderSize))
            }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: placeholderSize) { _ in placeholderImage }
        }
    }
    
    
    private func updatePlaybackTime(_ time: TimeInterval) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
//        print("⏱️ [updatePlaybackTime] final info: \(info)")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // LRC 构建
    private func buildCompleteLRC(for song: Song) -> String {
        var lyricLines: [(TimeInterval, String)] = []
        if let ls = lyricsService, !ls.lyrics.isEmpty {
            for line in ls.lyrics {
                lyricLines.append((line.startTime ?? 0, line.text))
            }
        } else if let ls = lyricsService, !ls.wordLyrics.isEmpty {
            // ✅ 直接从 wordLyrics 构建，无需依赖 song.cachedWordLyrics
            for (_, lineWords) in ls.wordLyrics.enumerated() {
                if let first = lineWords.first {
                    lyricLines.append((first.startTime, lineWords.map { $0.word }.joined()))
                }
            }
        }
        guard !lyricLines.isEmpty else { return "" }
        return lyricLines.map { "[\(formatLRC($0.0))]\($0.1)" }.joined(separator: "\n")
    }
    
    
    private func formatLRC(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 100)
        return String(format: "%02d:%02d.%02d", m, s, ms)
    }
    
    private func getFirstLyricLine() -> String? {
        if let ls = lyricsService, !ls.lyrics.isEmpty, !ls.lyrics[0].text.isEmpty { return ls.lyrics[0].text }
        if let ls = lyricsService, !ls.wordLyrics.isEmpty { return ls.wordLyrics[0].map(\.word).joined() }
        return nil
    }
    
    
    private func coverImageForDrawing() -> UIImage {
        let targetSide: CGFloat = 200
        if let thumbData = currentCoverThumbData, let img = UIImage(data: thumbData) {
            return img.resized(maxSide: targetSide) ?? img
        }
        if let coverData = currentCoverData, let img = UIImage(data: coverData) {
            return img.resized(maxSide: targetSide) ?? img
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetSide, height: targetSide))
        return renderer.image { ctx in
            UIColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: targetSide, height: targetSide)))
        }
    }
    
    
    private func getCurrentLyricForTime(_ time: TimeInterval) -> String? {
        guard let ls = lyricsService, !ls.lyrics.isEmpty else { return nil }
        var currentText: String? = nil
        for line in ls.lyrics {
            guard let startTime = line.startTime else { continue }
            if startTime <= time {
                currentText = line.text
            } else {
                break
            }
        }
        return currentText   // 可能为 nil，表示前奏
    }
    
    
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage? {
        let size = self.size
        let scale = min(maxSide / size.width, maxSide / size.height, 1.0)
        if scale >= 1.0 { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

