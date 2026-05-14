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
        
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if lyricsService.lyrics.isEmpty {
                        Color.clear
                            .frame(width: 0, height: 0)
                            .onAppear {
                                if let song = playbackService.currentSong,
                                   lyricsService.currentSongId == song.id,
                                   !lyricsService.isLoading {
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
                            }
                            .id(index)
                            .background(Color.clear)
                        }
                    }
                    // ✅ 严格保留原版底部垫片，确保每一句歌词都能被推到顶部
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
                lyricsService.updateCurrentIndex(with: playbackService.currentTime + lyricsService.lyricOffset)
                lastScrolledTargetIndex = -1
                lastScrollTime = 0
                // 延迟足够长，确保 ScrollView 已经渲染完成
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.scrollToCurrentLyric(using: proxy, animated: false)
                        // 二次保险：再延迟 0.1 秒，防止首次布局未完全
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.scrollToCurrentLyric(using: proxy, animated: false)
                        }
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
            .onReceive(lyricsService.$currentLyricIndex) { newIndex in
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
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scrollToCurrentLyric(using: proxy) }
                // ✅ 索引变化时使用动画滚动（平滑过渡）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.scrollToCurrentLyric(using: proxy, animated: true)
                }
            }
        }
    }
    
    private func scrollToCurrentLyric(using proxy: ScrollViewProxy, animated: Bool = true) {
        let idx = lyricsService.currentLyricIndex
        guard idx >= 0, idx < lyricsService.lyrics.count else { return }
        let now = CACurrentMediaTime()
        guard now - lastScrollTime >= 0.2 else { return }
        lastScrollTime = now
        lastScrolledTargetIndex = idx
        if animated {
            withAnimation(.easeOut(duration: 0.45)) {
                proxy.scrollTo(idx, anchor: .top)
            }
        } else {
            proxy.scrollTo(idx, anchor: .top)
        }
    }
    
//    private func scrollToCurrentLyric(using proxy: ScrollViewProxy) {
//        let idx = lyricsService.currentLyricIndex
//        guard idx >= 0, idx < lyricsService.lyrics.count else { return }
//        let now = CACurrentMediaTime()
//        guard now - lastScrollTime >= 0.2 else { return }
//        lastScrollTime = now
//        lastScrolledTargetIndex = idx
//        // 平滑推动效果，无弹簧
//        withAnimation(.easeOut(duration: 0.45)) {
//            proxy.scrollTo(idx, anchor: .top)
//        }
//    }
    
    
}
