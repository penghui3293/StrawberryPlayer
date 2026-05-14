import SwiftUI
import Combine

/// 提供与屏幕刷新率同步的高亮时间，确保逐字填充流畅且精确
@MainActor
class LyricsHighlightTimer: ObservableObject {
    @Published var currentHighlightTime: TimeInterval = 0
    
    private var displayLink: CADisplayLink?
    private weak var playbackService: PlaybackService?
    private weak var lyricsService: LyricsService?
    
    func start(playbackService: PlaybackService, lyricsService: LyricsService) {
        self.playbackService = playbackService
        self.lyricsService = lyricsService
        stop()
        
        let displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateTime() {
        guard let playbackService = playbackService,
              let lyricsService = lyricsService else { return }
        let rawTime = playbackService.currentTime + lyricsService.lyricOffset
        // 避免无效值（如 NaN 或过大）
        currentHighlightTime = rawTime.isFinite ? rawTime : 0
    }
}
