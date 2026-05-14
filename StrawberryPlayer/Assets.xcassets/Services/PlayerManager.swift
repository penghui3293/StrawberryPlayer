//
//  PlayerManager.swift
//  Player
//  播放器核心控制（单例）
//  Created by penghui zhang on 2026/2/14.
//

import AVFoundation
import MediaPlayer
import Combine

class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    private var player: AVPlayer?
    private var playerItems: [AVPlayerItem] = []
    private var songs: [Song] = []
    private var currentIndex: Int = 0

    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackMode: PlaybackMode = .loopAll
    
    @Published var lyrics: [LyricLine] = []      // 当前歌词
    @Published var currentLyricIndex: Int = 0   // 当前高亮行

    enum PlaybackMode {
        case loopAll, loopOne, shuffle
    }

    private var timeObserver: Any?

    override private init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
        setupNowPlaying()
        observePlayerItemEnd()
    }

    // MARK: - 播放控制

    
    func setPlaylist(songs: [Song], startIndex: Int = 0) {
        self.songs = songs
        self.playerItems = songs.map { AVPlayerItem(url: $0.url) }
        self.currentIndex = startIndex

        player = AVPlayer(playerItem: playerItems[startIndex])
        // 删除下面这行
        // player?.actionAtItemEnd = .advance

        setupNowPlaying()
        addPeriodicTimeObserver()
        currentSong = songs[startIndex]
        duration = songs[startIndex].duration
        
        // 加载歌词
        loadLyrics(for: currentSong)
    }
    
    // 加载歌词
        private func loadLyrics(for song: Song?) {
            guard let song = song, let lyricsURL = song.lyricsURL else {
                lyrics = []
                currentLyricIndex = 0
                print("📄 无歌词文件")
                return
            }
            lyrics = LyricsParser.parse(url: lyricsURL) ?? []
            print("📄 解析到 \(lyrics.count) 行歌词")
        }
    
    // 在 periodic time observer 中更新索引
        private func addPeriodicTimeObserver() {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600) // 更精细的更新
            timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.currentTime = time.seconds
                self?.updateNowPlayingPlaybackTime()
                self?.updateCurrentLyricIndex()
            }
        }
    
    // 更新当前歌词索引
        private func updateCurrentLyricIndex() {
            guard !lyrics.isEmpty else {
                currentLyricIndex = 0
                return
            }
            // 找到最后一个时间小于等于 currentTime 的索引
            var index = lyrics.lastIndex(where: { $0.time <= currentTime }) ?? 0
            // 防止越界
            if index >= lyrics.count { index = lyrics.count - 1 }
            if currentLyricIndex != index {
                currentLyricIndex = index
            }
        }

    func play() {
        player?.play()
        isPlaying = true
        updateNowPlaying(isPlaying: true)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying(isPlaying: false)
    }

    func playNext() {
        switch playbackMode {
        case .loopOne:
            // 单曲循环：重新播放当前歌曲
            player?.seek(to: .zero)
            play()
        case .shuffle:
            // 随机播放：随机选择一首（排除当前）
            let remaining = songs.indices.filter { $0 != currentIndex }
            if let randomIndex = remaining.randomElement() {
                currentIndex = randomIndex
                player?.replaceCurrentItem(with: playerItems[currentIndex])
                currentSong = songs[currentIndex]
                duration = songs[currentIndex].duration
                play()
            }
        case .loopAll:
            // 列表循环：顺序下一首，若到最后则回到开头
            let nextIndex = currentIndex + 1
            if nextIndex < songs.count {
                currentIndex = nextIndex
            } else {
                currentIndex = 0
            }
            player?.replaceCurrentItem(with: playerItems[currentIndex])
            currentSong = songs[currentIndex]
            duration = songs[currentIndex].duration
            play()
        }
    }

    func playPrevious() {
        // 上一首逻辑（类似 playNext，可自行补充）
        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            currentIndex = prevIndex
        } else {
            currentIndex = songs.count - 1
        }
        player?.replaceCurrentItem(with: playerItems[currentIndex])
        currentSong = songs[currentIndex]
        duration = songs[currentIndex].duration
        play()
    }

    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    // MARK: - 播放模式切换
    func updatePlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
    }

    // MARK: - 私有辅助方法

//    private func addPeriodicTimeObserver() {
//        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
//        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
//            self?.currentTime = time.seconds
//            self?.updateNowPlayingPlaybackTime()
//        }
//    }

    private func observePlayerItemEnd() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(playerItemDidEnd),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: nil)
    }

    @objc private func playerItemDidEnd(notification: Notification) {
        // 播放结束时自动下一首
        playNext()
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - 后台播放与控制中心
extension PlayerManager {
    fileprivate func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session: \(error)")
        }
    }

    fileprivate func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    fileprivate func setupNowPlaying() {
        guard let song = currentSong else { return }
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = song.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let data = song.artworkData, let image = UIImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    fileprivate func updateNowPlaying(isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }

    fileprivate func updateNowPlayingPlaybackTime() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }
}
