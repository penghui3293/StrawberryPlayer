import SwiftUI
import Combine

struct WordByWordLyricsView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    
    var onTap: (() -> Void)?
    
    @State private var currentLineWords: [WordLyrics] = []
    @State private var nextLineText: String = ""
    
    // 容器宽度与高度缓存（自适应横竖屏）
    @State private var containerWidth: CGFloat = max(UIScreen.main.bounds.width - 32, 1)
    @State private var cachedLineHeight: CGFloat = 0
    @State private var cachedLineWords: [WordLyrics] = []
    
    
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
            } else {
                let color = playbackService.accentColor == .clear
                ? Color.white.opacity(0.6)
                : inactiveColor
                Text(playbackService.currentSong?.title ?? "")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(color)
                    .padding(.horizontal, 16)
            }
            
            if !nextLineText.isEmpty {
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
            // 强制更新一次索引（基于当前播放时间）
//            let currentTime = playbackService.currentTime + lyricsService.lyricOffset
//            lyricsService.updateCurrentIndex(with: currentTime)
            syncWithCurrentLine()
        }
        .onReceive(playbackService.$currentSong) { _ in
            // 切歌时强制刷新容器宽度，防止偏移
            let newWidth = max(UIScreen.main.bounds.width - 32, 1)
            if newWidth != containerWidth {
                containerWidth = newWidth
                if !currentLineWords.isEmpty {
                    cachedLineHeight = LyricHighlightLayer.computeHeight(words: currentLineWords, fontSize: 18, containerWidth: containerWidth)
                }
            }
            // ✅ 切歌时重置标志，以便新歌显示时重新定位
            syncWithCurrentLine()
        }
        .onReceive(lyricsService.$currentLyricIndex) { _ in syncWithCurrentLine() }
        .onReceive(lyricsService.$wordLyrics) { _ in syncWithCurrentLine() }
        .onReceive(lyricsService.$currentSongId) { _ in syncWithCurrentLine() }
    }
    
    private func updateContainerWidth(_ newWidth: CGFloat) {
        let width = max(newWidth, 1)
        guard width != containerWidth else { return }
        containerWidth = width
        // 宽度变化时重新计算当前行高度
        if !currentLineWords.isEmpty {
            cachedLineHeight = LyricHighlightLayer.computeHeight(
                words: currentLineWords, fontSize: 18, containerWidth: containerWidth
            )
        }
    }
    

    private func syncWithCurrentLine() {
        if lyricsService.wordLyrics.isEmpty,
           let currentSong = playbackService.currentSong,
           lyricsService.currentSongId == currentSong.id {
            lyricsService.fetchLyrics(for: currentSong)
            return
        }
        
        guard !lyricsService.wordLyrics.isEmpty else {
            currentLineWords = []
            nextLineText = ""
            return
        }
        
        // ✅ 关键修复：实时根据当前播放时间计算索引，避免依赖可能旧的 currentLyricIndex
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
        // 边界保护
        idx = max(0, min(idx, wordLyrics.count - 1))
        
        // 更新 lyricsService 的 currentLyricIndex（保持与外部同步，但不再依赖它）
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
            cachedLineHeight = LyricHighlightLayer.computeHeight(
                words: newWords, fontSize: 18, containerWidth: containerWidth
            )
        }
        
        let nextIdx = idx + 1
        nextLineText = (nextIdx < wordLyrics.count)
            ? wordLyrics[nextIdx].map(\.word).joined() : ""
    }
    
//    private func syncWithCurrentLine() {
//        if lyricsService.wordLyrics.isEmpty,
//           let currentSong = playbackService.currentSong,
//           lyricsService.currentSongId == currentSong.id {
//            lyricsService.fetchLyrics(for: currentSong)
//            return
//        }
//        
//        guard !lyricsService.wordLyrics.isEmpty else {
//            currentLineWords = []
//            nextLineText = ""
//            return
//        }
//        
//        // ✅ 首次显示时强制根据当前时间更新索引
//        if !hasInitializedPosition {
//            let currentTime = playbackService.currentTime + lyricsService.lyricOffset
//            lyricsService.updateCurrentIndex(with: currentTime)
//            hasInitializedPosition = true
//        }
//        
//        let idx = max(0, min(lyricsService.currentLyricIndex, lyricsService.wordLyrics.count - 1))
//        guard idx < lyricsService.wordLyrics.count else {
//            currentLineWords = []
//            nextLineText = ""
//            return
//        }
//        
//        let newWords = lyricsService.wordLyrics[idx]
//        if currentLineWords.map(\.id) != newWords.map(\.id) {
//            currentLineWords = newWords
//            cachedLineWords = newWords
//            cachedLineHeight = LyricHighlightLayer.computeHeight(
//                words: newWords, fontSize: 18, containerWidth: containerWidth
//            )
//        }
//        
//        let nextIdx = idx + 1
//        nextLineText = (nextIdx < lyricsService.wordLyrics.count)
//        ? lyricsService.wordLyrics[nextIdx].map(\.word).joined() : ""
//    }
}
