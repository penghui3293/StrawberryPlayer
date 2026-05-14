import SwiftUI

    struct MyArtistsView: View {
    @EnvironmentObject var virtualArtistService: VirtualArtistService
    @EnvironmentObject var userService: UserService
    
    @State private var myArtists: [VirtualArtist] = []
    @State private var songCounts: [String: Int] = [:] // 艺人ID -> 歌曲数
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isDeleting = false
    
    @State private var showDeleteConfirmation = false
    @State private var artistToDelete: VirtualArtist?
    
    var body: some View {
        List {
            if isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else if let errorMessage = errorMessage {
                VStack {
                    Text("加载失败")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        loadArtists()
                    }
                    .padding(.top)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
            } else if myArtists.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 50))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("暂无虚拟艺人")
                        .font(.headline)
                    Text("点击右上角 + 创建你的第一个艺人")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
            } else {
                ForEach(myArtists) { artist in
                    NavigationLink(destination: ArtistProfileView(artist: artist)) {
                        HStack {
                            AsyncImage(url: artist.fullAvatarURL) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Circle().fill(Color.gray.opacity(0.3))
                                }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                            .id(artist.fullAvatarURL)
                            
                            VStack(alignment: .leading) {
                                Text(artist.name)
                                    .font(.headline)
                                HStack(spacing: 4) {
                                    Text("作品:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let count = songCounts[artist.id] {
                                        Text("\(count)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .frame(width: 12, height: 12)
                                    }
                                }
                            }
                        }
                    }
                }
                .onDelete(perform: deleteArtists)
            }
        }
        .navigationTitle("虚拟艺人")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: CreateArtistView()) {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            loadArtists()
        }
        .alert("删除艺人", isPresented: $showDeleteConfirmation, presenting: artistToDelete) { artist in
            Button("取消", role: .cancel) {
                artistToDelete = nil
            }
            Button("删除", role: .destructive) {
                Task {
                    await performDelete(artist: artist)
                }
            }
        } message: { artist in
            Text("确定要删除艺人“\(artist.name)”吗？此操作将同时删除该艺人的所有歌曲，且不可恢复。")
        }
        .alert("错误", isPresented: .constant(errorMessage != nil)) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private func loadArtists() {
        guard let token = userService.currentToken else {
            errorMessage = "请先登录"
            return
        }
        isLoading = true
        errorMessage = nil
        virtualArtistService.getMyArtists(token: token) { result in
            isLoading = false
            switch result {
            case .success(let artists):
                myArtists = artists
                loadSongCounts(for: artists)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func loadSongCounts(for artists: [VirtualArtist]) {
        for artist in artists {
            virtualArtistService.fetchSongs(for: artist.id) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let songs):
                        songCounts[artist.id] = songs.count
                    case .failure:
                        songCounts[artist.id] = 0
                    }
                }
            }
        }
    }
    
    // ✅ 删除艺人
    private func deleteArtists(at offsets: IndexSet) {
        guard let token = userService.currentToken else {
            errorMessage = "请先登录"
            return
        }
        
        // 假设只删除一个（滑动删除场景）
        if let index = offsets.first {
            artistToDelete = myArtists[index]
            showDeleteConfirmation = true
        }
        
    }
    
    private func performDelete(artist: VirtualArtist) async {
        guard let token = userService.currentToken else { return }
        await MainActor.run { isDeleting = true }
        do {
            guard let artistIdUUID = UUID(uuidString: artist.id) else {
                throw NSError(domain: "InvalidArtistID", code: -1, userInfo: [NSLocalizedDescriptionKey: "艺人 ID 格式无效"])
            }
            try await virtualArtistService.deleteArtist(artistId: artistIdUUID, token: token)
            await MainActor.run {
                loadArtists()  // 重新加载列表
                isDeleting = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "删除失败: \(error.localizedDescription)"
                isDeleting = false
                artistToDelete = nil
            }
        }
    }
}
