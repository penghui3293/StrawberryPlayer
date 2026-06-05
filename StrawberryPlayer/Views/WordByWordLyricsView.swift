import SwiftUI
import Combine

struct WordByWordLyricsView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    
    var onTap: (() -> Void)?
    
    @State private var currentLineWords: [WordLyrics] = []
    @State private var nextLineText: String = ""
    
    @State private var containerWidth: CGFloat = max(UIScreen.main.bounds.width - 32, 1)
    @State private var cachedLineHeight: CGFloat = 0
    @State private var cachedLineWords: [WordLyrics] = []
    
    // 判断是否为英文歌曲（通过翻译数据是否存在）
    
    private var isEnglishSong: Bool {
        let result = lyricsService.translatedLyrics != nil && !lyricsService.translatedLyrics!.isEmpty
        if result {
//            print("🎤 [WordByWord] 检测为英文歌曲，有翻译")
        }
        return result
    }
    
    var body: some View {
        let inactiveColor: Color = playbackService.accentColor == .clear
        ? Color.white.opacity(0.2)
        : playbackService.accentColor.mix(with: .white, amount: 0.2)
        
        VStack(alignment: .leading, spacing: 8) {
            if lyricsService.lyrics.isEmpty && lyricsService.isLoading {
                ProgressView()
                    .tint(playbackService.accentColor)
                    .frame(maxWidth: .infinity)
            } else if lyricsService.lyrics.isEmpty {
                Text("暂无歌词")
                    .foregroundColor(.secondary)
            } else if !currentLineWords.isEmpty {
                let height = cachedLineHeight
                
                // 当前行英文高亮
                LyricHighlightLayerView(
                    words: currentLineWords,
                    currentTime: playbackService.currentTime + lyricsService.lyricOffset,
                    activeColor: .white,
                    inactiveColor: inactiveColor,
                    fontSize: 18,
                    containerWidth: containerWidth
                )
                .frame(width: containerWidth, height: height)
                .padding(.horizontal, 16)
                .onTapGesture { onTap?() }
                
                // 英文歌曲：显示中文翻译（当前行）
                if isEnglishSong {
                    if !lyricsService.translatedWordLyrics.isEmpty,
                       lyricsService.currentLyricIndex >= 0,
                       lyricsService.currentLyricIndex < lyricsService.translatedWordLyrics.count {
                        let translatedWords = lyricsService.translatedWordLyrics[lyricsService.currentLyricIndex]
                        let translatedHeight = LyricHighlightLayer.computeHeight(words: translatedWords, fontSize: 14, containerWidth: containerWidth)
                        LyricHighlightLayerView(
                            words: translatedWords,
                            currentTime: playbackService.currentTime + lyricsService.lyricOffset,
                            activeColor: .white,
                            inactiveColor: inactiveColor,  // 与英文歌词使用相同的不活跃颜色
                            fontSize: 18,                  // ✅ 改为 18，与英文一致
                            containerWidth: containerWidth
                        )
                        .frame(width: containerWidth, height: translatedHeight)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    } else if let transLine = lyricsService.translatedLines[safe: lyricsService.currentLyricIndex] {
                        // 降级：静态翻译文本
                        Text(transLine)
                            .font(.system(size: 18))        // ✅ 改为 18
                            .foregroundColor(inactiveColor) // ✅ 与英文歌词保持一致
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }
                }
                
            } else {
                let color = playbackService.accentColor == .clear
                ? Color.white.opacity(0.6)
                : inactiveColor
                Text(playbackService.currentSong?.title ?? "")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(color)
                    .padding(.horizontal, 16)
            }
            
            // 中文歌曲：显示下一行预览；英文歌曲不显示
            if !isEnglishSong && !nextLineText.isEmpty {
                Text(nextLineText)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(inactiveColor)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateContainerWidth(geometry.size.width - 32)
                    }
                    .onChange(of: geometry.size.width) { newWidth in
                        updateContainerWidth(newWidth - 32)
                    }
            }
        )
        .onAppear {
            syncWithCurrentLine()
        }
        .onReceive(playbackService.$currentSong) {newIndex in
            let newWidth = max(UIScreen.main.bounds.width - 32, 1)
            if newWidth != containerWidth {
                containerWidth = newWidth
                if !currentLineWords.isEmpty {
                    cachedLineHeight = LyricHighlightLayer.computeHeight(words: currentLineWords, fontSize: 18, containerWidth: containerWidth)
                }
            }
            syncWithCurrentLine()
        }
        .onReceive(lyricsService.$wordLyrics) { newValue in
            print("🖥️ [WordByWord] 收到 wordLyrics 变化 | 新值行数: \(newValue.count)")
            syncWithCurrentLine()
        }
        .onReceive(lyricsService.$translatedWordLyrics) { newValue in
            print("🖥️ [WordByWord] 收到 translatedWordLyrics 变化 | 新值行数: \(newValue.count)")
            syncWithCurrentLine()
        }
        .onReceive(lyricsService.$translatedLines) { newValue in
            print("🖥️ [WordByWord] 收到 translatedLines 变化 | 新值行数: \(newValue.count)")
            syncWithCurrentLine()
        }
        .onReceive(lyricsService.$currentLyricIndex) { newIndex in
            print("🖥️ [WordByWord] 收到 currentLyricIndex 变化: \(newIndex)")
            syncWithCurrentLine()
        }
        .onReceive(lyricsService.$currentSongId) { newIndex in
            syncWithCurrentLine()
        }
    }
    
    private func updateContainerWidth(_ newWidth: CGFloat) {
        let width = max(newWidth, 1)
        guard width != containerWidth else { return }
        containerWidth = width
        if !currentLineWords.isEmpty {
            cachedLineHeight = LyricHighlightLayer.computeHeight(words: currentLineWords, fontSize: 18, containerWidth: containerWidth)
        }
    }
    
    private func syncWithCurrentLine() {
        print("🖥️ [WordByWord] syncWithCurrentLine 调用 | isLoading: \(lyricsService.isLoading) | wordLyrics行数: \(lyricsService.wordLyrics.count) | currentLyricIndex: \(lyricsService.currentLyricIndex)")
        if lyricsService.isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syncWithCurrentLine()
            }
            return
        }
        
        if lyricsService.wordLyrics.isEmpty,
           let currentSong = playbackService.currentSong,
           !lyricsService.hasNoLyrics(for: currentSong.id) {   // ✅ 新增条件
            lyricsService.fetchLyrics(for: currentSong)
            return
        }
        
        guard !lyricsService.wordLyrics.isEmpty else {
            currentLineWords = []
            nextLineText = ""
            return
        }
        
        let currentTime = playbackService.currentTime + lyricsService.lyricOffset
        let wordLyrics = lyricsService.wordLyrics
        var idx = 0
        for i in 0..<wordLyrics.count {
            guard let firstWord = wordLyrics[i].first else { continue }
            if currentTime >= firstWord.startTime {
                idx = i
            } else {
                break
            }
        }
        idx = max(0, min(idx, wordLyrics.count - 1))
        
        if lyricsService.currentLyricIndex != idx {
            lyricsService.currentLyricIndex = idx
        }
        
        guard idx < wordLyrics.count else {
            currentLineWords = []
            nextLineText = ""
            return
        }
        
        let newWords = wordLyrics[idx]
        if currentLineWords.map(\.id) != newWords.map(\.id) {
            currentLineWords = newWords
            cachedLineWords = newWords
            cachedLineHeight = LyricHighlightLayer.computeHeight(words: newWords, fontSize: 18, containerWidth: containerWidth)
        }
        
        let nextIdx = idx + 1
        nextLineText = (nextIdx < wordLyrics.count) ? wordLyrics[nextIdx].map(\.word).joined() : ""
    }
}
