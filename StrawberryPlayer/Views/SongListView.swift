
import SwiftUI

struct SongListView: View {
    @State private var library = LibraryService()
    @State private var songs: [Song] = []
    @State private var showPicker = false
    @State private var pickedURLs: [URL] = []
    @EnvironmentObject var playbackService: PlaybackService
    @Environment(\.dismiss) var dismiss  // 用于关闭模态
    
    var body: some View {
        NavigationView {
            List(songs) { song in
                HStack {
                    // 封面图 - 使用 coverURL 加载网络图片，如果没有则显示占位
                    if let coverURL = song.coverURL {
                        AsyncImage(url: coverURL) { phase in
                            if let image = phase.image {
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50)
                                    .cornerRadius(4)
                            } else {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 50, height: 50)
                                    .overlay(Image(systemName: "music.note").foregroundColor(.gray))
                            }
                        }
                        .id(song.stableId)  // ✅ 添加这一行
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 50, height: 50)
                            .overlay(Image(systemName: "music.note").foregroundColor(.gray))
                    }
                    
                    VStack(alignment: .leading) {
                        Text(song.title)
                            .font(.headline)
                            .foregroundColor(isCurrentSong(song) ? .blue : .primary)
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if isCurrentSong(song) {
                        Image(systemName: playbackService.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .foregroundColor(.blue)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 16)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isCurrentSong(song) {
                        playbackService.isPlaying ? playbackService.pause() : playbackService.play()
                    } else {
                        if let index = songs.firstIndex(where: { $0.id == song.id }) {
                            playbackService.setPlaylist(songs: songs, startIndex: index)
                            playbackService.play()
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle("网盘音乐")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker(onPick: { url in
                    library.importFile(from: url)
                })
            }
            .onAppear {
                refreshSongs()
            }
        }
    }
    
    private func refreshSongs() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let allSongs = library.scanSongs(in: documents)
        var seen = Set<String>()  // 使用 id 去重
        songs = allSongs.filter { seen.insert($0.id).inserted }
        
        // 预加载所有歌曲的主色（在后台异步进行，不影响 UI）
        for song in songs {
            preloadDominantColor(for: song)
        }
    }
    
    private func isCurrentSong(_ song: Song) -> Bool {
        return playbackService.currentSong?.id == song.id
    }
}
