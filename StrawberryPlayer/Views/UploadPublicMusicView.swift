//集成智能解析和封面匹配
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct UploadPublicMusicView: View {
    
    @State private var coordinator: Coordinator?
    
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var userService: UserService
    @Environment(\.dismiss) var dismiss
    
    // 上传状态
    @State private var selectedAudioFile: URL?
    @State private var originalFileName: String?
    @State private var isUploading = false
    @State private var isExtracting = false
    @State private var isMatchingCover = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showSuccess = false
    
    // 歌曲信息（自动提取后填充，但允许用户编辑）
    @State private var songTitle = ""
    @State private var artist = ""
    @State private var selectedStyle = "古典"
    @State private var duration: TimeInterval = 0
    @State private var matchedCoverURL: URL?
    
    // 文件大小限制：50MB
    private let maxFileSize: Int64 = 50 * 1024 * 1024
    
    // 风格选项
    let styleOptions = ["古典", "钢琴", "交响乐", "轻音乐", "室内乐", "独奏", "协奏曲", "其他"]
    
    var body: some View {
        NavigationStack {
            Form {
                // 音频文件选择
                Section("选择音频文件") {
                    Button(action: selectAudioFile) {
                        HStack {
                            Image(systemName: "music.note")
                            if let fileName = originalFileName {
                                Text(fileName)
                                    .lineLimit(1)
                            } else {
                                Text("点击选择音频文件")
                            }
                            Spacer()
                            if isExtracting {
                                ProgressView()
                            }
                        }
                    }
                }
                
                // 歌曲信息（可编辑）
                Section("歌曲信息") {
                    HStack {
                        Text("标题")
                        Spacer()
                        TextField("自动提取或手动输入", text: $songTitle)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.primary)
                    }
                    
                    HStack {
                        Text("艺术家")
                        Spacer()
                        TextField("自动提取或手动输入", text: $artist)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.primary)
                    }
                    
                    if duration > 0 {
                        HStack {
                            Text("时长")
                            Spacer()
                            Text(formatDuration(duration))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // 风格选择
                Section("选择风格") {
                    Picker("风格", selection: $selectedStyle) {
                        ForEach(styleOptions, id: \.self) { style in
                            Text(style).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedStyle) { _ in
                        matchCoverForCurrentSong()
                    }
                }
                
                // 封面预览（智能匹配）
                Section("封面（智能匹配）") {
                    if isMatchingCover {
                        HStack {
                            Spacer()
                            ProgressView("正在匹配封面...")
                            Spacer()
                        }
                        .frame(height: 150)
                    } else if let coverURL = matchedCoverURL {
                        AsyncImage(url: coverURL) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 200)
                                    .cornerRadius(8)
                            } else if phase.error != nil {
                                VStack {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                    Text("加载失败")
                                        .font(.caption)
                                }
                                .frame(height: 150)
                            } else {
                                ProgressView()
                                    .frame(height: 150)
                            }
                        }
                        .id(coverURL)   // 添加此行，匹配新封面时重建
                    } else {
                        HStack {
                            Spacer()
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .frame(height: 150)
                    }
                    
                    Text("系统将根据歌曲信息自动匹配封面")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // 上传按钮
                Section {
                    Button(action: uploadSong) {
                        if isUploading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("上传作品")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(selectedAudioFile == nil || songTitle.isEmpty || artist.isEmpty || isUploading)
                }
            }
            .navigationBarBackButtonHidden(true)  // 隐藏系统返回按钮
            .navigationTitle("上传公共版权音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.blue)
                    }
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定") { }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .alert("上传成功", isPresented: $showSuccess) {
                Button("确定") { dismiss() }
            } message: {
                Text("作品已成功上传")
            }
        }
    }
    
    // 选择音频文件
    private func selectAudioFile() {
        print("📂 弹出文件选择器")
        let coordinator = Coordinator(parent: self)
        self.coordinator = coordinator
        
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        documentPicker.allowsMultipleSelection = false
        documentPicker.delegate = coordinator
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(documentPicker, animated: true)
        }
    }
    
    // 匹配封面（调用智能匹配器）
    private func matchCoverForCurrentSong() {
        guard !artist.isEmpty, !songTitle.isEmpty else { return }
        isMatchingCover = true
        CoverMatcher.shared.matchCover(for: songTitle, artist: artist, style: selectedStyle) { url in
            DispatchQueue.main.async {
                self.matchedCoverURL = url
                self.isMatchingCover = false
            }
        }
    }
    
    // 上传歌曲
    private func uploadSong() {
        guard let audioFile = selectedAudioFile else { return }
        guard let token = userService.currentToken else {
            errorMessage = "请先登录"
            showError = true
            return
        }
        
        // 检查文件大小
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioFile.path)
            if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
                errorMessage = "文件过大，请选择小于50MB的音频文件"
                showError = true
                return
            }
        } catch {
            print("获取临时文件大小失败: \(error)")
        }
        
        isUploading = true
        
        Task {
            do {
                // 获取封面图片（如有）
                var coverImage: UIImage? = nil
                if !songTitle.isEmpty && !artist.isEmpty {
                    coverImage = await CoverMatcher.shared.fetchCoverImage(for: songTitle, artist: artist, style: selectedStyle)
                }
                
                // 上传成功后的处理（优化片段）
                let uploadedSong = try await VirtualArtistService.shared.uploadPublicDomainSong(
                    title: songTitle,
                    artist: artist,
                    style: selectedStyle,
                    audioFile: audioFile,
                    coverImage: coverImage,
                    token: token
                )
                
                // ✅ 缓存到本地持久化目录
                var finalSong = uploadedSong
                finalSong.streamURL = nil          // 防止播放时优先使用远程链接
                let ext = audioFile.pathExtension.isEmpty ? "mp3" : audioFile.pathExtension
                let localAudioURL = PlaybackService.localAudioURL(for: uploadedSong.id, extension: ext)
                
                do {
                    if !FileManager.default.fileExists(atPath: localAudioURL.path) {
                        try FileManager.default.copyItem(at: audioFile, to: localAudioURL)
                        print("✅ 音频已保存到本地: \(localAudioURL.path)")
                    } else {
                        print("ℹ️ 本地音频已存在，跳过复制")
                    }
                    finalSong.audioUrl = localAudioURL.absoluteString   // 切换为本地路径
                } catch {
                    print("⚠️ 保存本地音频失败，将使用远程URL: \(error)")
                    // 失败时保留原 audioUrl，上传仍然成功
                }
                
                await MainActor.run {
                    // 1. 将新歌曲添加到 libraryService.songs 中（使用包含本地路径的 finalSong）
                    self.libraryService.songs.append(finalSong)
                    
                    // 2. 发送通知，告知歌曲列表变化
                    NotificationCenter.default.post(name: .songsDidChange, object: nil)
                    
                    // 3. 关闭上传界面，显示成功
                    self.isUploading = false
                    self.showSuccess = true
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
    
    // 格式化时长
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // Coordinator 处理文档选择器
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: UploadPublicMusicView
        
        init(parent: UploadPublicMusicView) {
            self.parent = parent
        }
        
        deinit { print("🔴 Coordinator deinit") }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            print("✅ documentPicker 被调用，选择了 \(urls.count) 个文件")
            
            guard let originalURL = urls.first else {
                print("❌ 没有选择文件")
                return
            }
            
            print("✅ 选择了文件: \(originalURL)")
            
            guard originalURL.startAccessingSecurityScopedResource() else {
                print("❌ 无法获取文件安全访问权限")
                DispatchQueue.main.async {
                    self.parent.errorMessage = "无法访问所选文件，请重试"
                    self.parent.showError = true
                }
                return
            }
            
            defer {
                originalURL.stopAccessingSecurityScopedResource()
                print("🔒 释放文件安全访问权限")
            }
            
            do {
                let data = try Data(contentsOf: originalURL)
                print("✅ 读取文件成功，大小: \(data.count) 字节")
                
                let tempDir = FileManager.default.temporaryDirectory
                let tempFileURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(originalURL.pathExtension)")
                try data.write(to: tempFileURL)
                print("✅ 临时文件已创建: \(tempFileURL)")
                
                // 更新 UI
                DispatchQueue.main.async {
                    self.parent.selectedAudioFile = tempFileURL
                    self.parent.originalFileName = originalURL.lastPathComponent
                    self.parent.isExtracting = true
                    print("📝 UI 更新: originalFileName = \(originalURL.lastPathComponent)")
                }
                
                // 提取元数据
                Task {
                    do {
                        // 1. 尝试提取内嵌元数据
                        if let metadata = try await AudioMetadataExtractor.extract(from: tempFileURL) {
                            // 提取成功，但可能标题或艺术家为空
                            let finalTitle = metadata.title.isEmpty ? originalURL.deletingPathExtension().lastPathComponent : metadata.title
                            let finalArtist = metadata.artist.isEmpty ? "未知艺术家" : metadata.artist
                            await MainActor.run {
                                self.parent.songTitle = finalTitle
                                self.parent.artist = finalArtist
                                self.parent.duration = metadata.duration
                                self.parent.isExtracting = false
                                self.parent.matchCoverForCurrentSong()
                                print("✅ 元数据提取成功: 标题='\(finalTitle)', 艺术家='\(finalArtist)'")
                            }
                        } else {
                            // 2. 元数据提取失败，尝试从文件名智能解析
                            let fileName = originalURL.deletingPathExtension().lastPathComponent
                            if let (title, artist) = SmartMetadataParser.parse(fileName) {
                                await MainActor.run {
                                    self.parent.songTitle = title
                                    self.parent.artist = artist
                                    self.parent.isExtracting = false
                                    self.parent.matchCoverForCurrentSong()
                                    print("✅ 文件名解析成功: 标题='\(title)', 艺术家='\(artist)'")
                                }
                            } else {
                                // 3. 完全失败，使用文件名作为标题
                                let fileName = originalURL.deletingPathExtension().lastPathComponent
                                await MainActor.run {
                                    self.parent.songTitle = fileName
                                    self.parent.artist = "未知艺术家"
                                    self.parent.isExtracting = false
                                    print("⚠️ 无法提取元数据且无法解析文件名，使用文件名: \(fileName)")
                                }
                            }
                        }
                    } catch {
                        // 提取过程中出错，使用文件名
                        let fileName = originalURL.deletingPathExtension().lastPathComponent
                        await MainActor.run {
                            self.parent.songTitle = fileName
                            self.parent.artist = "未知艺术家"
                            self.parent.isExtracting = false
                            print("❌ 元数据提取错误: \(error.localizedDescription)，使用文件名: \(fileName)")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.parent.errorMessage = "读取文件失败: \(error.localizedDescription)"
                    self.parent.showError = true
                }
            }
        }
    }
}
