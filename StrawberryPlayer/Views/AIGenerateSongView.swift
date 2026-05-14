import SwiftUI

struct AIGenerateSongView: View {
    let artist: VirtualArtist
    @EnvironmentObject var virtualArtistService: VirtualArtistService
    @EnvironmentObject var userService: UserService
    @EnvironmentObject var libraryService: LibraryService
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    @Environment(\.dismiss) var dismiss
    
    // 状态：选择歌手、歌曲、封面
    @State private var selectedArtist: ReferenceArtist? = nil
    @State private var selectedSong: ReferenceSong? = nil
    @State private var selectedCoverURL: URL? = nil
    @State private var coverOptions: [URL] = []
    @State private var isLoadingCovers = false
    @State private var isGenerating = false
    
    @State private var stylePromptHasBeenEdited = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var syllableWarning: String? = nil
    
    // 歌词与风格编辑、参数调节
    @State private var lyricsText: String = ""
    @State private var stylePrompt: String = ""
    @State private var creativity: Double = 0.8
    @State private var isGeneratingLyrics = false
    @State private var isImprovingLyrics = false
    @State private var optimizationGoals: Set<String> = []
    @State private var generatedTitle: String = ""
    @State private var songTheme: String = ""
    
    @StateObject private var referenceService = ReferenceService.shared
    @State private var loadedArtists: [ReferenceArtist] = []
    @State private var loadedSongs: [String: [ReferenceSong]] = [:]
    
    let availableGoals = ["替换陈旧意象", "强化副歌记忆点", "丰富故事层次", "雕琢金句"]
    
    @State private var lyricsTemperature: Double = 0.85
    @State private var lyricsMaxTokens: Int = 3000
    @State private var musicTemperature: Double = 0.9
    @State private var songDuration: Double = 180
    @State private var useReferenceAudio = false
    @State private var selectedReferenceAudioURL: URL?
    @State private var isShowingFilePicker = false
    @State private var generateTask: Task<Void, Never>?
    
