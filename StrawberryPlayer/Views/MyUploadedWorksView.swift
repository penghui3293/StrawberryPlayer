
import SwiftUI

struct MyUploadedWorksView: View {
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var userService: UserService
    @EnvironmentObject var virtualArtistService: VirtualArtistService
    @EnvironmentObject var tabSelection: TabSelection
    @EnvironmentObject var lyricsService: LyricsService
    
    @State private var showingUploadSheet = false
    @State private var showDeleteErrorAlert = false
    @State private var deleteErrorMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var songToDelete: Song?
    
    private var uploadedWorks: [Song] {
        libraryService.songs.filter { $0.virtualArtistId == nil }
    }
    
    var body: some View {
        List {
            if uploadedWorks.isEmpty {
                Text("暂无上传作品")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(uploadedWorks) { song in
                    SongRow(song: song) {
                        lyricsService.fetchLyrics(for: song)
                        playbackService.setPlaylist(songs: uploadedWorks, startIndex: uploadedWorks.firstIndex(of: song) ?? 0)
                        playbackService.play()
                        playbackService.setPlayerUIMode(.full)   // ✅ 使用统一方法打开全屏
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            songToDelete = song
                            showingDeleteConfirmation = true
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("公共版权作品")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    NavigationLink(destination: UploadPublicMusicView()) {
                        Label("上传公共版权音乐", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("删除失败", isPresented: $showDeleteErrorAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(deleteErrorMessage)
        }
        .alert("删除作品", isPresented: $showingDeleteConfirmation, presenting: songToDelete) { song in
            Button("取消", role: .cancel) {
                songToDelete = nil
            }
            Button("删除", role: .destructive) {
                performDelete(song)
            }
        } message: { song in
            Text("确定要删除歌曲“\(song.title)”吗？此操作不可恢复。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .songsDidChange)) { _ in
            // 计算属性会自动刷新，无需额外操作
        }
        .onAppear {
            playbackService.setAllowMiniPlayer(true)
        }
        .onDisappear {
            playbackService.setAllowMiniPlayer(false)

        }
    }
    
    private func performDelete(_ song: Song) {
        guard let token = userService.currentToken else { return }
        libraryService.deleteSong(songId: song.id, token: token) { result in
            switch result {
            case .success:
                if let index = libraryService.songs.firstIndex(where: { $0.id == song.id }) {
                    libraryService.songs.remove(at: index)
                }
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
                songToDelete = nil
                showingDeleteConfirmation = false
            case .failure(let error):
                deleteErrorMessage = error.localizedDescription
                showDeleteErrorAlert = true
            }
        }
    }
}

struct SongRow: View {
    let song: Song
    let action: () -> Void
    @EnvironmentObject var playbackService: PlaybackService
    @State private var likeCount: Int = 0
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var body: some View {
        Button(action: action) {
            HStack {
                // 封面图保持原样
                if let coverURL = song.coverURL {
                    AsyncImage(url: coverURL) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.3))
                        }
                    }
                    .frame(width: 50, height: 50)
                    .cornerRadius(4)
                    .id(coverURL)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "music.note").foregroundColor(.gray))
                }
                
                VStack(alignment: .leading) {
                    Text(song.title)
                        .font(.headline)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "heart")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(likeCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatTime(song.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
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
}

//struct SongRow: View {
//    let song: Song
//    let action: () -> Void
//    
//    private func formatTime(_ time: TimeInterval) -> String {
//        let minutes = Int(time) / 60
//        let seconds = Int(time) % 60
//        return String(format: "%02d:%02d", minutes, seconds)
//    }
//    
//    var body: some View {
//        Button(action: action) {
//            HStack {
//                if let coverURL = song.coverURL {
//                    AsyncImage(url: coverURL) { phase in
//                        if let image = phase.image {
//                            image.resizable().aspectRatio(contentMode: .fill)
//                        } else {
//                            Rectangle().fill(Color.gray.opacity(0.3))
//                        }
//                    }
//                    .frame(width: 50, height: 50)
//                    .cornerRadius(4)
//                    .id(coverURL)
//                } else {
//                    Rectangle()
//                        .fill(Color.gray.opacity(0.3))
//                        .frame(width: 50, height: 50)
//                        .overlay(Image(systemName: "music.note").foregroundColor(.gray))
//                }
//                
//                VStack(alignment: .leading) {
//                    Text(song.title)
//                        .font(.headline)
//                    Text(song.artist)
//                        .font(.caption)
//                        .foregroundColor(.secondary)
//                }
//                Spacer()
//                Text(formatTime(song.duration))
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//                    .monospacedDigit()
//            }
//        }
//        .buttonStyle(PlainButtonStyle())
//    }
//}
