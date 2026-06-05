import SwiftUI
import Combine   // ✅ 新增


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
    @State private var lyricsMaxTokens: Int = 6000
    
    @State private var musicTemperature: Double = 0.9
    @State private var songDuration: Double = 240
    @State private var useReferenceAudio = false
    @State private var selectedReferenceAudioURL: URL?
    @State private var isShowingFilePicker = false
    @State private var generateTask: Task<Void, Never>?
    @State private var translatedLyricsText: String? = nil
    
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
                                    if lyricsMaxTokens > 1000 {
                                        lyricsMaxTokens -= 200
                                    }
                                }) {
                                    Image(systemName: "minus.circle")
                                        .font(.title2)
                                        .foregroundColor(lyricsMaxTokens > 1000 ? .blue : .gray)
                                }
                                .disabled(lyricsMaxTokens <= 1000)
                                
                                Text("\(lyricsMaxTokens)")
                                    .font(.subheadline)
                                    .frame(minWidth: 50)
                                
                                Button(action: {
                                    if lyricsMaxTokens < 12000 {
                                        lyricsMaxTokens += 200
                                    }
                                }) {
                                    Image(systemName: "plus.circle")
                                        .font(.title2)
                                        .foregroundColor(lyricsMaxTokens < 12000 ? .blue : .gray)
                                }
                                .disabled(lyricsMaxTokens >= 12000)   // ✅ 修复上限逻辑
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
                            Slider(value: $songDuration, in: 60...300, step: 10)
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
        .onAppear {
            playbackService.setPlayerUIMode(.hidden)
            
            // 清理临时文件和缓存
            URLCache.shared.removeAllCachedResponses()
            let tempDir = FileManager.default.temporaryDirectory
            if let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            
            Task {
                await referenceService.loadArtists()
                await MainActor.run {
                    loadedArtists = referenceService.artists
                }
            }
            
            // ✅ 强化：进入页面时强制刷新用户信息，确保剩余次数最新
            Task {
                do {
                    try await userService.refreshUserInfo()
                    await MainActor.run {
                        // 可选：打印日志确认刷新成功
                        if let remaining = userService.currentUser?.aiSongRemaining {
                            debugLog("✅ 刷新用户信息成功，剩余次数: \(remaining)")
                        }
                    }
                } catch {
                    debugLog("⚠️ 刷新用户信息失败: \(error)")
                }
            }
            
            // 🔥 清理缓存
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
                print("✅ 封面选项生成成功，原始返回: \(options)")
                for (idx, urlString) in options.enumerated() {
                    print("   📸 封面[\(idx)]: \(urlString)")
                    if let url = URL(string: urlString) {
                        print("       - scheme: \(url.scheme ?? "nil"), host: \(url.host ?? "nil")")
                    } else {
                        print("       ❌ 无效 URL，无法解析")
                    }
                }
                
                await MainActor.run {
                    var urls = options.compactMap { URL(string: $0) }
                    urls = Array(Set(urls))
                    print("📦 去重后有效封面数量: \(urls.count)")
                    
                    
                    if urls.isEmpty {
                        if let original = song.coverURL {
                            coverOptions = [original]
                            selectedCoverURL = original
                            print("⚠️ 封面生成返回空列表，使用原版封面: \(original)")
                        } else {
                            coverOptions = []
                            selectedCoverURL = nil
                            print("❌ 封面生成失败且无原版封面")
                        }
                    } else {
                        coverOptions = urls
                        selectedCoverURL = urls.first
                        print("🎨 封面候选: \(urls)")
                        
                    }
                    isLoadingCovers = false
                }
            } catch {
                print("❌ 生成封面选项失败: \(error)")
                await MainActor.run {
                    if let original = song.coverURL {
                        coverOptions = [original]
                        selectedCoverURL = original
                        print("⚠️ 降级使用原版封面: \(original)")
                        
                    } else {
                        coverOptions = []
                        selectedCoverURL = nil
                    }
                    isLoadingCovers = false
                }
            }
        }
    }
    
    // MARK: - 生成初始歌词和风格（合并歌手共性 + 歌曲差异）
    private func generateInitialLyricsAndStyle(for song: ReferenceSong) {
        guard let token = userService.currentToken else {
            lyricsText = "请先登录"
            isGeneratingLyrics = false
            return
        }
        guard let selectedArtist = selectedArtist else { return }
        
        // 1. 歌手共性风格（精简后的）
        let baseStyle = referenceService.stylePrompt(for: selectedArtist)
        
        // 2. 歌曲特有音乐风格（编曲、乐器、节奏等）
        var songSpecificStyle = ""
        if let musicStyle = song.musicStyle, !musicStyle.isEmpty {
            songSpecificStyle = " 参考歌曲《\(song.title)》的编曲风格：\(musicStyle)。"
        }
        
        // 3. 歌曲主题（可选的额外引导）
        let themeGuidance = song.theme.isEmpty ? "" : " 歌曲主题意象：\(song.theme)。"
        
        // 4. 最终合并的风格提示（只在未手动编辑时自动填充）
        let fullStyle = baseStyle + songSpecificStyle + themeGuidance
        
        if !stylePromptHasBeenEdited {
            self.stylePrompt = fullStyle
        }
        
        // 以下歌词生成逻辑保持不变
        let shortStyle = selectedArtist.shortStyleReference ?? ""
        let themeGuide = selectedArtist.themeGuidance ?? ""
        
        syllableWarning = nil
        isGeneratingLyrics = true
        lyricsText = ""
        
        let referenceDuration = song.duration > 0 ? song.duration : 210
        // 如果用户没有手动调整过时长（刚进入页面），则使用参考时长
        if !stylePromptHasBeenEdited {
            let initialDuration = min(max(referenceDuration, 60), 300)
            self.songDuration = initialDuration
        }
        let expectedLines = Int(referenceDuration / 3.5)
        let minLines = max(expectedLines - 10, 30)
        
        let referenceLyrics = song.lyrics ?? ""
        let imageryHint = song.imageryHint ?? ""
        let referenceArtistName = selectedArtist.name
        let referenceSongTitle = song.title
        let theme = song.theme
        let language = selectedArtist.language ?? "国语"
        
        Task {
            do {
                guard let token = userService.currentToken else {
                    throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "请先登录"])
                }
                
                // 意象指导
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
                
                // 输出语言指令
                var outputInstruction: String
                var singingLanguageInstruction: String = ""
                
                switch language {
                case "English":
                    outputInstruction = """
                    **【歌词输出要求】**
                    - 只输出纯英文歌词，不要包含任何中文翻译或注释。
                    - 第一行必须是歌名。
                    """
                    singingLanguageInstruction = " Sing in English with clear pronunciation, natural flow, and western pop style."
                case "粤语":
                    outputInstruction = """
                    **【歌词输出要求】**
                    - 请输出**简体中文**歌词（不要输出粤语口语文字，用标准中文表达意思）。
                    - 第一行必须是歌名（简体中文）。
                    """
                    singingLanguageInstruction = " 演唱语言：粤语，必须使用地道粤语发音和词汇，旋律风格参考经典粤语金曲。"
                default:
                    outputInstruction = """
                    **【歌词输出要求】**
                    - 只输出简体中文歌词。
                    - 第一行必须是歌名。
                    """
                    singingLanguageInstruction = " 演唱语言：国语，发音标准，旋律流畅。"
                }
                
                
                var prompt = """
                ⚠️ **【硬性要求】你必须生成一首完整的流行歌曲，总行数（不含结构标记）不得少于 40 行，否则必须重新生成。** ⚠️
                包含以下所有部分，每个部分的行数必须严格按要求：
                
                [前奏] (4-8 小节，纯音乐，不写具体歌词)
                [主歌 A] (4 行)
                [主歌 B] (4 行)
                [副歌] (4 行)
                [间奏] (4 小节，纯音乐)
                [主歌 C] (4 行)
                [副歌] (重复，4 行)
                [桥段] (4 行)
                [副歌] (重复，4 行)
                [尾奏] (4 小节，纯音乐)
                
                参考歌曲《\(referenceSongTitle)》的行数约为 \(Int(referenceDuration / 3.5)) 行，请生成相近数量。**少于 40 行的输出将被直接拒绝并重试。**
                
                **歌名要求**：
                - 简洁、有画面感或哲理感，由 2-7 个实词组成。
                - 禁止使用虚词：“的、了、吗、吧、啊、啦、哦、嗯、呢”。
                - 歌名要能精准概括整首歌的核心意象或故事。
                
                **歌词要求**：
                - 必须紧紧围绕歌名展开，每一句都呼应主题。
                - 尽量避免使用虚词、口水词、网络用语、大白话。
                - 尽量避免陈词滥调（如“月光”、“泪水”、“誓言”、“永远”），但不要因噎废食，优先保证长度和完整性。
                - 每一句用具体的生活细节、动作、环境、物件表达情感。
                - 句子宜短不宜长，精炼有力。不必每句押韵，但副歌最好有统一韵脚。
                - 整首歌词要有起承转合，副歌必须有一句高度记忆点的金句。
                
                **风格参考（只学方法，不抄内容）：**
                - 参考歌曲的主题：\(theme)
                - 额外主题引导：\(themeGuide.isEmpty ? "无" : themeGuide)
                - 核心风格关键词：\(shortStyle.isEmpty ? baseStyle : shortStyle)
                
                **意象与语言指导：**
                \(imageryGuidance)
                
                **输出格式**：
                - 每段前标注：[主歌A]、[主歌B]、[副歌]、[桥段] 等（标记单独一行，不计入行数）。
                - 段落之间用一个空行分隔。
                - 只输出纯歌词文本，不要输出任何解释、备注、括号、标记。
                \(outputInstruction)
                """
                
                if language == "English" {
                    prompt += """
                        
                        **English Lyric Requirements (prioritize length)**:
                        - Ensure the total number of lines is at least 40.
                        - Each line should have roughly 8-12 syllables, small deviations are acceptable.
                        - Hook line should be memorable.
                        """
                }
                
                let (title, cleaned) = try await generateWithRetry(
                    prompt: prompt,
                    temperature: lyricsTemperature,
                    maxTokens: lyricsMaxTokens,
                    language: language
                )
                
                var originalLyrics = cleaned
                var translatedLyrics: String? = nil
                
                if language == "English" {
                    originalLyrics = cleaned
                    do {
                        translatedLyrics = try await translateLyricsToChinese(originalLyrics)
                        print("✅ 翻译完成，行数: \(translatedLyrics?.components(separatedBy: .newlines).count ?? 0)")
                    } catch {
                        print("❌ 翻译失败: \(error)")
                        translatedLyrics = nil
                    }
                } else {
                    originalLyrics = cleaned
                }
                
                await MainActor.run {
                    lyricsText = originalLyrics
                    generatedTitle = title.isEmpty ? song.title : title
                    self.translatedLyricsText = translatedLyrics
                    
                    let suggestedDuration = self.estimateSongDuration(from: originalLyrics)
                    let clampedDuration = min(max(suggestedDuration, 60), 240)
                    self.songDuration = clampedDuration
                    
                    if abs(clampedDuration - 180) > 20 {
                        self.syllableWarning = "已根据歌词长度自动调整目标时长为 \(Int(clampedDuration)) 秒"
                    }
                    
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
        // 确保每次请求都有足够的 token 空间产出完整歌词（基础值 15000，重试时可能更高）
        let effectiveTokens = max(maxTokens, 15000)
        // 重试时提高温度增加多样性（最高 1.2）
        let effectiveTemperature = attempt > 0 ? min(temperature * 1.2, 1.2) : temperature
        let (title, rawLyrics) = try await DeepSeekService.shared.generateLyrics(
            prompt: prompt,
            temperature: effectiveTemperature,
            maxTokens: effectiveTokens
        )
        
        let cleaned = await Task.detached(priority: .userInitiated) {
            return autoreleasepool { self.cleanLyrics(rawLyrics) }
        }.value
        
        // 1. 基本保护：完全为空则重试
        guard !cleaned.isEmpty else {
            if attempt < 4 {
                return try await generateWithRetry(prompt: prompt, temperature: effectiveTemperature,
                                                   maxTokens: 20000, language: language, attempt: attempt + 1)
            }
            throw NSError(domain: "LyricsError", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "生成的歌词为空"])
        }
        
        // 2. 行数检查：完整流行歌曲通常需要 30-60 行，设下限为 30 行
        let lines = cleaned.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count < 30 {
            if attempt < 4 {
                print("⚠️ 歌词行数不足 (\(lines.count) 行，期望 ≥30 行完整歌曲)，自动重试 (第 \(attempt+2) 次)")
                // 追加强制指令，并大幅提高 token 和温度
                let retryPrompt = prompt + "\n\n⚠️ 上一次生成的歌词只有 \(lines.count) 行，严重不足！你必须输出完整的流行歌曲结构，总行数至少 40 行！如果再次少于 40 行，你的输出将被视为无效。⚠️"
                return try await generateWithRetry(prompt: retryPrompt,
                                                   temperature: min(temperature * 1.3, 1.2), // 温度最高 1.2
                                                   maxTokens: 20000,   // 增加 token 到 20000
                                                   language: language,
                                                   attempt: attempt + 1)
            }
            print("⚠️ 警告：歌词仅 \(lines.count) 行，歌曲可能不完整")
        }
        
        // 3. 时长匹配检查（若偏差超过30秒且未达重试上限）
        let estimatedDuration = Double(lines.count) * 4.0  // 每行约4秒
        let targetDuration = self.songDuration
        if abs(estimatedDuration - targetDuration) > 30 && attempt < 4 {
            print("⚠️ 歌词时长与目标时长不匹配 (估计\(Int(estimatedDuration))秒 vs 目标\(Int(targetDuration))秒)，调整 token 重试")
            let adjustedMaxTokens = Int(Double(effectiveTokens) * targetDuration / estimatedDuration)
            // 重试时也使用最高 token 上限 20000
            let finalMaxTokens = max(adjustedMaxTokens, 20000)
            return try await generateWithRetry(prompt: prompt, temperature: effectiveTemperature,
                                               maxTokens: finalMaxTokens, language: language, attempt: attempt + 1)
        }
        
        // 4. 音节均匀度检查
        if language == "English" {
            let syllableCounts = lines.map { self.countSyllables(in: $0, language: language) }
            let avg = syllableCounts.reduce(0, +) / max(1, syllableCounts.count)
            let variance = syllableCounts.reduce(0.0) { $0 + pow(Double($1) - Double(avg), 2) } / Double(syllableCounts.count)
            let stdDev = sqrt(variance)
            let avgOk = (6...14).contains(avg)
            let stdOk = stdDev <= 4.0
            if !(avgOk && stdOk) {
                if attempt < 4 {
                    print("⚠️ 英文音节不均匀 (avg=\(avg), std=\(String(format: "%.1f", stdDev)))，重试")
                    return try await generateWithRetry(prompt: prompt,
                                                       temperature: effectiveTemperature,
                                                       maxTokens: 20000,
                                                       language: language,
                                                       attempt: attempt + 1)
                }
                print("⚠️ 音节仍不均匀，但内容有效，直接采用")
            }
        } else {
            // 中文/粤语：字数检查 7~16 字，标准差 ≤4.5（放宽）
            let charCounts = lines.map { $0.count }
            let avg = charCounts.reduce(0, +) / max(1, charCounts.count)
            let variance = charCounts.reduce(0.0) { $0 + pow(Double($1) - Double(avg), 2) } / Double(charCounts.count)
            let stdDev = sqrt(variance)
            if !((7...16).contains(avg) && stdDev <= 4.5) {
                if attempt < 4 {
                    print("⚠️ 歌词字数不均匀 (avg=\(avg), std=\(String(format: "%.1f", stdDev)))，重试")
                    return try await generateWithRetry(prompt: prompt, temperature: effectiveTemperature,
                                                       maxTokens: 20000, language: language, attempt: attempt + 1)
                }
                print("⚠️ 歌词字数仍不均匀，但内容有效，直接采用")
            }
        }
        
        return (title, cleaned)
    }
    
    
    // MARK: - 带自动重试的歌词生成（含音节均匀性检测）
    //    private func generateWithRetry(
    //        prompt: String,
    //        temperature: Double,
    //        maxTokens: Int,
    //        language: String,
    //        attempt: Int = 0
    //    ) async throws -> (String, String) {
    //        // 确保每次请求都有足够的 token 空间产出完整歌词（最少 4000）
    //        let effectiveTokens = max(maxTokens, 15000)  // 从 6000 改为 10000
    //        // 重试时提高温度增加多样性（而不是降低）
    //        let effectiveTemperature = attempt > 0 ? min(temperature * 1.2, 1.2) : temperature
    //        let (title, rawLyrics) = try await DeepSeekService.shared.generateLyrics(
    //            prompt: prompt,
    //            temperature: effectiveTemperature,
    //            maxTokens: effectiveTokens
    //        )
    //
    //        let cleaned = await Task.detached(priority: .userInitiated) {
    //            return autoreleasepool { self.cleanLyrics(rawLyrics) }
    //        }.value
    //
    //        // 1. 基本保护：完全为空则重试
    //        guard !cleaned.isEmpty else {
    //            if attempt < 4 {
    //                return try await generateWithRetry(prompt: prompt, temperature: effectiveTemperature,
    //                                                   maxTokens: 15000, language: language, attempt: attempt + 1)
    //            }
    //            throw NSError(domain: "LyricsError", code: -1,
    //                          userInfo: [NSLocalizedDescriptionKey: "生成的歌词为空"])
    //        }
    //
    //        // 2. 行数检查：一首完整的歌词至少应有 12 行（主歌×2+副歌+桥段）
    //        let lines = cleaned.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    //        // 2. 行数检查：完整流行歌曲通常需要 30-60 行，设下限为 30 行
    //        if lines.count < 30 {
    //            if attempt < 4 {  // 增加重试次数到 4 次
    //                print("⚠️ 歌词行数不足 (\(lines.count) 行，期望 ≥30 行完整歌曲)，自动重试 (第 \(attempt+2) 次)")
    //                // 追加强制指令，并提高 token 和温度
    //                let retryPrompt = prompt + "\n\n⚠️ 上一次生成的歌词只有 \(lines.count) 行，严重不足！你必须输出完整的流行歌曲结构，总行数至少 40 行！如果再次少于 40 行，你的输出将被视为无效。⚠️"
    //                return try await generateWithRetry(prompt: retryPrompt,
    //                                                   temperature: min(temperature * 1.3, 1.2), // 提高温度到 1.2
    //                                                   maxTokens: 15000,   // 增加 token 到 15000
    //                                                   language: language,
    //                                                   attempt: attempt + 1)
    //            }
    //            print("⚠️ 警告：歌词仅 \(lines.count) 行，歌曲可能不完整")
    //        }
    //
    //
    //        // 在行数检查之后添加
    //        let estimatedDuration = Double(lines.count) * 4.0  // 每行约4秒
    //        let targetDuration = self.songDuration
    //        if abs(estimatedDuration - targetDuration) > 30 && attempt < 4 {
    //            print("⚠️ 歌词时长与目标时长不匹配 (估计\(Int(estimatedDuration))秒 vs 目标\(Int(targetDuration))秒)，调整 token 重试")
    //            let adjustedMaxTokens = Int(Double(effectiveTokens) * targetDuration / estimatedDuration)
    //            return try await generateWithRetry(prompt: prompt, temperature: effectiveTemperature,
    //                                               maxTokens: adjustedMaxTokens, language: language, attempt: attempt + 1)
    //        }
    //
    //
    //        // 3. 音节均匀度检查（仅英文，中文按字数计）
    //        if language == "English" {
    //            let syllableCounts = lines.map { self.countSyllables(in: $0, language: language) }
    //            let avg = syllableCounts.reduce(0, +) / max(1, syllableCounts.count)
    //            let variance = syllableCounts.reduce(0.0) { $0 + pow(Double($1) - Double(avg), 2) } / Double(syllableCounts.count)
    //            let stdDev = sqrt(variance)
    //
    //            // 条件适当放宽
    //            let avgOk = (6...14).contains(avg)
    //            let stdOk = stdDev <= 4.0
    //            if !(avgOk && stdOk) {
    //                if attempt < 4 {
    //                    print("⚠️ 英文音节不均匀 (avg=\(avg), std=\(String(format: "%.1f", stdDev)))，重试")
    //                    return try await generateWithRetry(prompt: prompt,
    //                                                       temperature: effectiveTemperature,
    //                                                       maxTokens: 15000,
    //                                                       language: language,
    //                                                       attempt: attempt + 1)
    //                }
    //                print("⚠️ 音节仍不均匀，但内容有效，直接采用")
    //            }
    //        } else {
    //            // 中文/粤语：字数检查 7~16 字，标准差 ≤4.5（放宽）
    //            let charCounts = lines.map { $0.count }
    //            let avg = charCounts.reduce(0, +) / max(1, charCounts.count)
    //            let variance = charCounts.reduce(0.0) { $0 + pow(Double($1) - Double(avg), 2) } / Double(charCounts.count)
    //            let stdDev = sqrt(variance)
    //            if !((7...16).contains(avg) && stdDev <= 4.5){
    //                if attempt < 4 {
    //                    print("⚠️ 歌词字数不均匀 (avg=\(avg), std=\(String(format: "%.1f", stdDev)))，重试")
    //                    return try await generateWithRetry(prompt: prompt, temperature: effectiveTemperature,
    //                                                       maxTokens: 15000, language: language, attempt: attempt + 1)
    //                }
    //                print("⚠️ 歌词字数仍不均匀，但内容有效，直接采用")
    //            }
    //        }
    //
    //        return (title, cleaned)
    //    }
    
    // MARK: - 翻译英文歌词为中文（逐行对齐）
    private func translateLyricsToChinese(_ englishLyrics: String) async throws -> String {
        let prompt = """
        请将以下英文歌词逐行翻译成中文，要求：
        1. **必须保持每行一一对应，行数完全一致（原文 \(englishLyrics.components(separatedBy: .newlines).count) 行）**。
        2. 只输出中文译文，每行一句，不要添加任何额外内容。
        3. 不要翻译歌名，从第一行歌词开始。
        4. 如果某行英文没有对应的中文翻译，请输出空行保持行数对齐。
        
        英文歌词：
        \(englishLyrics)
        """
        let (_, translated) = try await DeepSeekService.shared.generateLyrics(
            prompt: prompt,
            temperature: 0.3,
            maxTokens: 8000  // 增加到 8000
        )
        return translated.trimmingCharacters(in: .whitespacesAndNewlines)
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
                
                let referenceSongTitle = selectedSong?.title ?? ""
                let referenceSongDuration = selectedSong?.duration ?? 210
                let songMusicStyle = selectedSong?.musicStyle   // ✅ 获取歌曲编曲风格
                
                
                let (title, improved) = try await virtualArtistService.improveLyrics(
                    currentLyrics: lyricsText,
                    task: "optimize",
                    theme: songTheme,
                    referenceArtist: selectedArtist?.name,
                    referenceSongTitle: referenceSongTitle,           // ✅ 新增
                    referenceSongDuration: referenceSongDuration,     // ✅ 新增
                    optimizationGoals: finalGoals,
                    token: token,
                    temperature: lyricsTemperature,
                    maxTokens: lyricsMaxTokens,
                    referenceLyrics: referenceLyrics,
                    referenceImageryHint: referenceImageryHint,
                    songMusicStyle: songMusicStyle   // ✅ 传递
                )
                
                let cleaned = await Task.detached(priority: .userInitiated) {
                    return autoreleasepool { () -> String in
                        return cleanLyrics(improved)
                    }
                }.value
                
                // ✅ 新增：如果是英文，单独翻译
                var translated: String? = nil
                if referenceArtistLanguage == "English" {
                    do {
                        translated = try await translateLyricsToChinese(cleaned)
                        print("✅ 优化后翻译完成，行数: \(translated?.components(separatedBy: .newlines).count ?? 0)")
                    } catch {
                        print("❌ 优化后翻译失败: \(error)")
                        translated = nil
                    }
                }
                
                await MainActor.run {
                    lyricsText = cleaned
                    generatedTitle = title
                    self.translatedLyricsText = translated   // 更新翻译
                    
                    
                    // 音节警告处理（保持不变）
                    let lines = cleaned.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    let counts = lines.map { self.countSyllables(in: $0, language: referenceArtistLanguage) }
                    let avg = counts.reduce(0, +) / max(1, counts.count)
                    let isEnglish = referenceArtistLanguage == "English"
                    let validRange = isEnglish ? (8...12) : (7...12)
                    
                    if validRange.contains(avg) {
                        syllableWarning = nil
                    } else {
                        if isEnglish {
                            syllableWarning = "⚠️ 英文歌词每行音节数应在 8~10 之间（当前平均 \(avg)），建议点击“优化歌词”重新生成"
                        } else {
                            syllableWarning = "⚠️ 歌词每行字数建议 7~10 字（当前平均 \(avg)），可再次优化"
                        }
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
    
    // MARK: - 中文翻译逐字高亮映射
    private func mapEnglishTimestampsToChinese(englishWords: [WordLyrics], englishText: String, chineseText: String) -> [WordLyrics]? {
        // 提取英文句子中的非空格字符
        let enChars = Array(englishText.filter { !$0.isWhitespace })
        let zhChars = Array(chineseText)
        guard !enChars.isEmpty, !zhChars.isEmpty else { return nil }
        
        guard let firstWord = englishWords.first, let lastWord = englishWords.last else { return nil }
        let startTime = firstWord.startTime
        let endTime = lastWord.endTime
        let totalDuration = endTime - startTime
        
        let perZhDuration = totalDuration / Double(zhChars.count)
        var result: [WordLyrics] = []
        for (index, char) in zhChars.enumerated() {
            let start = startTime + Double(index) * perZhDuration
            let end = start + perZhDuration
            result.append(WordLyrics(word: String(char), startTime: start, endTime: end))
        }
        return result
    }
    
    private func generateTranslatedWordLyrics(originalWordLyrics: [[WordLyrics]], originalLines: [String], translatedLines: [String]) -> [[WordLyrics]]? {
        guard originalLines.count == translatedLines.count else { return nil }
        var result: [[WordLyrics]] = []
        for i in 0..<originalLines.count {
            let enLine = originalLines[i]
            let zhLine = translatedLines[i]
            let enWordsForLine = originalWordLyrics[i]
            guard let mapped = mapEnglishTimestampsToChinese(englishWords: enWordsForLine, englishText: enLine, chineseText: zhLine) else {
                return nil
            }
            result.append(mapped)
        }
        return result
    }
    
    // MARK: - 提交生成（使用 AITaskManager 解耦 UI，立即关闭页面）
    private func generateSong() {
        // 先取消之前的生成任务
        generateTask?.cancel()
        generateTask = nil
        virtualArtistService.generationProgress = ""
        
        guard let song = selectedSong, let coverURL = selectedCoverURL,
              let token = userService.currentToken else {
            errorMessage = "请完成所有选择"
            showError = true
            return
        }
        
        // 保留原始带标记的歌词（包含 [主歌A]、[副歌] 等）
        let rawLyricsWithMarkers = lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLyricsWithMarkers.isEmpty else {
            errorMessage = "请输入歌词"
            showError = true
            return
        }
        
        // 如果需要纯文本用于其他用途（如查重），可单独创建
        let plainLyrics = rawLyricsWithMarkers
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("[") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        
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
        
        // 生成前清理缓存
        URLCache.shared.removeAllCachedResponses()
        let tempDir = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("creation_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        
        isGenerating = true
        
        generateTask = Task {
            do {
                // ✅ 1. 先刷新用户信息，确保剩余次数是最新的
                try await userService.refreshUserInfo()
                
                // 2. 获取最新剩余次数并校验
                guard let currentUser = userService.currentUser else {
                    throw NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户信息获取失败"])
                }
                guard currentUser.aiSongRemaining > 0 else {
                    throw NSError(domain: "PaymentRequired", code: 402, userInfo: [NSLocalizedDescriptionKey: "免费次数已用完，请付费解锁更多生成次数"])
                }
                
                let finalDuration = estimateSongDuration(from: rawLyricsWithMarkers)
                let clampedDuration = min(max(finalDuration, 60), 240)
                if abs(clampedDuration - self.songDuration) > 15 {
                    print("🎵 自动调整目标时长: \(Int(self.songDuration)) -> \(Int(clampedDuration))")
                    self.songDuration = clampedDuration
                }
                
                // 增强风格提示，告知 Mureka 歌曲结构
                var enhancedStylePrompt = stylePrompt
                enhancedStylePrompt += """
                
                【重要】歌曲结构要求（请严格遵守）：
                - 前奏 8 秒（纯音乐）
                - 主歌 A 4 行，主歌 B 4 行（每行约 3.5 秒）
                - 副歌 4 行（每行约 4.5 秒），重复 2 次
                - 桥段 4 行（每行约 4 秒）
                - 尾奏 6 秒
                请确保每部分时长与歌词行数匹配。
                """
                print("🔍 [AIGenerateSong] 参考歌手: \(selectedArtist?.name ?? "nil"), 语言: \(selectedArtist?.language ?? "nil")")
                // ✅ 3. 使用 AITaskManager 提交任务（不等待完成，立即返回）
                try await AITaskManager.shared.submitTask(
                    originalSong: song,
                    selectedCoverURL: coverURL,
                    creativity: musicTemperature,
                    duration: songDuration,
                    artist: artist,
                    customLyrics: rawLyricsWithMarkers,
                    customStylePrompt: enhancedStylePrompt,
                    customTitle: generatedTitle,
                    lyricsTemperature: lyricsTemperature,
                    lyricsMaxTokens: lyricsMaxTokens,
                    referenceAudioURL: useReferenceAudio ? selectedReferenceAudioURL : nil,
                    translatedLyrics: translatedLyricsText,
                    voiceModelIdOverride: selectedArtist?.voiceModelId,
                    referenceArtistLanguage: selectedArtist?.language,
                    gender: selectedArtist?.gender   // ✅ 新增
                )
                
                // ✅ 4. 立即关闭当前 AI 再创作页面
                await MainActor.run {
                    isGenerating = false
                    dismiss()
                    // 可选：发送本地通知或显示 Toast，告知用户任务已提交
                    // 这里简单打印日志
                    print("🎵 AI 生成任务已提交，taskId 已存入后台管理器")
                }
                
            } catch {
                // ✅ 增强错误处理：如果是 402 错误，强制刷新用户信息并弹窗提示
                await MainActor.run {
                    isGenerating = false
                    if let nsError = error as? NSError, nsError.code == 402 {
                        // 刷新用户信息以更新显示
                        Task {
                            do {
                                try await userService.refreshUserInfo()
                                await MainActor.run {
                                    errorMessage = "免费次数已用完，请付费解锁更多生成次数"
                                    showError = true
                                }
                            } catch {
                                errorMessage = "获取用户信息失败，请稍后重试"
                                showError = true
                            }
                        }
                    } else if error is CancellationError {
                        print("⏹️ 生成任务被取消")
                    } else {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }
        
    
    @MainActor
    private func waitForLyricsReady(songId: String) async {
        // 如果已经加载完成，直接返回
        if lyricsService.currentSongId == songId && !lyricsService.wordLyrics.isEmpty {
            return
        }
        // 使用 Combine 订阅等待，超时30秒
        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = lyricsService.$wordLyrics
                .sink { wordLyrics in
                    if lyricsService.currentSongId == songId && !wordLyrics.isEmpty {
                        cancellable?.cancel()
                        continuation.resume()
                    }
                }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                cancellable?.cancel()
                continuation.resume()
            }
        }
    }
    /// 根据带结构标记的歌词估算歌曲总时长（秒）
    private func estimateSongDuration(from lyricsWithMarkers: String) -> TimeInterval {
        let lines = lyricsWithMarkers.components(separatedBy: .newlines)
        var totalSeconds = 0.0
        var currentSection: String = "verse"
        var chorusCount = 0
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                // 识别结构标记
                if trimmed.contains("副歌") || trimmed.contains("Chorus") {
                    currentSection = "chorus"
                    chorusCount += 1
                } else if trimmed.contains("桥段") || trimmed.contains("Bridge") {
                    currentSection = "bridge"
                } else if trimmed.contains("主歌") || trimmed.contains("Verse") {
                    currentSection = "verse"
                } else if trimmed.contains("前奏") || trimmed.contains("Intro") {
                    totalSeconds += 8.0  // 前奏 8 秒
                    currentSection = "verse"
                } else if trimmed.contains("尾奏") || trimmed.contains("Outro") {
                    totalSeconds += 6.0  // 尾奏 6 秒
                } else if trimmed.contains("间奏") || trimmed.contains("Interlude") {
                    totalSeconds += 4.0  // 间奏 4 秒
                }
                continue
            }
            // 根据段落类型决定每行演唱时长
            let lineDuration: Double
            switch currentSection {
            case "chorus":
                lineDuration = 4.5   // 副歌稍慢
            case "bridge":
                lineDuration = 4.0   // 桥段
            default:
                lineDuration = 3.5   // 主歌
            }
            totalSeconds += lineDuration
        }
        
        // 如果副歌重复次数 >= 2，额外加 4 秒（因为副歌通常重复两次）
        if chorusCount >= 2 {
            totalSeconds += 4.0
        }
        
        // 确保在合理范围内
        return min(max(totalSeconds, 60), 240)
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
    
    private func convertMurekaSectionsToLyricLines(_ sections: [MurekaLyricsSection]) -> [LyricLine] {
        var result: [LyricLine] = []
        for section in sections {
            guard let lines = section.lines else { continue }
            for line in lines {
                guard let words = line.words, !words.isEmpty else { continue }
                var wordLyricsArray: [WordLyrics] = []
                for word in words {
                    let splitWords = splitWordIntoCharacters(word)  // 需要实现
                    wordLyricsArray.append(contentsOf: splitWords)
                }
                let startTime = wordLyricsArray.first?.startTime ?? 0
                let endTime = wordLyricsArray.last?.endTime ?? startTime + 0.5
                let text = wordLyricsArray.map { $0.word }.joined()
                let lyricLine = LyricLine(startTime: startTime, endTime: endTime, text: text, words: wordLyricsArray)
                result.append(lyricLine)
            }
        }
        return result
    }
    
    private func splitWordIntoCharacters(_ word: MurekaWord) -> [WordLyrics] {
        let text = word.text
        let totalDuration = Double(word.end - word.start) / 1000.0
        var result: [WordLyrics] = []
        
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let firstChar = text[currentIndex]
            var chunkEndIndex = currentIndex
            
            // 根据首字符类型，判断这是一个什么类型的“块”（中文汉字、英文字母/数字、还是分隔符）
            if firstChar.isWhitespace {
                // 空格单独处理，不参与高亮
                let spaceWord = WordLyrics(word: " ", startTime: 0, endTime: 0.001)
                result.append(spaceWord)
                currentIndex = text.index(after: currentIndex)
                continue
            } else if firstChar.isCJK {
                // 中文汉字：单个字就是一个“块”
                chunkEndIndex = text.index(after: currentIndex)
            } else if firstChar.isEnglishOrDigit {
                // 英文或数字：找到连续字符组成一个“块”（一个完整的单词或数字）
                while chunkEndIndex < text.endIndex, text[chunkEndIndex].isEnglishOrDigit {
                    chunkEndIndex = text.index(after: chunkEndIndex)
                }
            } else {
                // 其他符号（如标点），作为一个单独的块
                chunkEndIndex = text.index(after: currentIndex)
            }
            
            let chunkString = String(text[currentIndex..<chunkEndIndex])
            let chunkLength = chunkString.count
            
            // 根据块在原文本中的位置，计算它的开始和结束时间
            let startRatio = Double(text.distance(from: text.startIndex, to: currentIndex)) / Double(text.count)
            let endRatio = Double(text.distance(from: text.startIndex, to: chunkEndIndex)) / Double(text.count)
            
            let chunkStartTime = Double(word.start) / 1000.0 + totalDuration * startRatio
            let chunkEndTime = Double(word.start) / 1000.0 + totalDuration * endRatio
            
            
            if chunkLength > 1 {
                // 均匀分配给每个字符
                let perCharDuration = (chunkEndTime - chunkStartTime) / Double(chunkLength)
                for (offset, char) in chunkString.enumerated() {
                    let start = chunkStartTime + Double(offset) * perCharDuration
                    let end = start + perCharDuration
                    result.append(WordLyrics(word: String(char), startTime: start, endTime: end))
                }
            } else {
                result.append(WordLyrics(word: chunkString, startTime: chunkStartTime, endTime: chunkEndTime))
            }
            currentIndex = chunkEndIndex
            
        }
        return result
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
                                .frame(width: 160, height: 90)
                                .clipped()
                                .cornerRadius(8)
                        } else {
                            // 占位符，保持布局稳定
                            ProgressView()
                                .frame(width: 160, height: 90)
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
            .onAppear {
                print("🖼️ CoverOptionCard 出现，URL: \(coverURL)")
                if loadedImage == nil {
                    loadAndDownsampleImage()
                }
            }
            .onDisappear {
                // 视图移出屏幕时，可以置空以释放图片内存
                loadedImage = nil
            }
        }
        
        private func loadAndDownsampleImage() {
            // 先查缓存
            if let cached = ImageCacheManager.shared.image(for: coverURL) {
                print("✅ 封面缓存命中: \(coverURL.lastPathComponent)")
                self.loadedImage = cached
                return
            }
            print("🔍 封面未命中缓存，开始加载: \(coverURL)")
            
            // 兼容 data URL (Base64)
            if coverURL.scheme == "data" {
                print("📀 检测到 data URL，尝试解析 Base64 图片")
                let dataString = coverURL.absoluteString
                guard let commaIndex = dataString.firstIndex(of: ",") else {
                    print("❌ data URL 格式错误，缺少逗号分隔符")
                    return
                }
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
                                print("✅ data URL 图片加载成功")
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.isLoading = false
                                print("❌ data URL 图片解码失败")
                            }
                        }
                    }
                }
                return
            }
            
            guard !isLoading else {
                print("⚠️ 封面已在加载中，跳过重复请求: \(coverURL)")
                return
            }
            isLoading = true
            
            // 异步下载（当前代码使用的是同步 Data(contentsOf:)，我们需要临时改为异步并加日志）
            // 注意：原代码使用 DispatchQueue.global 中的 Data(contentsOf:)，我们保持结构不变，只加日志和错误详情
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        print("🌐 开始下载封面数据: \(self.coverURL)")
                        let startTime = CFAbsoluteTimeGetCurrent()
                        let data = try Data(contentsOf: self.coverURL)
                        let duration = CFAbsoluteTimeGetCurrent() - startTime
                        print("📥 下载完成，大小: \(data.count) 字节，耗时: \(String(format: "%.2f", duration))秒")
                        
                        guard let rawImage = UIImage(data: data) else {
                            print("❌ 数据无法转换为 UIImage，URL: \(self.coverURL)")
                            DispatchQueue.main.async {
                                self.isLoading = false
                            }
                            return
                        }
                        let targetSize = CGSize(width: 120, height: 120)
                        let downsampled = rawImage.preparingThumbnail(of: targetSize)
                        ImageCacheManager.shared.setImage(downsampled ?? rawImage, for: self.coverURL)
                        DispatchQueue.main.async {
                            self.loadedImage = downsampled ?? rawImage
                            self.isLoading = false
                            print("✅ 封面加载成功并缓存: \(self.coverURL.lastPathComponent)")
                        }
                    } catch {
                        let nsError = error as NSError
                        print("❌ 封面下载失败: \(self.coverURL)")
                        print("   错误域: \(nsError.domain), 错误码: \(nsError.code)")
                        print("   描述: \(nsError.localizedDescription)")
                        if let urlError = error as? URLError {
                            print("   URLError 类型: \(urlError.code.rawValue)")
                            switch urlError.code {
                            case .secureConnectionFailed:
                                print("   👉 具体原因: SSL 连接失败 (可能证书问题)")
                            case .cannotConnectToHost:
                                print("   👉 具体原因: 无法连接到主机")
                            case .timedOut:
                                print("   👉 具体原因: 请求超时")
                            default:
                                print("   👉 其他 URLError")
                            }
                        }
                        DispatchQueue.main.async {
                            self.isLoading = false
                        }
                    }
                }
            }
        }
        
    }
    
    
    
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