    // 添加焦点管理
    enum Field: Hashable {
        case lyrics, stylePrompt, songTheme
    }
    @FocusState private var focusedField: Field?
    
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 自定义顶部关闭按钮
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Text("AI 再创作")
                            .font(.headline)
                        Spacer()
                        Color.clear.frame(width: 30, height: 30)
                    }
                    .padding(.top, 8)
                    
                    // 剩余次数提示条
                    if let remaining = userService.currentUser?.aiSongRemaining, let limit = userService.currentUser?.aiSongLimit {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.yellow)
                            Text("今日剩余免费生成次数：\(remaining) / \(limit)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }
                    
                    // 剩余次数提示条
//                    if let remaining = userService.currentUser?.aiSongRemaining, let limit = userService.currentUser?.aiSongLimit {
//                        HStack {
//                            Image(systemName: remaining > 0 ? "sparkles" : "exclamationmark.triangle")
//                                .foregroundColor(remaining > 0 ? .yellow : .red)
//                            Text(remaining > 0 ? "今日剩余免费生成次数：\(remaining) / \(limit)" : "免费次数已用完，请付费解锁无限创作")
//                                .font(.caption)
//                                .foregroundColor(remaining > 0 ? .secondary : .red)
//                            Spacer()
//                        }
//                        .padding(.horizontal)
//                        .padding(.top, 4)
//                    }
                    
                    // 步骤1：选择歌手
                    stepHeader(number: 1, title: "选择歌手", isCompleted: selectedArtist != nil)
                    
                    if referenceService.isLoading {
                        ProgressView()
                    } else if loadedArtists.isEmpty {
                        Text("暂无可参考的歌手")
                            .foregroundColor(.secondary)
                    } else {
                        let availableArtists = referenceService.filterArtists(for: artist)
                        HStack {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(availableArtists) { artist in
                                        ArtistChip(
                                            artist: artist.name,
                                            isSelected: selectedArtist?.id == artist.id
                                        ) {
                                            selectedArtist = artist
                                            selectedSong = nil
                                            selectedCoverURL = nil
                                            Task {
                                                await referenceService.loadSongs(for: artist.id)
                                                await MainActor.run {
                                                    loadedSongs = referenceService.songsByArtistId
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            Button(action: randomSelectArtist) {
                                Image(systemName: "dice")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                            }
                            .padding(.trailing, 8)
                        }
                    }
                    
                    // 步骤2：选择歌曲
                    if let artist = selectedArtist,
                       let songs = loadedSongs[artist.id], !songs.isEmpty {
                        stepHeader(number: 2, title: "选择歌曲", isCompleted: selectedSong != nil)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(songs) { song in
                                ReferenceSongCard(
                                    song: song,
                                    isSelected: selectedSong?.id == song.id
                                ) {
                                    selectedSong = song
                                    selectedCoverURL = nil
                                    generateCoverOptions(for: song)
                                    generateInitialLyricsAndStyle(for: song)
                                    songTheme = song.theme
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("随机一首") {
                                randomSelectSong(from: songs)
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.top, 4)
                        }
                    }
                    
                    // 步骤3：调整歌词与风格
                    if let song = selectedSong {
                        stepHeader(number: 3, title: "调整歌词与风格", isCompleted: !lyricsText.isEmpty && !stylePrompt.isEmpty)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            // 歌词编辑区
                            HStack {
                                Text("歌词")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                if isGeneratingLyrics || isImprovingLyrics {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                            TextEditor(text: $lyricsText)
                                .frame(height: 120)
                                .padding(4)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                .disabled(isGeneratingLyrics || isImprovingLyrics || isGenerating)
                                .focused($focusedField, equals: .lyrics)
                            
                            // 👇 新增警告文字
                            if let warning = syllableWarning {
                                Text(warning)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.top, 4)
                                    .transition(.opacity)
                            }
                            
                            // 歌词生成控制区
                            HStack {
                                Text("歌词创作温度: \(lyricsTemperature, specifier: "%.2f")")
                                    .font(.subheadline)
                                Slider(value: $lyricsTemperature, in: 0.3...1.2, step: 0.05)
                                    .frame(maxWidth: .infinity)
                            }
                            
                            HStack {
                                Text("歌词最大长度: \(lyricsMaxTokens) 字")
                                    .font(.subheadline)
                                HStack(spacing: 12) {
                                    Button(action: {
                                        if lyricsMaxTokens > 500 {
                                            lyricsMaxTokens -= 100
                                        }
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .font(.title2)
                                            .foregroundColor(lyricsMaxTokens > 500 ? .blue : .gray)
                                    }
                                    .disabled(lyricsMaxTokens <= 500)
                                    
                                    Text("\(lyricsMaxTokens)")
                                        .font(.subheadline)
                                        .frame(minWidth: 50)
                                    
                                    Button(action: {
                                        if lyricsMaxTokens < 5000 {
                                            lyricsMaxTokens += 100
                                        }
                                    }) {
                                        Image(systemName: "plus.circle")
                                            .font(.title2)
                                            .foregroundColor(lyricsMaxTokens < 5000 ? .blue : .gray)
                                    }
                                    .disabled(lyricsMaxTokens >= 5000)   // ✅ 修复上限逻辑
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            
                            // 生成/优化歌词按钮
                            HStack {
                                if lyricsText.isEmpty || lyricsText == "无法自动生成歌词，请手动输入..." {
                                    Button("生成歌词") {
                                        generateInitialLyricsAndStyle(for: song)
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(16)
                                    .disabled(isGeneratingLyrics)
                                } else {
                                    Button("优化歌词") {
                                        optimizeLyrics()
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(16)
                                    .disabled(isImprovingLyrics || lyricsText.isEmpty)
                                }
                                Spacer()
                            }
                            .padding(.top, 4)
                            
                            // 优化目标
                            if !lyricsText.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("优化目标（可多选）")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    FlowLayout(spacing: 8) {
                                        ForEach(availableGoals, id: \.self) { goal in
                                            Button(action: {
                                                if optimizationGoals.contains(goal) {
                                                    optimizationGoals.remove(goal)
                                                } else {
                                                    optimizationGoals.insert(goal)
                                                }
                                            }) {
                                                Text(goal)
                                                    .font(.caption)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 6)
                                                    .background(optimizationGoals.contains(goal) ? Color.blue : Color.gray.opacity(0.2))
                                                    .foregroundColor(optimizationGoals.contains(goal) ? .white : .primary)
                                                    .cornerRadius(16)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            }
                            
                            // 风格描述
                            Text("风格描述")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            TextEditor(text: Binding(
                                get: { stylePrompt },
                                set: { newValue in
                                    stylePrompt = newValue
                                    stylePromptHasBeenEdited = true   // 用户手动编辑过
                                }
                            ))
                            .frame(height: 70)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            
                            
                            TextField("创作主题（如：雨夜告别）", text: $songTheme)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .padding(.vertical, 4)
                                .focused($focusedField, equals: .stylePrompt)   // ✅ 添加焦点绑定
                            
                            // 音乐创意度和目标时长
                            HStack {
                                Text("音乐创意度: \(musicTemperature, specifier: "%.2f")")
                                    .font(.subheadline)
                                Slider(value: $musicTemperature, in: 0.3...1.2, step: 0.05)
                                    .frame(maxWidth: .infinity)
                            }
                            
                            HStack {
                                Text("目标时长: \(Int(songDuration)) 秒")
                                    .font(.subheadline)
                                Slider(value: $songDuration, in: 60...240, step: 10)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    // 参考音轨选项
                    if selectedSong != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("使用参考音轨提升演唱准确度（推荐）", isOn: $useReferenceAudio)
                                .font(.subheadline)
                            if useReferenceAudio {
                                Button("选择参考音频文件") {
                                    isShowingFilePicker = true
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(16)
                                if let url = selectedReferenceAudioURL {
                                    Text("已选择: \(url.lastPathComponent)")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                Text("建议上传 30 秒以上、无背景噪音的人声或完整歌曲片段，格式支持 MP3/M4A/WAV。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    // 步骤4：选择封面
                    if let song = selectedSong {
                        stepHeader(number: 4, title: "选择封面", isCompleted: selectedCoverURL != nil)
                        if isLoadingCovers {
                            ProgressView("生成封面中...")
                                .frame(maxWidth: .infinity, minHeight: 140)
                        } else if !coverOptions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(coverOptions, id: \.self) { url in
                                        let isGeneratedCover = url != song.coverURL
                                        let title = isGeneratedCover
                                        ? (coverOptions.firstIndex(of: url).map { "风格 \($0 + 1)" } ?? "封面")
                                        : "原版"
                                        CoverOptionCard(
                                            coverURL: url,
                                            isSelected: selectedCoverURL == url,
                                            title: title
                                        ) {
                                            selectedCoverURL = url
                                        }
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    
                    Spacer(minLength: 30)
                    
                    Button(action: generateSong) {
                        if isGenerating {
                            VStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("AI 创作中...")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("AI 再创作")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: selectedSong != nil && selectedCoverURL != nil ? [.blue, .purple] : [.gray, .gray],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(28)
                    .disabled(selectedSong == nil || selectedCoverURL == nil || isGenerating || isGeneratingLyrics || isImprovingLyrics || lyricsText.isEmpty)
                    .padding(.bottom, 8)
                    
                    
                    
                    // 底部按钮
//                    Button(action: {
//                        if canGenerate {
//                            generateSong()
//                        } else {
//                            showPurchaseOption()   // 弹出付费购买界面
//                        }
//                    }) {
//                        if isGenerating {
//                            VStack {
//                                ProgressView()
//                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
//                                Text("AI 创作中...")
//                                    .font(.caption)
//                                    .foregroundColor(.white)
//                            }
//                            .frame(maxWidth: .infinity)
//                        } else {
//                            Text(canGenerate ? "AI 再创作" : "购买次数")
//                                .font(.headline)
//                                .frame(maxWidth: .infinity)
//                        }
//                    }
//                    .frame(height: 56)
//                    .background(
//                        LinearGradient(
//                            colors: canGenerate && selectedSong != nil && selectedCoverURL != nil ? [.blue, .purple] : [.gray, .gray],
//                            startPoint: .leading,
//                            endPoint: .trailing
//                        )
//                    )
//                    .foregroundColor(.white)
//                    .cornerRadius(28)
//                    .disabled(!canGenerate && (selectedSong == nil || selectedCoverURL == nil || isGenerating || isGeneratingLyrics || isImprovingLyrics || lyricsText.isEmpty))
//                    .padding(.bottom, 8)
                    
                    if isGenerating {
                        if !virtualArtistService.generationProgress.isEmpty {
                            Text(virtualArtistService.generationProgress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                                .transition(.opacity)
                        } else {
                            Text("🎵 AI 正在为您创作歌曲，预计需要 5~10 分钟，请耐心等待...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal)   // 🆕 添加这一行
                .padding(.bottom, 30)
            }
            
        .onTapGesture {
            // 点击空白区域收起键盘
            focusedField = nil
        }
        .fileImporter(isPresented: $isShowingFilePicker, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                selectedReferenceAudioURL = url
            case .failure(let error):
                print("选择文件失败: \(error)")
            }
        }
        .alert("提示", isPresented: $showError) {
            Button("确定") { }
            Button("购买次数") {
                // 简化付费入口：跳转或弹窗提示
                showPurchaseOption()
            }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        //        .alert("错误", isPresented: $showError) {
        //            Button("确定") { }
        //        } message: {
        //            Text(errorMessage ?? "未知错误")
        //        }
        .onAppear {
            playbackService.setPlayerUIMode(.hidden)   // 进入生成页面时隐藏迷你播放器
            
            // 清理临时文件和缓存
            URLCache.shared.removeAllCachedResponses()
            
            // 清理临时文件
            let tempDir = FileManager.default.temporaryDirectory
            if let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            
            // 通知系统释放内存
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            
            Task {
                await referenceService.loadArtists()
                await MainActor.run {
                    loadedArtists = referenceService.artists
                }
            }
            
            Task {
                if let token = userService.currentToken {
                    // 刷新用户信息以获取最新剩余次数
                    _ = try? await userService.refreshUserInfo()
                }
            }
            
            // 🔥 进入生成页时，主动清理一遍 App 全局缓存，为新封面腾出空间
            URLCache.shared.removeAllCachedResponses()
            ImageCacheManager.shared.clearCache()
        }
        .onDisappear {
            // ✅ 取消正在进行的生成任务
            generateTask?.cancel()
            generateTask = nil
            coverOptions = []
            selectedCoverURL = nil
            lyricsText = ""
            stylePrompt = ""
            
            // 🔥 退出页面时，强制清理当前页面的所有图片和全局缓存
            URLCache.shared.removeAllCachedResponses()
            ImageCacheManager.shared.clearCache()
            
            
            // 如果当前有歌曲播放，返回后显示迷你播放器；否则保持隐藏
            if playbackService.currentSong != nil {
                playbackService.setPlayerUIMode(.mini)
            }
            
            // 建议给系统一个喘息的机会
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            }
        }
    }
    
    // MARK: - 步骤头部组件
    @ViewBuilder
    private func stepHeader(number: Int, title: String, isCompleted: Bool) -> some View {
        HStack {
            Text("\(number). \(title)")
                .font(.headline)
            Spacer()
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.default, value: isCompleted)
    }
    
    // MARK: - 随机选择歌手
    private func randomSelectArtist() {
        let available = referenceService.filterArtists(for: artist)
        guard let randomArtist = available.randomElement() else { return }
        selectedArtist = randomArtist
        selectedSong = nil
        selectedCoverURL = nil
        stylePromptHasBeenEdited = false
        Task {
            await referenceService.loadSongs(for: randomArtist.id)
            await MainActor.run {
                loadedSongs = referenceService.songsByArtistId
            }
        }
    }
    
    // MARK: - 随机选择歌曲
    private func randomSelectSong(from songs: [ReferenceSong]) {
        guard let randomSong = songs.randomElement() else { return }
        selectedSong = randomSong
        selectedCoverURL = nil
        stylePromptHasBeenEdited = false
        generateCoverOptions(for: randomSong)
        generateInitialLyricsAndStyle(for: randomSong)
        songTheme = randomSong.theme
    }
    
    // MARK: - 生成封面候选项
    private func generateCoverOptions(for song: ReferenceSong) {
        guard let token = userService.currentToken else { return }   // 已在主线程
        
        isLoadingCovers = true
        coverOptions = []
        selectedCoverURL = nil
        
        let gender = selectedArtist?.gender
        Task.detached(priority: .background) { [token, song, gender] in   // 捕获 gender
            do {
                print("🔄 开始为歌曲 \(song.title) 生成封面选项")
                let options = try await self.virtualArtistService.generateCovers(
                    title: song.title,
                    artist: song.artist,
                    coverURL: song.coverURL?.absoluteString,
                    count: 2,  // ✅ 减少到 2 张，降低内存压力
                    token: token,
                    gender: gender
                )
                print("✅ 封面选项生成成功，数量: \(options.count)")
                
                await MainActor.run {
                    var urls = options.compactMap { URL(string: $0) }
                    urls = Array(Set(urls))
                    
                    if urls.isEmpty {
                        if let original = song.coverURL {
                            coverOptions = [original]
                            selectedCoverURL = original
                            print("⚠️ 封面生成返回空列表，使用原版封面")
                        } else {
                            coverOptions = []
                            selectedCoverURL = nil
                            print("❌ 封面生成失败且无原版封面")
                        }
                    } else {
                        coverOptions = urls
                        selectedCoverURL = urls.first
                    }
                    isLoadingCovers = false
                }
            } catch {
                print("❌ 生成封面选项失败: \(error)")
                await MainActor.run {
                    if let original = song.coverURL {
                        coverOptions = [original]
                        selectedCoverURL = original
                    } else {
                        coverOptions = []
                        selectedCoverURL = nil
                    }
                    isLoadingCovers = false
                }
            }
        }
    }
    
    // MARK: - 生成初始歌词和风格
    private func generateInitialLyricsAndStyle(for song: ReferenceSong) {
        guard let token = userService.currentToken else {
            lyricsText = "请先登录"
            isGeneratingLyrics = false
            return
        }
        guard let selectedArtist = selectedArtist else { return }
        let baseStyle = referenceService.stylePrompt(for: selectedArtist)        // 长风格描述（精细描述）
        let shortStyle = selectedArtist.shortStyleReference ?? ""                // 短风格关键词（从数据库来）
        let themeGuide = selectedArtist.themeGuidance ?? ""                      // 主题引导（从数据库来）
        if !stylePromptHasBeenEdited {
            self.stylePrompt = baseStyle
        }
        
        syllableWarning = nil
        isGeneratingLyrics = true
        lyricsText = ""
        
        // ✅ 动态获取当前歌曲的参考歌词和意象提示（后端维护）
        let referenceLyrics = song.lyrics ?? ""
        let imageryHint = song.imageryHint ?? ""
        
        Task {
            do {
                guard let token = userService.currentToken else {
                    throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
                }
                
                let language = selectedArtist.language ?? "国语"
                
                // 意象指导（根据语言和实际意象提示动态生成）
                let imageryGuidance: String = {
                    if !imageryHint.isEmpty {
                        return "优先使用以下意象进行创作：\(imageryHint)。请用这些物象构建场景，避免抽象抒情。"
                    } else {
                        switch language {
                        case "粤语": return "避免空洞词汇，优先选用粤语歌词常见的具体物象（如海风、街灯、旧照片等）。"
                        case "English": return "Use concrete, visual details from everyday life. Avoid abstract metaphors."
                        default: return "避免使用“月光/誓言/泪水”等抽象词汇，选择具体的生活细节。"
                        }
                    }
                }()
                
                // 动态构建提示词（无任何硬编码的歌曲名或歌手名）
                var prompt = """
                你是一位深谙\(selectedArtist.name)创作风格的顶级作词人。请以该歌手的代表作《\(song.title)》为风格蓝本，创作一首全新歌词，要求如下：
                
                1. **核心风格模仿**：
                   - 参考歌曲：《\(song.title)》，学习其叙事方式、用词习惯和情感基调。
                   - 关键风格词：\(shortStyle.isEmpty ? baseStyle : shortStyle)
                   - 必须严格模仿该歌手的典型句式、用词习惯和情感表达方式。
                   \(language == "粤语" ? "请使用地道、口语化的粤语创作，严格避免普通话词汇。" : (language == "English" ? "Create the lyrics in English." : "请使用国语创作。"))
                
                2. **主题与故事**：
                   - 核心主题：\(song.theme)
                   - 故事需有完整起承转合，用具体场景推进情感。
                   \(themeGuide.isEmpty ? "" : "- 额外主题引导：" + themeGuide)
                
                3. **意象创新**：
                   \(imageryGuidance)
                
                4. **参考歌词范例**（供学习其用词、句式和意象，但最终歌词必须全新创作）：
                   “\(referenceLyrics)”
                
                5. **金句设计**：
                   副歌必须有一句高度记忆点的句子（比喻/反转/情感爆发）。
                
                6. **韵律与演唱（精确硬性要求）**：
                   - **主歌（Verse）**：所有主歌句子严格控制在7-8个字。全部主歌句子中，最长句与最短句字数差距**不得大于1个字**。
                   - **副歌（Chorus）**：对应位置的句子字数必须完全相等。例如，如果第一遍副歌的第一句是7个字，那么后面每次重复副歌时，第一句都必须是7个字。
                   - **整体字数范围**：整首歌词中，最长的一句不得超过10个字，最短的一句不得少于6个字。
                   \(language == "粤语" ? "**粤语特别要求**：务必确保符合粤语口语习惯，避免为了凑字数而强行增减字，导致歌词不通顺。" : "")
                
                7. **格式要求（严格遵守）**：
                   - 只输出纯歌词文本。禁止任何括号、标记、符号。
                   - 段落之间使用一个空行分隔。
                   - 歌名直接写在第一行，**不要**加【】或任何符号。示例：第一行直接写 浪声里的旧号码。
                   - 总长度约\(lyricsMaxTokens)字以内。
                                
                \(baseStyle)
                
                请直接输出歌词（第一行是歌名，不要加【】符号）：
                """
                
                // 按语言补充具体要求（动态）
                switch language {
                case "粤语":
                    prompt += "\n**演唱语言：粤语**"
                    prompt += "\n- 必须使用地道、口语化的粤语，不可出现普通话词汇。"
                    prompt += "\n- 每句字数控制在 7~10 字，最长句与最短句差距不超过 3 字。"
                    prompt += "\n- 副歌必须押韵，推荐使用“-oeng”、“-in”、“-ou”、“-ing”等粤语常用韵脚。"
                    prompt += "\n- 金句要求：副歌要有一句高度浓缩、极易传唱的句子，例如“笑骂由人 洒脱地做人”。"
                case "English":
                    prompt += """
                    
                    **CRITICAL English Lyric Requirements (Must Follow)**:
                    - Create a complete, professional-grade lyric in English.
                    - Total length: at least 4 verses, 2 choruses, and a bridge (minimum 16 lines).
                    - Syllable control: EVERY line must contain exactly 8-10 syllables. Count syllables precisely.
                      Example of 9-syllable line: "We slow dance in the dark, our bodies sway".
                    - Rhyme scheme: The chorus must have a perfect end rhyme throughout (all lines rhyme with the same sound).
                      Preferred rhyme families: /aɪ/ (night, light, sky, eyes) or /iː/ (be, see, me, free) or /oʊ/ (go, know, slow, glow).
                    - Imagery: Use warm, intimate, sensory details (barefoot on grass, stars, whispers, dancing, moonlight).
                      FORBIDDEN: violent, military, or harsh words (spear, war, fight, battle, etc.).
                    - HOOK: The chorus must contain one unforgettable, emotionally powerful line that could be sung by millions –
                      for example "I found my forever in your eyes" or "We're barefoot dancing in the dark".
                    - Output only the lyrics, no chord notations, no stage directions, no extra symbols.
                    """
                default:
                    prompt += "\n**语言要求**：请使用国语创作。"
                    prompt += "\n- 每句控制在 7~10 个字，最长句与最短句差距 ≤3 字。"
                    prompt += "\n- 副歌必须押韵，韵脚统一不生硬。"
                    prompt += "\n- 金句设计：副歌需要一句高度记忆点（比喻、反转或情感爆发），例如“如果那两个字没有颤抖，我不会发现难受”。"
                }
                
                // 附加短风格关键词
                if !shortStyle.isEmpty {
                    prompt += "\n\n核心风格关键词：\(shortStyle)"
                }
                
                prompt += """
                ⚠️ 重要：
                - 第一行就是歌名，直接写歌名本身，不要加【】、【Song Title】或其它任何符号。
                - 只输出纯歌词文本，不要输出任何自检报告、解释、备注或额外信息。
                - 段落之间用一个空行分隔。
                """
                
                let (title, cleaned) = try await generateWithRetry(
                    prompt: prompt,
                    temperature: lyricsTemperature,
                    maxTokens: lyricsMaxTokens,
                    language: language
                )
                
                await MainActor.run {
                    lyricsText = cleaned
                    generatedTitle = title
                    isGeneratingLyrics = false
                }
            } catch {
                await MainActor.run {
                    lyricsText = "无法自动生成歌词，请手动输入..."
                    isGeneratingLyrics = false
                }
            }
        }
    }
    
    nonisolated private func cleanLyrics(_ lyrics: String) -> String {
        return autoreleasepool { () -> String in
            // 使用 NSMutableString 进行原地修改，减少内存分配
            let mutable = NSMutableString(string: lyrics)
            
            // 优化：同时去除未闭合括号
            let bracketPattern = "（[^（）]*）?|\\([^()]*\\)?|\\[.*?\\]?|【.*?】?"
            let bracketRegex = try? NSRegularExpression(pattern: bracketPattern)
            bracketRegex?.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "")
            
            // 去除特殊符号（逐个替换，但只生成最终一个字符串）
            let symbolsToRemove = ["*", "#", "@", "～", "~", "`", "「", "」", "『", "』", "•", "■", "□"]
            for symbol in symbolsToRemove {
                mutable.replaceOccurrences(of: symbol, with: "", range: NSRange(location: 0, length: mutable.length))
            }
            
            // 压缩连续空行
            let newlineRegex = try? NSRegularExpression(pattern: "\\n{3,}")
            newlineRegex?.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "\n\n")
            
            return mutable.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    
    // MARK: - 带自动重试的歌词生成（含音节均匀性检测）
    private func generateWithRetry(
        prompt: String,
        temperature: Double,
        maxTokens: Int,
        language: String,
        attempt: Int = 0
    ) async throws -> (String, String) {
        // 确保每次请求都有足够的 token 空间产出完整歌词（最少 4000）
        let effectiveTokens = max(maxTokens, 4000)
        
        let (title, rawLyrics) = try await DeepSeekService.shared.generateLyrics(
            prompt: prompt,
            temperature: attempt > 0 ? temperature * 0.65 : temperature,
            maxTokens: effectiveTokens
        )
        
        let cleaned = await Task.detached(priority: .userInitiated) {
            return autoreleasepool { self.cleanLyrics(rawLyrics) }
        }.value
        
        // 1. 基本保护：完全为空则重试
        guard !cleaned.isEmpty else {
            if attempt < 1 {
                return try await generateWithRetry(prompt: prompt, temperature: temperature * 0.65,
                                                   maxTokens: 8000, language: language, attempt: attempt + 1)
            }
            throw NSError(domain: "LyricsError", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "生成的歌词为空"])
        }
        
        // 2. 行数检查：一首完整的歌词至少应有 12 行（主歌×2+副歌+桥段）
        let lines = cleaned.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count < 12 {
            if attempt < 2 {
                print("⚠️ 歌词行数不足 (\(lines.count) 行)，自动重试")
                return try await generateWithRetry(prompt: prompt, temperature: temperature * 0.65,
                                                   maxTokens: 8000, language: language, attempt: attempt + 1)
            }
            // 行数仍不足但非空，直接采用并警告
            print("⚠️ 歌词行数仍不足 (\(lines.count) 行)，但直接采用")
            return (title, cleaned)
        }
        
        // 3. 音节均匀度检查（仅英文，中文按字数计）
        if language == "English" {
            let syllableCounts = lines.map { countSyllables(in: $0, language: language) }
            let avg = syllableCounts.reduce(0, +) / max(1, syllableCounts.count)
            let variance = syllableCounts.reduce(0.0) { $0 + pow(Double($1) - Double(avg), 2) } / Double(syllableCounts.count)
            let stdDev = sqrt(variance)
            
            // 条件放宽：平均音节在 7~12 之间，标准差 ≤3.5
            if !((7...12).contains(avg) && stdDev <= 3.5) {
                if attempt < 2 {
                    print("⚠️ 英文音节不均匀 (avg=\(avg), std=\(String(format: "%.1f", stdDev)))，重试")
                    return try await generateWithRetry(prompt: prompt, temperature: temperature * 0.65,
                                                       maxTokens: 8000, language: language, attempt: attempt + 1)
                }
                print("⚠️ 音节仍不均匀，但内容有效，直接采用")
            }
        } else {
            // 中文/粤语：字数检查 7~12，标准差 ≤3.5
            let charCounts = lines.map { $0.count }
            let avg = charCounts.reduce(0, +) / max(1, charCounts.count)
            let variance = charCounts.reduce(0.0) { $0 + pow(Double($1) - Double(avg), 2) } / Double(charCounts.count)
            let stdDev = sqrt(variance)
            if !((7...12).contains(avg) && stdDev <= 3.5) {
                if attempt < 2 {
                    print("⚠️ 歌词字数不均匀 (avg=\(avg), std=\(String(format: "%.1f", stdDev)))，重试")
                    return try await generateWithRetry(prompt: prompt, temperature: temperature * 0.65,
                                                       maxTokens: 8000, language: language, attempt: attempt + 1)
                }
                print("⚠️ 歌词字数仍不均匀，但内容有效，直接采用")
            }
        }
        
        return (title, cleaned)
    }
    // MARK: - 优化歌词
    private func optimizeLyrics() {
        guard !lyricsText.isEmpty else { return }
        let finalGoals: Set<String>
        if optimizationGoals.isEmpty {
            finalGoals = Set(availableGoals)
            print("🎯 未选择优化目标，将使用默认全部目标: \(finalGoals)")
        } else {
            finalGoals = optimizationGoals
        }
        
        let referenceArtistLanguage = selectedArtist?.language ?? "国语"   // 👈 新增
        isImprovingLyrics = true
        
        Task {
            do {
                guard let token = userService.currentToken else {
                    throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
                }
                
                let referenceLyrics = selectedSong?.lyrics ?? ""
                let referenceImageryHint = selectedSong?.imageryHint ?? ""
                
                let (title, improved) = try await virtualArtistService.improveLyrics(
                    currentLyrics: lyricsText,
                    task: "optimize",
                    theme: songTheme,
                    referenceArtist: selectedArtist?.name,
                    optimizationGoals: finalGoals,
                    token: token,
                    temperature: lyricsTemperature,
                    maxTokens: lyricsMaxTokens,
                    referenceLyrics: referenceLyrics,              // ✅
                    referenceImageryHint: referenceImageryHint     // ✅
                )
                
                let cleaned = await Task.detached(priority: .userInitiated) {
                    return autoreleasepool { () -> String in
                        return cleanLyrics(improved)
                    }
                }.value
                
                await MainActor.run {
                    lyricsText = cleaned
                    generatedTitle = title
                    
                    // ✅ 使用 referenceArtistLanguage
                    let lines = cleaned.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    let counts = lines.map { countSyllables(in: $0, language: referenceArtistLanguage) }
                    let avg = counts.reduce(0, +) / max(1, counts.count)
                    let isEnglish = referenceArtistLanguage == "English"
                    let validRange = isEnglish ? (8...12) : (7...12)
                    if validRange.contains(avg) {
                        syllableWarning = nil
                    } else {
                        syllableWarning = "歌词音节不符合演唱要求，建议优化或重新生成"
                    }
                    
                    isImprovingLyrics = false
                }
            } catch {
                await MainActor.run {
                    isImprovingLyrics = false
                    errorMessage = "优化失败：\(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
    
    
    // MARK: - 提交生成（新歌置顶，完整播放列表，发送通知）
    private func generateSong() {
        // ✅ 先取消之前的生成任务
        generateTask?.cancel()
        generateTask = nil
        virtualArtistService.generationProgress = ""
        guard let song = selectedSong, let coverURL = selectedCoverURL,
              let token = userService.currentToken else {
            errorMessage = "请完成所有选择"
            showError = true
            return
        }
        
        let trimmedLyrics = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLyrics.isEmpty else {
            errorMessage = "请输入歌词"
            showError = true
            return
        }
        
        let finalTitle = generatedTitle.isEmpty ? song.title : generatedTitle
        let normalizedTitle = finalTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArtist = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // 检查是否已存在同名同艺人歌曲
        let existingSong = libraryService.songs.first {
            $0.title.lowercased() == normalizedTitle &&
            $0.artist.lowercased() == normalizedArtist
        }
        
        if existingSong != nil {
            errorMessage = "歌曲《\(finalTitle)》已存在，请勿重复生成"
            showError = true
            return
        }
        
        // 生成前清理缓存，降低内存峰值
        URLCache.shared.removeAllCachedResponses()
        let tempDir = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("creation_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        
        isGenerating = true
        
        // 校验剩余次数
        guard let remaining = userService.currentUser?.aiSongRemaining, remaining > 0 else {
            errorMessage = "免费次数已用完，请付费解锁更多生成次数"
            showError = true
            isGenerating = false
            return
        }
        
        generateTask = Task {
            do {
                
                // 1. 生成歌曲
                let generatedSong = try await virtualArtistService.generateSongFromReference(
                    originalSong: song,
                    selectedCoverURL: coverURL,
                    creativity: musicTemperature,
                    duration: songDuration,
                    artist: artist,
                    customLyrics: trimmedLyrics,
                    customStylePrompt: stylePrompt,
                    customTitle: generatedTitle,
                    token: token,
                    lyricsTemperature: lyricsTemperature,
                    lyricsMaxTokens: lyricsMaxTokens,
                    referenceAudioURL: useReferenceAudio ? selectedReferenceAudioURL : nil
                )
                
                try Task.checkCancellation()
                
                // 2. 缓存到本地，确保立即播放
                var finalSong = generatedSong
                do {
                    let localURL = try await virtualArtistService.downloadSongToLocal(generatedSong)
                    finalSong.audioUrl = localURL.absoluteString
                    // ⚠️ 关键：清空可能已存在的 streamURL，防止播放时优先使用远程链接
                    finalSong.streamURL = nil
                    print("✅ AI 歌曲已缓存到本地: \(localURL.path)")
                } catch {
                    print("⚠️ 缓存本地音频失败，将使用远程URL: \(error)")
                }
                
                // 3. 创建最终的 Song 对象（使用 finalSong 的 audioUrl）
                var correctedSong = Song(
                    id: finalSong.id,
                    title: finalSong.title,
                    artist: finalSong.artist,
                    album: finalSong.album,
                    duration: finalSong.duration,
                    audioUrl: finalSong.audioUrl ?? "",   // ← 使用最终确定的 URL
                    coverUrl: finalSong.coverUrl,
                    lyrics: trimmedLyrics,
                    virtualArtist: finalSong.virtualArtist,
                    virtualArtistId: finalSong.virtualArtistId ?? UUID(uuidString: artist.id),
                    creatorId: finalSong.creatorId,
                    isUserGenerated: finalSong.isUserGenerated,
                    wordLyrics: finalSong.wordLyrics,
                    createdAt: finalSong.createdAt,
                    style: finalSong.style
                )
                
                try Task.checkCancellation()
                
                // 4. 主线程更新 UI 与播放列表
                await MainActor.run {
                    isGenerating = false
                    
                    // 将 correctedSong 更新到全局歌曲库
                    var libSongs = libraryService.songs
                    if let index = libSongs.firstIndex(where: { $0.id == correctedSong.id }) {
                        libSongs[index] = correctedSong
                    } else {
                        libSongs.append(correctedSong)
                    }
                    libraryService.songs = libSongs
                    
                    // 构建该艺人的完整播放列表（新歌置顶）
                    let artistId = artist.id
                    let allArtistSongs = libSongs.filter { song in
                        guard let vid = song.virtualArtistId,
                              let artistUUID = UUID(uuidString: artistId) else { return false }
                        return vid == artistUUID
                    }
                    let otherSongs = allArtistSongs.filter { $0.id != correctedSong.id }
                    let newPlaylist = [correctedSong] + otherSongs
                    
                    // 设置播放列表并从第一首开始播放
                    playbackService.ensureAudioSessionIsActive()
                    playbackService.setPlaylist(songs: newPlaylist, startIndex: 0)
                    
                    // 发送通知，关闭页面
                    NotificationCenter.default.post(name: .songsDidChange, object: nil)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    if error is CancellationError {
                        print("⏹️ 生成任务被取消")
                    } else {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }
    
    private func showPurchaseOption() {
        // 简化版：弹窗告知功能开发中（可替换为真正的 IAP 页面）
        let alert = UIAlertController(title: "付费解锁", message: "该功能正在建设中，敬请期待。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好的", style: .default))
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            rootVC.present(alert, animated: true)
        }
    }
    
}

// MARK: - 子视图组件（保持不变）
struct ArtistChip: View {
    let artist: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(artist)
                .font(.system(size: 16, weight: .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(isSelected ? Color.blue : Color(.systemGray6))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(25)
        }
    }
}

struct ReferenceSongCard: View {
    let song: ReferenceSong
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let coverURL = song.coverURL {
                        AsyncImage(url: coverURL) { phase in
                            switch phase {
                            case .empty:
                                placeholderCover
                            case .success(let image):
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                            case .failure:
                                placeholderCover
                            @unknown default:
                                placeholderCover
                            }
                        }
                        .id(coverURL)
                    } else {
                        placeholderCover
                    }
                }
                .frame(height: 120)
                .clipped()
                .cornerRadius(8)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var placeholderCover: some View {
        Rectangle()
            .fill(LinearGradient(
                gradient: Gradient(colors: [.blue, .purple]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundColor(.white.opacity(0.5))
            )
    }
    
}

struct CoverOptionCard: View {
    let coverURL: URL
    let isSelected: Bool
    let title: String
    let action: () -> Void
    
    // ✅ 使用一个可缓存、可降采样的加载器
    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let image = loadedImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipped()
                            .cornerRadius(8)
                    } else {
                        // 占位符，保持布局稳定
                        ProgressView()
                            .frame(width: 120, height: 120)
                            .onAppear(perform: loadAndDownsampleImage)
                    }
                }
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(isSelected ? .blue : .primary)
            }
            .padding(8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onDisappear {
            // 视图移出屏幕时，可以置空以释放图片内存
            loadedImage = nil
        }
    }
    
    private func loadAndDownsampleImage() {
        
        // ✅ 兼容 data URL (Base64)
        if coverURL.scheme == "data" {
            let dataString = coverURL.absoluteString
            guard let commaIndex = dataString.firstIndex(of: ",") else { return }
            let base64String = String(dataString[dataString.index(after: commaIndex)...])
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    if let imageData = Data(base64Encoded: base64String),
                       let rawImage = UIImage(data: imageData) {
                        let targetSize = CGSize(width: 120, height: 120)
                        let downsampled = rawImage.preparingThumbnail(of: targetSize)
                        ImageCacheManager.shared.setImage(downsampled ?? rawImage, for: self.coverURL)
                        DispatchQueue.main.async {
                            self.loadedImage = downsampled ?? rawImage
                            self.isLoading = false
                        }
                    }
                }
            }
            return
        }
        
        // 先查缓存
        if let cached = ImageCacheManager.shared.image(for: coverURL) {
            self.loadedImage = cached
            return
        }
        guard !isLoading else { return }
        isLoading = true
        // 背景线程下载
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = try? Data(contentsOf: coverURL),
               let rawImage = UIImage(data: data) {
                // 降采样到实际显示尺寸 [2†L11-L13]
                let targetSize = CGSize(width: 120, height: 120)
                let downsampled = rawImage.preparingThumbnail(of: targetSize)
                // 缓存降采样后的图片
                ImageCacheManager.shared.setImage(downsampled ?? rawImage, for: coverURL)
                DispatchQueue.main.async {
                    self.loadedImage = downsampled ?? rawImage
                    self.isLoading = false
                }
            } else {
                DispatchQueue.main.async { self.isLoading = false }
            }
        }
    }
}


// MARK: - 自定义 FlowLayout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        
        for size in sizes {
            if lineWidth + size.width + spacing > (proposal.width ?? .infinity) {
                width = max(width, lineWidth)
                height += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
        }
        width = max(width, lineWidth)
        height += lineHeight
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var point = bounds.origin
        var lineHeight: CGFloat = 0
        
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            if point.x + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Whisper 对齐辅助函数（临时复制，避免改动 LyricsService）
extension AIGenerateSongView {
    private func countSyllables(in text: String, language: String) -> Int {
        if language == "English" {
            let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines)
            return words.reduce(0) { count, word in
                let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                guard !trimmed.isEmpty else { return count }
                var syllableCount = 0
                var lastWasVowel = false
                for char in trimmed {
                    let isVowel = "aeiouy".contains(char)
                    if isVowel && !lastWasVowel {
                        syllableCount += 1
                    }
                    lastWasVowel = isVowel
                }
                // 处理末尾不发音的 e
                if trimmed.hasSuffix("e") && syllableCount > 1 {
                    syllableCount -= 1
                }
                return count + max(1, syllableCount)
            }
        } else {
            return text.count
        }
    }
    private func alignWhisperWordsToLines(words: [WordLyrics], lyricLines: [String]) -> [[WordLyrics]] {
        let singleCharWords = splitWhisperWordsToCharacters(words)
        var result: [[WordLyrics]] = []
        var wordIndex = 0
        let totalWords = singleCharWords.count
        
        for line in lyricLines {
            let targetChars = line.map { String($0) }
            var lineWords: [WordLyrics] = []
            for targetChar in targetChars {
                if isPunctuation(targetChar) {
                    lineWords.append(WordLyrics(word: targetChar, startTime: 0, endTime: 0))
                    continue
                }
                // ✅ 新增空格处理
                if targetChar == " " {
                    lineWords.append(WordLyrics(word: " ", startTime: 0, endTime: 0))
                    continue
                }
                if wordIndex < totalWords {
                    let whisperWord = singleCharWords[wordIndex]
                    if whisperWord.word == targetChar {
                        lineWords.append(whisperWord)
                        wordIndex += 1
                    } else {
                        // 偏差处理：尝试匹配相似字符（如英文大小写、中英文标点）
                        // 简单策略：直接使用 whisper 的时间戳但替换文本
                        let corrected = WordLyrics(word: targetChar,
                                                   startTime: whisperWord.startTime,
                                                   endTime: whisperWord.endTime)
                        lineWords.append(corrected)
                        wordIndex += 1
                    }
                } else {
                    // Whisper 词不够时，使用最后一个有效词的结束时间 + 微小偏移
                    let lastTime = lineWords.last?.endTime ?? 0
                    let placeholder = WordLyrics(word: targetChar,
                                                 startTime: lastTime,
                                                 endTime: lastTime + 0.1)
                    lineWords.append(placeholder)
                }
            }
            result.append(lineWords)
        }
        return result
    }
    
    private func splitWhisperWordsToCharacters(_ words: [WordLyrics]) -> [WordLyrics] {
        var result: [WordLyrics] = []
        for word in words {
            let chars = Array(word.word)
            if chars.count == 1 {
                result.append(word)
                continue
            }
            let duration = word.endTime - word.startTime
            let perCharDuration = duration / Double(chars.count)
            for (offset, char) in chars.enumerated() {
                let start = word.startTime + Double(offset) * perCharDuration
                let end = start + perCharDuration
                result.append(WordLyrics(word: String(char), startTime: start, endTime: end))
            }
        }
        return result
    }
    
    private func isPunctuation(_ char: String) -> Bool {
        let punctuationSet = CharacterSet.punctuationCharacters
        return char.unicodeScalars.allSatisfy { punctuationSet.contains($0) }
    }
    private func extractPureLyrics(from lrc: String) async -> [String] {
        let lines = lrc.components(separatedBy: .newlines)
        var result: [String] = []
        let regex = try? NSRegularExpression(pattern: "\\[.*?\\]")
        for line in lines {
            let range = NSRange(location: 0, length: line.utf16.count)
            let cleaned = regex?.stringByReplacingMatches(in: line, range: range, withTemplate: "") ?? line
            let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }
}
