import SwiftUI

struct ArtistProfileView: View {
    let artist: VirtualArtist
    @EnvironmentObject var virtualArtistService: VirtualArtistService
    @EnvironmentObject var userService: UserService
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @EnvironmentObject var tabSelection: TabSelection
    @EnvironmentObject var libraryService: LibraryService
    
    @State private var isFollowed = false
    @State private var followerCount: Int
    @State private var refreshFlag = 0          // ✅ 强制刷新标志

    @State private var showDeleteErrorAlert = false
    @State private var deleteErrorMessage = ""
    @State private var showDeleteSongConfirmation = false
    @State private var songToDelete: Song?
    @State private var showAIGenerate = false
        
    // ✅ 优化：直接使用字符串比较，避免 UUID 转换失败导致歌曲不显示
    private var songs: [Song] {
        libraryService.songs.filter { song in
            guard let vid = song.virtualArtistId else { return false }
            // 将艺人的 UUID 字符串与歌曲的 virtualArtistId 字符串直接比较
            return vid.uuidString == artist.id
        }
    }
    
    init(artist: VirtualArtist) {
        self.artist = artist
        _followerCount = State(initialValue: artist.followerCount)
    }
    
    var body: some View {
        List {
            // 头部信息
            Section {
                HStack(spacing: 16) {
                    AsyncImage(url: artist.fullAvatarURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Circle().fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .id(artist.fullAvatarURL)
                    
                    VStack(alignment: .leading) {
                        Text(artist.name)
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(artist.genre)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: toggleFollow) {
                        Text(isFollowed ? "已关注" : "+ 关注")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(isFollowed ? Color.gray.opacity(0.2) : Color.blue)
                            .foregroundColor(isFollowed ? .primary : .white)
                            .cornerRadius(16)
                    }
                }
                .padding(.horizontal)
                
                if let bio = artist.bio, !bio.isEmpty {
                    Text(bio)
                        .padding(.horizontal)
                }
                
                HStack(spacing: 40) {
                    VStack {
                        Text("\(songs.count)")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("作品")
                    }
                    VStack {
                        Text("\(followerCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("粉丝")
                    }
                }
                .padding(.horizontal)
                
                Divider()
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            
            // 作品列表
            Section(header: Text("作品").font(.title3).fontWeight(.bold).padding(.horizontal)) {
                ForEach(songs) { song in
                    SongRowWithMetrics(song: song, playbackService: playbackService, lyricsService: lyricsService) {
                        playSong(song)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteSong(song)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .id(refreshFlag)   // ✅ 当 refreshFlag 变化时，强制重建整个 List
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        showAIGenerate = true
                    } label: {
                        Label("AI生成歌曲", systemImage: "waveform")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fullScreenCover(isPresented: $showAIGenerate) {
            AIGenerateSongView(artist: artist)
                .environmentObject(virtualArtistService)
                .environmentObject(userService)
                .environmentObject(libraryService)
                .environmentObject(playbackService)
        }
        .onAppear {
            print("🎤 当前艺人 ID: \(artist.id)")
            playbackService.setAllowMiniPlayer(true)
            loadArtistDetails()
        }
        .onDisappear {
            playbackService.setAllowMiniPlayer(false)
        }
        // ✅ 监听歌曲库变化，重新加载艺人信息（songs 作为计算属性会自动刷新）
        .onReceive(NotificationCenter.default.publisher(for: .songsDidChange)) { _ in
            loadArtistDetails()      // 刷新粉丝数等艺人信息
            refreshFlag += 1         // ✅ 触发视图强制刷新，立即显示新歌曲
        }
        .alert("删除失败", isPresented: $showDeleteErrorAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(deleteErrorMessage)
        }
        .alert("删除歌曲", isPresented: $showDeleteSongConfirmation, presenting: songToDelete) { song in
            Button("取消", role: .cancel) {
                songToDelete = nil
            }
            Button("删除", role: .destructive) {
                performDeleteSong(song)
            }
        } message: { song in
            Text("确定要删除歌曲“\(song.title)”吗？此操作不可恢复。")
        }
    }
    
    // MARK: - Helpers
    private func deleteSong(_ song: Song) {
        songToDelete = song
        showDeleteSongConfirmation = true
    }
    
    private func performDeleteSong(_ song: Song) {
        guard let token = userService.currentToken else { return }
        libraryService.deleteSong(songId: song.id, token: token) { result in
            switch result {
            case .success:
                // 从全局数据源移除
                if let index = libraryService.songs.firstIndex(where: { $0.id == song.id }) {
                    libraryService.songs.remove(at: index)
                }
                // 同步播放列表
                if let playbackIndex = playbackService.songs.firstIndex(where: { $0.id == song.id }) {
                    playbackService.songs.remove(at: playbackIndex)
                    if playbackService.currentSong?.id == song.id {
                        if playbackService.songs.isEmpty {
                            playbackService.currentSong = nil
                            playbackService.stop()
                        } else {
                            playbackService.playNext()
                        }
                    }
                }
                NotificationCenter.default.post(name: .songsDidChange, object: nil)
            case .failure(let error):
                deleteErrorMessage = error.localizedDescription
                showDeleteErrorAlert = true
            }
            songToDelete = nil
        }
    }
    
    private func loadArtistDetails() {
        virtualArtistService.fetchArtist(id: artist.id) { result in
            if case .success(let updatedArtist) = result {
                followerCount = updatedArtist.followerCount
            }
        }
        // 关注状态可根据需要从服务获取，此处略
    }
    
    private func toggleFollow() {
        guard let token = userService.currentToken else { return }
        if isFollowed {
            virtualArtistService.unfollowArtist(artistId: artist.id, token: token) { result in
                if case .success = result {
                    isFollowed = false
                    followerCount -= 1
                }
            }
        } else {
            virtualArtistService.followArtist(artistId: artist.id, token: token) { result in
                if case .success = result {
                    isFollowed = true
                    followerCount += 1
                }
            }
        }
    }
    
    private func playSong(_ song: Song) {
        debugLog("🎵 ArtistProfileView 播放歌曲: \(song.title)")
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else {
            fallbackPlaySingle(song)
            return
        }
        lyricsService.fetchLyrics(for: song)
        playbackService.forceCompactOnNextOpen = true
        playbackService.switchToPlaylist(songs: songs, startIndex: index, openFullPlayer: true)
    }
    
    private func fallbackPlaySingle(_ song: Song) {
        lyricsService.fetchLyrics(for: song)
        playbackService.forceCompactOnNextOpen = true
        playbackService.switchToPlaylist(songs: [song], startIndex: 0, openFullPlayer: true)
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%02d:%02d", min, sec)
    }
}

// SongRowWithMetrics 保持不变（无需修改）
struct SongRowWithMetrics: View {
    let song: Song
    let playbackService: PlaybackService
    let lyricsService: LyricsService
    let action: () -> Void
    
    @State private var likeCount: Int = 0
    
    var body: some View {
        HStack {
            Text(song.title)
                .foregroundColor(.primary)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "heart")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(likeCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(formatDuration(song.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onTapGesture(perform: action)
        .onAppear {
            if let metrics = SongMetricsCache.shared.get(songId: song.stableId) {
                likeCount = metrics.likes
            } else {
                playbackService.fetchLikeCount(for: song) { count in
                    likeCount = count
                }
            }
        }
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        return String(format: "%02d:%02d", min, sec)
    }
}
