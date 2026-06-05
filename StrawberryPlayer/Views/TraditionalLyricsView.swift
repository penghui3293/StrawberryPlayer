import SwiftUI
import Combine

struct TraditionalLyricsView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @EnvironmentObject var lyricsService: LyricsService
    
    var isFullScreen: Bool = false
    var onDismiss: (() -> Void)? = nil
    
    @State private var lastScrolledTargetIndex: Int = -1
    @State private var lastScrollTime: TimeInterval = 0
    
    @State private var containerWidth: CGFloat = max(UIScreen.main.bounds.width - 32, 1)
    @State private var cachedCurrentLineHeight: CGFloat = 0
    @State private var cachedWords: [WordLyrics] = []
    
    // 判断是否为英文歌曲（通过翻译数据是否存在）
    private var isEnglishSong: Bool {
        return lyricsService.translatedLyrics != nil && !lyricsService.translatedLyrics!.isEmpty
    }
    
    var body: some View {
        let inactiveColor: Color = playbackService.accentColor == .clear
        ? Color.white.opacity(0.2)
        : playbackService.accentColor.mix(with: .white, amount: 0.2)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if lyricsService.lyrics.isEmpty {
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onAppear {
                                if let song = playbackService.currentSong,
                                   !lyricsService.isLoading ,
                                   !lyricsService.hasNoLyrics(for: song.id) {   // ✅ 新增条件
                                    lyricsService.fetchLyrics(for: song)
                                }
                            }
                        if lyricsService.isLoading {
                            ProgressView().tint(.white).scaleEffect(1.5).padding()
                        } else {
                            Text(playbackService.currentSong?.title ?? "")
                                .foregroundColor(.white)
                                .font(isFullScreen ? .title2 : .body)
                                .padding()
                        }
                    } else {
                        ForEach(Array(lyricsService.lyrics.enumerated()), id: \.offset) { index, line in
                            let isCurrent = (index == lyricsService.currentLyricIndex && isFullScreen && lyricsService.currentLyricIndex >= 0)
                            let isInstrumental: Bool = {
                                let rawTime = playbackService.currentTime + lyricsService.lyricOffset
                                guard let words = lyricsService.wordLyrics[safe: index],
                                      let first = words.first, let last = words.last else { return true }
                                let isLastLine = (index == lyricsService.wordLyrics.count - 1)
                                if isLastLine {
                                    return rawTime < first.startTime
                                } else {
                                    let lineEnd = (index + 1 < lyricsService.wordLyrics.count)
                                    ? (lyricsService.wordLyrics[index + 1].first?.startTime ?? last.endTime + 0.5)
                                    : last.endTime + 0.5
                                    return rawTime < first.startTime || rawTime >= lineEnd
                                }
                            }()
                            
                            VStack(alignment: .leading, spacing: 0) {
                                // 当前行显示（高亮或普通）
                                if isCurrent && !isInstrumental {
                                    if let words = lyricsService.wordLyrics[safe: index], !words.isEmpty {
                                        let fontSize: CGFloat = 24
                                        let height = cachedCurrentLineHeight
                                        
                                        LyricHighlightLayerView(
                                            words: words,
                                            currentTime: playbackService.currentTime + lyricsService.lyricOffset,
                                            activeColor: .white,
                                            inactiveColor: playbackService.accentColor.mix(with: .white, amount: 0.2),
                                            fontSize: fontSize,
                                            containerWidth: containerWidth
                                        )
                                        .frame(width: containerWidth, height: height)
                                        .padding(.horizontal, 16)
                                        .onAppear {
                                            if cachedWords.map(\.id) != words.map(\.id) {
                                                cachedWords = words
                                                cachedCurrentLineHeight = LyricHighlightLayer.computeHeight(
                                                    words: words, fontSize: fontSize, containerWidth: containerWidth
                                                )
                                            }
                                        }
                                    } else {
                                        Text(line.text)
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 16)
                                    }
                                } else {
                                    let inactiveColor: Color = playbackService.accentColor == .clear
                                    ? Color.white.opacity(0.2)
                                    : playbackService.accentColor.mix(with: .white, amount: 0.2)
                                    Text(line.text)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(inactiveColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                }
                                
                                // 英文歌曲：在每行歌词下方添加中文翻译
                                if isEnglishSong {
                                    let _ = print("📜 [Traditional] 渲染行 \(index)，isEnglishSong=\(isEnglishSong), translatedWordLyrics.count=\(lyricsService.translatedWordLyrics.count)")
                                    
                                    if !lyricsService.translatedWordLyrics.isEmpty, index < lyricsService.translatedWordLyrics.count {
                                        let transWords = lyricsService.translatedWordLyrics[index]
                                        let transHeight = LyricHighlightLayer.computeHeight(words: transWords, fontSize: 14, containerWidth: containerWidth)
                                        LyricHighlightLayerView(
                                            words: transWords,
                                            currentTime: playbackService.currentTime + lyricsService.lyricOffset,
                                            activeColor: .white,
                                            inactiveColor: isCurrent ? Color.white.opacity(0.2) : inactiveColor,  // 当前行高亮，非当前行灰色
                                            fontSize: 18,                  // ✅ 改为 18
                                            containerWidth: containerWidth
                                        )
                                        .frame(width: containerWidth, height: transHeight)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 4)
                                    } else if let transLine = lyricsService.translatedLines[safe: index] {
                                        // 降级：静态翻译文本
                                        Text(transLine)
                                            .font(.system(size: 18))        // ✅ 改为 18
                                            .foregroundColor(isCurrent ? .white.opacity(0.2) : inactiveColor)
                                            .padding(.horizontal, 16)
                                            .padding(.top, 2)
                                    }
                                }
                            }
                            .id(index)
                            .background(Color.clear)
                        }
                    }
                    Color.clear.frame(height: UIScreen.main.bounds.height)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            let newWidth = max(geometry.size.width - 32, 1)
                            if newWidth != containerWidth {
                                containerWidth = newWidth
                                if let currentWords = lyricsService.wordLyrics[safe: lyricsService.currentLyricIndex] {
                                    cachedCurrentLineHeight = LyricHighlightLayer.computeHeight(
                                        words: currentWords, fontSize: 24, containerWidth: containerWidth
                                    )
                                }
                            }
                        }
                        .onChange(of: geometry.size.width) { newWidth in
                            let w = max(newWidth - 32, 1)
                            containerWidth = w
                            if let currentWords = lyricsService.wordLyrics[safe: lyricsService.currentLyricIndex] {
                                cachedCurrentLineHeight = LyricHighlightLayer.computeHeight(
                                    words: currentWords, fontSize: 24, containerWidth: w
                                )
                            }
                        }
                }
            )
            .onAppear {
                lyricsService.useCustomSentenceDuration = false
                lyricsService.minLineDisplayDuration = 0
                lastScrolledTargetIndex = -1
                lastScrollTime = 0
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let currentIdx = lyricsService.currentLyricIndex
                    if currentIdx >= 0 && currentIdx < lyricsService.lyrics.count {
                        self.scrollToCurrentLyric(using: proxy, animated: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.scrollToCurrentLyric(using: proxy, animated: false)
                        // ✅ 再发一次通知确保（可选）
                        NotificationCenter.default.post(name: .forceScrollToCurrentLyric, object: nil)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .forceScrollToCurrentLyric)) { _ in
                // 强制滚动，忽略节流
                let idx = lyricsService.currentLyricIndex
                guard idx >= 0, idx < lyricsService.lyrics.count else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(idx, anchor: .top)
                }
            }
            .onReceive(playbackService.$currentSong) { _ in
                let newWidth = max(UIScreen.main.bounds.width - 32, 1)
                if newWidth != containerWidth {
                    containerWidth = newWidth
                    if let currentWords = lyricsService.wordLyrics[safe: lyricsService.currentLyricIndex] {
                        cachedCurrentLineHeight = LyricHighlightLayer.computeHeight(words: currentWords, fontSize: 24, containerWidth: containerWidth)
                    }
                }
                lyricsService.updateCurrentIndex(with: playbackService.currentTime + lyricsService.lyricOffset)
            }
            .onReceive(lyricsService.$wordLyrics) { newValue in
                print("📜 [Traditional] 收到 wordLyrics 变化 | 行数: \(newValue.count)")
            }
            .onReceive(lyricsService.$translatedWordLyrics) { newValue in
                print("📜 [Traditional] 收到 translatedWordLyrics 变化 | 行数: \(newValue.count)")
            }
            .onReceive(lyricsService.$currentLyricIndex) { newIndex in
                print("📜 [Traditional] 收到 currentLyricIndex 变化: \(newIndex)")
                
                guard newIndex >= 0 else { return }
                if let words = lyricsService.wordLyrics[safe: newIndex], !words.isEmpty {
                    let newWords = words
                    if cachedWords.map(\.id) != newWords.map(\.id) {
                        cachedWords = newWords
                        cachedCurrentLineHeight = LyricHighlightLayer.computeHeight(
                            words: newWords, fontSize: 24, containerWidth: containerWidth
                        )
                    }
                }
                self.scrollToCurrentLyric(using: proxy, animated: true)
                //                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                //                    self.scrollToCurrentLyric(using: proxy, animated: true)
                //                }
            }
        }
    }
    
    private func scrollToCurrentLyric(using proxy: ScrollViewProxy, animated: Bool = true) {
        let idx = lyricsService.currentLyricIndex
        guard idx >= 0, idx < lyricsService.lyrics.count else { return }
        lastScrolledTargetIndex = idx
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(idx, anchor: .top)
            }
        } else {
            proxy.scrollTo(idx, anchor: .top)
        }
    }
    
    //    private func scrollToCurrentLyric(using proxy: ScrollViewProxy, animated: Bool = true) {
    //        let idx = lyricsService.currentLyricIndex
    //        guard idx >= 0, idx < lyricsService.lyrics.count else { return }
    //        let now = CACurrentMediaTime()
    //        guard now - lastScrollTime >= 0.2 else { return }
    //        lastScrollTime = now
    //        lastScrolledTargetIndex = idx
    //        if animated {
    //            withAnimation(.easeOut(duration: 0.45)) {
    //                proxy.scrollTo(idx, anchor: .top)
    //            }
    //        } else {
    //            proxy.scrollTo(idx, anchor: .top)
    //        }
    //    }
}
