
//
//  LyricsService.swift
//  StrawberryPlayer
//  负责歌词的加载、解析和管理，包括本地和在线获取，并提供给 UI 层使用
//  Created by penghui zhang on 2026/2/19.
//

import Foundation
import Combine
import QuartzCore

extension Notification.Name {
    static let songWordLyricsDidRepair = Notification.Name("songWordLyricsDidRepair")
}

// MARK: - Mureka 逐词歌词 JSON 解码结构（必须与 Mureka API 返回的 lyrics_sections 字段完全匹配）
public struct MurekaLyricsSection: Decodable {
    let section_type: String?
    let start: Int?
    let end: Int?
    let lines: [MurekaLyricLine]?
}

public struct MurekaLyricLine: Decodable {
    let text: String
    let words: [MurekaWord]?
}

public struct MurekaWord: Decodable {
    let text: String
    let start: Int      // 毫秒
    let end: Int        // 毫秒
}

class LyricsService: ObservableObject {
    
    @Published var wordLyrics: [[WordLyrics]] = [] {
        didSet {
            if !Thread.isMainThread {
                print("❌ wordLyrics 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var currentPlaybackTime: TimeInterval = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ currentPlaybackTime 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var lyricOffset: TimeInterval = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ lyricOffset 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var isLoading = false {
        didSet {
            if !Thread.isMainThread {
                print("❌ isLoading 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var currentLyricText: String = "" {
        didSet {
            if !Thread.isMainThread {
                print("❌ currentLyricText 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var lyrics: [LyricLine] = []  {
        didSet {
            if !Thread.isMainThread {
                print("❌ lyrics 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var currentLyricIndex: Int = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ currentLyricIndex 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    @Published var currentWordIndex: Int = 0 {
        didSet {
            if !Thread.isMainThread {
                print("❌ currentWordIndex 在后台线程被修改")
                Thread.callStackSymbols.forEach { print($0) }
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    // 新增：记录当前正在加载的歌曲 ID，避免旧任务干扰
    var currentLoadingSongId: String?   // 改为 internal，可供 FullPlayerView 读取
    private let stateQueue = DispatchQueue(label: "com.strawberry.lyrics.stateQueue")  // 新增：保护内部状态
    
    // 网络歌词获取任务
    private var networkFetchTask: Task<Void, Never>?
    
    // 固定时长模式（用于紧凑模式匀速扫描）
    @Published var useCustomSentenceDuration: Bool = false
    @Published var customSentenceDuration: TimeInterval = 5.0
    
    // 动态校准相关
    private var lastCalibrationTime: TimeInterval = 0
    private let calibrationInterval: TimeInterval = 1.0   // 每秒校准一次
    private var isCalibrating = false
    
    // 最小行显示时长（秒），避免因数据过短导致行切换太快
    public var minLineDisplayDuration: TimeInterval = 0.8
    private var lineSwitchTime: TimeInterval = 0          // 记录当前行开始时间
    private var lastUpdateTime: TimeInterval = 0
    // 防止重复修复同一首歌
    private var repairingSongIds = Set<String>()
    
    // ✅ 修改：快歌适配，最小字符填充时长降至 0.5 秒
    private let minCharacterFillDuration: TimeInterval = 0.5
    
    @Published var currentLineSpeedFactor: Double = 1.0  // 当前行的速度补偿因子
    
    // 新增驱动控制
    private var isDriverPaused = false
    @Published var currentSongId: String?
    
    // 新增：行时长缓存，避免重复计算
    private var cachedLineDurations: [TimeInterval] = []
    
    private var throttleTime: TimeInterval = 0
    
    private let throttleInterval: TimeInterval = 0.08  // 60fps，也可直接注释节流逻辑
    
    private var isLoadingFetch = false
    
    
    let parsedWordLyricsCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 10          // 最多缓存 10 首歌曲的解析结果
        cache.totalCostLimit = 4 * 1024 * 1024   // 4 MB，足够存几十行逐字数据
        return cache
    }()
    
    private var wordTheoreticalStarts: [String: TimeInterval] = [:]
    
    init() {
        parsedWordLyricsCache.countLimit = 10
        parsedWordLyricsCache.totalCostLimit = 16 * 1024 * 1024   // 提高到 16 MB，匹配复杂歌词
        
        lyricsCache.countLimit = 10
        lyricsCache.totalCostLimit = 8 * 1024 * 1024             // 提高到 8 MB
    }
    
    func cancelCurrentLoading() {
        networkFetchTask?.cancel()
        networkFetchTask = nil
        isLoadingFetch = false
        currentLoadingSongId = nil
    }
    
    func pauseDriver() {
        print("💾 [LyricsDriver pause] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")
        
        isDriverPaused = true
    }
    
    func resumeDriver() {
        print("💾 [LyricsDriver resume] 内存: \(String(format: "%.1f", currentMemoryInMB())) MB")
        
        isDriverPaused = false
        // 恢复后立即更新一次，避免滞后
        let currentTime = currentPlaybackTime
        updateCurrentIndex(with: currentTime)
    }
    
    // 在 LyricsService 类中添加清洗方法（替换原有）
    private func cleanLyricsText(_ text: String) -> String {
        var cleaned = text
        let patterns = ["[尾声]", "[副歌]", "[间奏]", "[前奏]", "[桥段]",
                        "（尾声）", "（副歌）", "（间奏）", "（前奏）", "（桥段）",
                        "(尾声)", "(副歌)", "(间奏)", "(前奏)", "(桥段)"]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "")
        }
        return cleaned
    }
    
    public func parseLRC(_ content: String) -> [LyricLine] {
        // 1. 处理可能的 BOM 头和统一换行符
        var cleanedContent = content
        if content.hasPrefix("\u{FEFF}") {
            cleanedContent = String(content.dropFirst())
        }
        let lines = cleanedContent.components(separatedBy: .newlines)
        
        var tempLines: [(startTime: TimeInterval, text: String)] = []
        
        // 2. 更宽松的正则：支持 [mm:ss.xx]、[mm:ss.xxx]、[mm:ss]
        let pattern = "\\[(\\d{1,2}):(\\d{2})(?:[.:](\\d{2,3}))?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            
            let nsLine = trimmedLine as NSString
            let matches = regex.matches(in: trimmedLine, range: NSRange(location: 0, length: nsLine.length))
            if matches.isEmpty { continue }
            
            let lastMatch = matches.last!
            let textStart = lastMatch.range.location + lastMatch.range.length
            let text = textStart < nsLine.length ? nsLine.substring(from: textStart) : ""
            
            for match in matches {
                let minute = nsLine.substring(with: match.range(at: 1))
                let second = nsLine.substring(with: match.range(at: 2))
                let millisecond: String
                if match.numberOfRanges > 3, let msRange = Range(match.range(at: 3), in: trimmedLine) {
                    millisecond = String(trimmedLine[msRange])
                } else {
                    millisecond = "00"
                }
                
                let minutes = Double(minute) ?? 0
                let seconds = Double(second) ?? 0
                let ms = Double(millisecond) ?? 0
                let totalSeconds = minutes * 60 + seconds + (ms / (millisecond.count == 2 ? 100 : 1000))
                
                tempLines.append((startTime: totalSeconds, text: text.trimmingCharacters(in: .whitespaces)))
            }
        }
        
        tempLines.sort { $0.startTime < $1.startTime }
        
        var result: [LyricLine] = []
        for i in 0..<tempLines.count {
            let current = tempLines[i]
            let endTime: TimeInterval? = (i + 1 < tempLines.count) ? tempLines[i + 1].startTime : nil
            let cleanedText = cleanLyricsText(current.text)
            let lyricLine = LyricLine(startTime: current.startTime, endTime: endTime, text: cleanedText)
            result.append(lyricLine)
        }
        
        print("📄 parseLRC 解析到 \(result.count) 行")
        return result
    }
    
    
    func clearParsedCache(for songId: String) {
        parsedWordLyricsCache.removeObject(forKey: songId as NSString)
    }
    
    func clearAllParsedCache() {
        parsedWordLyricsCache.removeAllObjects()
    }
    
    func fetchLyrics(for song: Song, songDuration: TimeInterval = 0) {
        var song = song
        
        // 避免重复加载
        if let loadingId = currentLoadingSongId, loadingId == song.id { return }

        // 如果已有同首歌歌词且未在加载中，更新进度并通知
        if currentSongId == song.id, !wordLyrics.isEmpty, currentLoadingSongId == nil {
            updateCurrentIndex(with: currentPlaybackTime)
            return
        }


        if currentSongId == song.id, !lyrics.isEmpty, !wordLyrics.isEmpty {
            updateCurrentIndex(with: currentPlaybackTime)
            return
        }

        // 1. 全局缓存
        if let cached = parsedWordLyricsCache.object(forKey: song.id as NSString) as? [[WordLyrics]],
           !cached.isEmpty, isWordLyricsValid(cached) {
            applyWordLyricsAndNotify(cached, songId: song.id)
            return
        }

        // 2. 内存缓存
        if let cached = song.cachedWordLyrics, !cached.isEmpty, isWordLyricsValid(cached) {
            applyWordLyricsAndNotify(cached, songId: song.id)
            return
        }

        // 3. 开始加载
        currentLoadingSongId = song.id
        currentSongId = song.id
        DispatchQueue.main.async {
            self.lyrics = []
            self.wordLyrics = []
            self.currentLyricIndex = 0
            self.isLoading = true
        }

        let isClassical = song.style?.lowercased() == "古典" || song.virtualArtistId == nil
        let hasNoLyricsData = song.lyrics == nil && song.wordLyrics == nil
        if isClassical && hasNoLyricsData {
            DispatchQueue.main.async {
                self.lyrics = []
                self.wordLyrics = []
                self.isLoading = false
                NotificationCenter.default.post(name: .lyricsDidUpdate, object: song.id)
            }
            return
        }

        // 4. 异步解析
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let wordLyricsString = song.wordLyrics, !wordLyricsString.isEmpty,
               let wordData = wordLyricsString.data(using: .utf8) {
                do {
                    let sections = try JSONDecoder().decode([MurekaLyricsSection].self, from: wordData)
                    let lines = self.convertMurekaSectionsToLyricLines(sections)
                    if !lines.isEmpty {
                        let words = lines.map { $0.words }
                        self.parsedWordLyricsCache.setObject(words as NSArray, forKey: song.id as NSString)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            guard self.currentLoadingSongId == song.id else { return }
                            self.applyWordLyricsAndNotify(words, songId: song.id)
                        }
                        return
                    }
                } catch {
                    if let json = try? JSONSerialization.jsonObject(with: wordData) as? [String: Any],
                       let sectionsArray = json["sections"] as? [[String: Any]],
                       let sectionsData = try? JSONSerialization.data(withJSONObject: sectionsArray) {
                        do {
                            let sections = try JSONDecoder().decode([MurekaLyricsSection].self, from: sectionsData)
                            let lines = self.convertMurekaSectionsToLyricLines(sections)
                            if !lines.isEmpty {
                                let words = lines.map { $0.words }
                                self.parsedWordLyricsCache.setObject(words as NSArray, forKey: song.id as NSString)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    guard self.currentLoadingSongId == song.id else { return }
                                    self.applyWordLyricsAndNotify(words, songId: song.id)
                                }
                                return
                            }
                        } catch {}
                    }
                }
            }

            // LRC 文本
            if let lyricsText = song.lyrics, !lyricsText.isEmpty {
                let parsed = self.parseLRC(lyricsText)
                if !parsed.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard self.currentLoadingSongId == song.id else { return }
                        self.lyrics = parsed
                        self.wordLyrics = []
                        self.isLoading = false
                        self.currentLoadingSongId = nil
                        NotificationCenter.default.post(name: .lyricsDidUpdate, object: song.id)
                    }
                    return
                }
                let rawLines = lyricsText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !rawLines.isEmpty {
                    let total = song.duration > 0 ? song.duration : 180
                    let interval = max(1, total / Double(rawLines.count))
                    let lyricLines = rawLines.enumerated().map { i, text in
                        LyricLine(startTime: Double(i) * interval, endTime: Double(i+1) * interval, text: text)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard self.currentLoadingSongId == song.id else { return }
                        self.lyrics = lyricLines
                        self.wordLyrics = []
                        self.isLoading = false
                        self.currentLoadingSongId = nil
                        NotificationCenter.default.post(name: .lyricsDidUpdate, object: song.id)
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                guard self.currentLoadingSongId == song.id else { return }
                self.performNetworkFetch(for: song, songDuration: songDuration)
            }
        }
    }
    
    private func applyWordLyricsAndNotify(_ wordLyrics2D: [[WordLyrics]], songId: String) {
        DispatchQueue.main.async {
            self.lyricOffset = 0
            self.wordLyrics = wordLyrics2D
            self.precomputeProgressMetadata()
            // ✅ 同步填充 lyrics 数组，保证控制中心等依赖方可用
            self.lyrics = wordLyrics2D.enumerated().map { index, words in
                let lineText = words.map { $0.word }.joined()
                let startTime = words.first?.startTime ?? 0
                let endTime = words.last?.endTime ?? (index + 1 < wordLyrics2D.count ? wordLyrics2D[index+1].first?.startTime : nil)
                return LyricLine(startTime: startTime, endTime: endTime, text: lineText, words: words)
            }
            self.isLoading = false
            self.currentLoadingSongId = nil
            self.currentSongId = songId
            self.updateCurrentIndex(with: self.currentPlaybackTime)
            self.objectWillChange.send()
            NotificationCenter.default.post(name: .lyricsDidUpdate, object: songId)
        }
    }
    
    private func fallbackToLRCParsing(lyricsText: String, song: Song) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let parsedLines = self.parseLRC(lyricsText)
            DispatchQueue.main.async {
                guard self.currentLoadingSongId == song.id else { return }
                self.lyrics = parsedLines
                self.wordLyrics = []
                self.isLoading = false
                self.currentLoadingSongId = nil
                self.updateCurrentIndex(with: self.currentPlaybackTime)
            }
        }
    }
    
    // MARK: - 将 Mureka 的 sections 转换为 [LyricLine]
    private func convertMurekaSectionsToLyricLines(_ sections: [MurekaLyricsSection]) -> [LyricLine] {
        var result: [LyricLine] = []
        
        for section in sections {
            guard let lines = section.lines else { continue }
            for line in lines {
                guard let words = line.words, !words.isEmpty else {
                    print("⚠️ Mureka 行缺少逐词数据: \(line.text)")
                    continue
                }
                var wordLyricsArray: [WordLyrics] = []
                for word in words {
                    let splitWords = splitWordIntoCharacters(word)
                    wordLyricsArray.append(contentsOf: splitWords)
                }
                // 直接使用原始时间戳，不进行任何缩放
                let startTime = wordLyricsArray.first?.startTime ?? 0
                let endTime = wordLyricsArray.last?.endTime ?? startTime + 0.5
                let text = wordLyricsArray.map { $0.word }.joined()
                let lyricLine = LyricLine(startTime: startTime, endTime: endTime, text: text, words: wordLyricsArray)
                result.append(lyricLine)
            }
        }
        
        
        
        // 保存二维缓存（如果需要）
        if let songId = currentLoadingSongId {
            let wordLyrics2D = result.map { $0.words }
            saveWordLyrics2DToCache(songId: songId, wordLyrics2D: wordLyrics2D)
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
    
    private func performNetworkFetch(for song: Song, songDuration: TimeInterval) {
        // 取消之前的网络请求任务
        networkFetchTask?.cancel()
        networkFetchTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let lyricsText = try await LyricsDownloadService.shared.fetchLyricsAsync(for: song)
                
                try Task.checkCancellation()   // ✅ 关键：检查取消状态
                await MainActor.run {
                    guard self.currentLoadingSongId == song.id else { return}
                    self.parseLyrics(lyricsText, songDuration: songDuration, for: song.id)
                }
            } catch {
                if Task.isCancelled { return }
                
                await MainActor.run {
                    guard self.currentLoadingSongId == song.id else { return }
                    // 网络失败时尝试 LRC 本地解析作为最终回退
                    if let lyricsText = song.lyrics, !lyricsText.isEmpty {
                        self.fallbackToLRCParsing(lyricsText: lyricsText, song: song)
                    } else {
                        self.lyrics = []
                        self.wordLyrics = []
                        self.isLoading = false
                        self.currentLoadingSongId = nil
                    }
                }
            }
        }
    }
    
    
    // MARK: - 解析网络返回的歌词文本
    private func parseLyrics(_ text: String, songDuration: TimeInterval, for songId: String) {
        let wordLines = LyricsParser.parseWordLyrics(content: text, songDuration: songDuration)
        
        if !wordLines.isEmpty {
            // 逐词格式（已有清洗，无需修改）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.currentLoadingSongId == songId else { return }
                self.applyWordLyricsIfChanged(wordLines)
                self.precomputeProgressMetadata()   // ✅ 新增
                
                self.lyrics = wordLines.enumerated().map { index, words in
                    let lineText = words.map { $0.word }.joined()
                    let cleanedText = self.cleanLyricsText(lineText)
                    let startTime = words.first?.startTime ?? 0
                    let endTime: TimeInterval? = (index + 1 < wordLines.count) ? wordLines[index + 1].first?.startTime : words.last?.endTime
                    return LyricLine(startTime: startTime, endTime: endTime, text: cleanedText, words: words)
                }
                self.updateCurrentIndex(with: self.currentPlaybackTime)
                print("✅ 网络歌词解析为逐词格式，行数: \(self.wordLyrics.count)")
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .lyricsDidUpdate, object: songId) // songId 参数是该方法的入参
            }
        } else {
            // 传统格式分支，需要清洗每一行
            if let traditional = LyricsParser.parse(content: text) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, self.currentLoadingSongId == songId else { return }
                    // ✅ 对每行歌词进行清洗
                    self.lyrics = traditional.map { line in
                        LyricLine(startTime: line.startTime, endTime: line.endTime,
                                  text: self.cleanLyricsText(line.text),
                                  words: line.words)
                    }
                    self.wordLyrics = []
                    self.updateCurrentIndex(with: self.currentPlaybackTime)
                    print("✅ 网络歌词解析为传统格式，行数: \(self.lyrics.count)")
                    self.objectWillChange.send()
                    
                    NotificationCenter.default.post(name: .lyricsDidUpdate, object: songId)

                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.currentLoadingSongId == songId else { return }
                    self.lyrics = []
                    self.wordLyrics = []
                    print("❌ 网络歌词解析失败")
                }
            }
        }
    }
    
    // MARK: - 供视图调用的进度计算（无闭包捕获）
    func progress(for word: WordLyrics, at currentTime: TimeInterval, lineIndex: Int) -> Double {
        guard lineIndex >= 0, lineIndex < wordLyrics.count else { return 0 }
        let line = wordLyrics[lineIndex]
        guard let first = line.first, let last = line.last else { return 0 }
        
        // 原始的开始和结束时间
        let originalStart = word.startTime
        let originalEnd = word.endTime
        let originalDuration = originalEnd - originalStart
        
        // ✅ 最小可见时长（可调整，您原来设置的 0.5 秒左右）
        let minVisibleDuration: TimeInterval = 0.5
        
        // ✅ 关键：只在太短的时候拉长，且不改变原始 startTime
        let effectiveDuration = max(originalDuration, minVisibleDuration)
        
        // 计算进度时，基于原始开始时间，但用拉长后的时长
        let elapsed = currentTime - originalStart
        let rawProgress = elapsed / effectiveDuration
        let clamped = min(max(rawProgress, 0), 1)
        
        if elapsed <= 0 { return 0 }
        if currentTime >= originalEnd { return 1.0 }
        
        // 保留原有的缓动曲线（ease-in-out）
        return clamped < 0.5 ? 2 * clamped * clamped : 1 - pow(-2 * clamped + 2, 2) / 2
    }
    
    func updateCurrentIndex(with time: TimeInterval) {
        guard !isDriverPaused else { return }
        
        // ✅ 节流：每 0.1 秒最多执行一次，避免高频调用导致内存飙升
        let now = CACurrentMediaTime()
        guard now - throttleTime >= throttleInterval else { return }
        throttleTime = now
        
        let adjustedTime = time + lyricOffset
        
        if !wordLyrics.isEmpty {
            var newLineIndex = currentLyricIndex
            
            // 先看是否需要前进到下一行：只有当前行最后一个字已经扫完（时间已超过行结束），才允许切换
            if currentLyricIndex < wordLyrics.count {
                let currentLine = wordLyrics[currentLyricIndex]
                if let lastWord = currentLine.last {
                    let lineEndTime: TimeInterval
                    if currentLyricIndex + 1 < wordLyrics.count,
                       let nextLineFirst = wordLyrics[currentLyricIndex + 1].first {
                        lineEndTime = nextLineFirst.startTime
                    } else {
                        lineEndTime = lastWord.endTime + 0.5
                    }
                    if adjustedTime >= lineEndTime {
                        newLineIndex = min(currentLyricIndex + 1, wordLyrics.count - 1)
                    }
                }
            }
            
            // 如果没前进，再检查是否需要回退
            if newLineIndex == currentLyricIndex {
                for (index, lineWords) in wordLyrics.enumerated() {
                    guard let firstWord = lineWords.first else { continue }
                    if adjustedTime >= firstWord.startTime {
                        newLineIndex = index
                    } else {
                        break
                    }
                }
            }
            
            // 保证新索引在安全范围内
            newLineIndex = min(max(0, newLineIndex), wordLyrics.count - 1)
            
            // 只在索引真正改变时才更新属性
            if self.currentLyricIndex != newLineIndex {
                self.currentLyricIndex = newLineIndex
                
                // 更新当前行速度因子（如果需要）
                if newLineIndex < wordLyrics.count {
                    let lineWords = wordLyrics[newLineIndex]
                    if let firstWord = lineWords.first, let lastWord = lineWords.last {
                        let lineDuration = lastWord.endTime - firstWord.startTime
                        let charCount = lineWords.count
                        let avgCharDuration = lineDuration / Double(max(1, charCount))
                        let baseCharDuration: TimeInterval = 0.15
                        self.currentLineSpeedFactor = max(0.5, min(2.0, baseCharDuration / max(0.05, avgCharDuration)))
                    }
                }
            }
            
            // 动态校准（每 5 秒一次）
            let calibrationNow = CACurrentMediaTime()
            if calibrationNow - lastCalibrationTime > 5.0 {
                lastCalibrationTime = calibrationNow
                performDynamicCalibration(at: adjustedTime)
            }
            return
        }
        
        // LRC 回退模式（同样严格按结束时间切换）
        guard !lyrics.isEmpty else { return }
        var newIndex = currentLyricIndex
        if currentLyricIndex < lyrics.count,
           let line = lyrics[safe: currentLyricIndex],
           let lineEnd = line.endTime,
           adjustedTime >= lineEnd {
            newIndex = min(currentLyricIndex + 1, lyrics.count - 1)
        }
        if newIndex == currentLyricIndex {
            for (index, line) in lyrics.enumerated() {
                if let startTime = line.startTime, adjustedTime >= startTime {
                    newIndex = index
                } else { break }
            }
        }
        newIndex = min(max(0, newIndex), lyrics.count - 1)
        
        if self.currentLyricIndex != newIndex {
            self.currentLyricIndex = newIndex
        }
    }
    
    
    // MARK: - 动态校准（恢复）
    /// 动态校准歌词偏移（由外部驱动定期调用）
    func dynamicCalibration(currentTime: TimeInterval, currentWord: WordLyrics?) {
        guard let word = currentWord else { return }
        let now = CACurrentMediaTime()
        guard now - lastCalibrationTime >= calibrationInterval else { return }
        lastCalibrationTime = now
        
        let progress = word.progress(at: currentTime + lyricOffset)
        if progress < 0.2 && currentTime > word.endTime + 0.1 {
            let adjustment = -0.05
            lyricOffset += adjustment
            print("🔧 动态校准（滞后）: 调整 \(adjustment) 秒，新偏移 \(lyricOffset)")
        } else if progress > 0.8 && currentTime < word.startTime - 0.1 {
            let adjustment = 0.05
            lyricOffset += adjustment
            print("🔧 动态校准（提前）: 调整 \(adjustment) 秒，新偏移 \(lyricOffset)")
        }
    }
    
    private func performDynamicCalibration(at time: TimeInterval) {
        guard currentLyricIndex >= 0, currentLyricIndex < wordLyrics.count,
              let currentLine = wordLyrics[safe: currentLyricIndex] else { return }
        
        guard let currentWord = currentLine.first(where: { time >= $0.startTime && time <= $0.endTime }) else {
            return
        }
        
        let progress = currentWord.progress(at: time)
        let lagThreshold: TimeInterval = 0.05
        let leadThreshold: TimeInterval = 0.05
        
        if progress < 0.2 && time > currentWord.endTime + lagThreshold {
            lyricOffset -= 0.025
        } else if progress > 0.8 && time < currentWord.startTime - leadThreshold {
            lyricOffset += 0.025
        }
        
        lyricOffset = max(-1.5, min(1.5, lyricOffset))
    }
    // MARK: - 持续歌词同步微调
    private var lastAdjustmentTime: TimeInterval = 0
    private let adjustmentInterval: TimeInterval = 2.0 // 每2秒调整一次，避免过于频繁
    
    /// 持续微调歌词偏移量（基于当前字的高亮进度）
    /// - Parameters:
    ///   - currentTime: 当前播放时间（秒）
    ///   - currentWord: 当前正在高亮的字（如果有）
    func continuousAdjustment(currentTime: TimeInterval, currentWord: WordLyrics?) {
        // 仅当歌词偏移为0或尚未有手动调整时自动微调（避免干扰用户已设置的值）
        // 或者根据需求允许微调（这里选择不覆盖用户手动设置的偏移，仅当偏移为0时自动微调）
        guard lyricOffset == 0 else { return }
        guard let word = currentWord else { return }
        
        let now = CACurrentMediaTime()
        guard now - lastAdjustmentTime >= adjustmentInterval else { return }
        lastAdjustmentTime = now
        
        let wordProgress = word.progress(at: currentTime)
        
        // 判断是否严重偏离
        if wordProgress < 0.2 && currentTime > word.endTime + 0.5 {
            // 歌词滞后：实际已经过了当前字的时间，但高亮还没完成 → 减小偏移（让歌词提前）
            let adjustment = -0.1
            lyricOffset += adjustment
            print("🔧 持续微调（歌词滞后）: 调整 \(adjustment) 秒，新偏移: \(lyricOffset)")
        } else if wordProgress > 0.8 && currentTime < word.startTime - 0.3 {
            // 歌词提前：还没到当前字开始时间，但高亮已经快结束了 → 增大偏移（让歌词滞后）
            let adjustment = 0.1
            lyricOffset += adjustment
            print("🔧 持续微调（歌词提前）: 调整 \(adjustment) 秒，新偏移: \(lyricOffset)")
        }
    }
    
    // 添加属性
    private let lyricsCache = NSCache<NSString, NSArray>()
    
    private func saveWordLyrics2DToCache(songId: String, wordLyrics2D: [[WordLyrics]]) {
        // 计算成本：使用 JSON 编码后的大小作为近似内存占用
        var cost = 0
        if let data = try? JSONEncoder().encode(wordLyrics2D) {
            cost = data.count
        }
        lyricsCache.setObject(wordLyrics2D as NSArray, forKey: songId as NSString, cost: cost)
    }
    
    private func loadWordLyrics2DFromCache(songId: String) -> [[WordLyrics]]? {
        return lyricsCache.object(forKey: songId as NSString) as? [[WordLyrics]]
    }
    
    
    private func precomputeProgressMetadata() {
        guard !wordLyrics.isEmpty else { return }
        for line in wordLyrics {
            for word in line {
                if wordTheoreticalStarts[word.id] == nil {
                    wordTheoreticalStarts[word.id] = word.startTime
                }
            }
        }
    }
    
    
    func reset() {
        networkFetchTask?.cancel()
        networkFetchTask = nil
        currentLoadingSongId = nil
        currentSongId = nil                  // 新增：避免误判为同一首歌
        DispatchQueue.main.async {
            self.lyrics = []
            self.wordLyrics = []
            self.currentLyricIndex = 0
            self.isLoading = false
            self.cachedLineDurations = []
            self.wordTheoreticalStarts.removeAll()           // 新增
            self.parsedWordLyricsCache.removeAllObjects()    // 同时清空解析缓存
            self.lyricsCache.removeAllObjects()
        }
        
        // 强制取消仍可能存在的全局网络任务
        URLSession.shared.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }
    
    
    // MARK: - 自动校准歌词偏移（支持网络音频）- 内存优化版
    func autoCalibrateOffset(for song: Song, audioURL: URL, firstWordStartTime: TimeInterval) async {
        // 获取本地可用的音频文件 URL（如果是网络 URL，先下载到临时文件）
        let localURL: URL
        if audioURL.isFileURL {
            localURL = audioURL
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(audioURL.pathExtension)
            do {
                print("🔄 下载音频用于校准: \(audioURL)")
                
                // ✅ 使用 downloadTask 替代 data(from:)，避免将整个文件读入内存
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let task = URLSession.shared.downloadTask(with: audioURL) { downloadedURL, response, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let downloadedURL = downloadedURL else {
                            continuation.resume(throwing: NSError(domain: "LyricsService", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败"]))
                            return
                        }
                        do {
                            try FileManager.default.moveItem(at: downloadedURL, to: tempFile)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    task.resume()
                }
                
                localURL = tempFile
                print("✅ 音频下载完成: \(tempFile.path)")
            } catch {
                print("❌ 下载音频用于校准失败: \(error)")
                return
            }
            
            // 异步执行校准，完成后删除临时文件
            await withCheckedContinuation { continuation in
                LyricsAutoCalibrator.shared.autoCalibrate(audioURL: localURL,
                                                          firstWordStartTime: firstWordStartTime) { offset in
                    DispatchQueue.main.async {
                        let clampedOffset = max(-5.0, min(5.0, offset))
                        if abs(clampedOffset) > 0.3 {
                            self.lyricOffset = clampedOffset
                            print("✅ 自动校准歌词偏移量: \(clampedOffset) 秒 (原始值: \(offset) 秒)")
                            self.saveLyricOffset(for: song)
                        } else {
                            self.lyricOffset = 0
                            self.saveLyricOffset(for: song)
                            print("ℹ️ 偏移量过小 (\(offset) 秒)，重置为0")
                        }
                        // 清理临时文件
                        try? FileManager.default.removeItem(at: localURL)
                        continuation.resume()
                    }
                }
            }
            return
        }
        
        // 本地文件直接校准（无需下载和清理）
        await withCheckedContinuation { continuation in
            LyricsAutoCalibrator.shared.autoCalibrate(audioURL: localURL,
                                                      firstWordStartTime: firstWordStartTime) { offset in
                DispatchQueue.main.async {
                    if abs(offset) > 0.3 {
                        self.lyricOffset = offset
                        print("✅ 自动校准歌词偏移量: \(offset) 秒")
                        self.saveLyricOffset(for: song)
                    } else {
                        print("ℹ️ 偏移量过小 (\(offset) 秒)，不调整")
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - 自动校准歌词偏移（支持网络音频）
    //    func autoCalibrateOffset(for song: Song, audioURL: URL, firstWordStartTime: TimeInterval) async {
    //        // 获取本地可用的音频文件 URL（如果是网络 URL，先下载）
    //        let localURL: URL
    //        if audioURL.isFileURL {
    //            localURL = audioURL
    //        } else {
    //            let tempDir = FileManager.default.temporaryDirectory
    //            let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(audioURL.pathExtension)
    //            do {
    //                print("🔄 下载音频用于校准: \(audioURL)")
    //                let (data, _) = try await URLSession.shared.data(from: audioURL)
    //                try data.write(to: tempFile)
    //                localURL = tempFile
    //                print("✅ 音频下载完成: \(tempFile.path)")
    //            } catch {
    //                print("❌ 下载音频用于校准失败: \(error)")
    //                return
    //            }
    //
    //            // 异步执行校准，完成后删除临时文件
    //            await withCheckedContinuation { continuation in
    //                LyricsAutoCalibrator.shared.autoCalibrate(audioURL: localURL,
    //                                                          firstWordStartTime: firstWordStartTime) { offset in
    //                    DispatchQueue.main.async {
    //                        let clampedOffset = max(-5.0, min(5.0, offset))
    //                        if abs(clampedOffset) > 0.3 {
    //                            self.lyricOffset = clampedOffset
    //                            print("✅ 自动校准歌词偏移量: \(clampedOffset) 秒 (原始值: \(offset) 秒)")
    //                            self.saveLyricOffset(for: song)
    //                        } else {
    //                            // 若偏移量过小，可考虑重置为0，避免之前保存的错误偏移残留
    //                            self.lyricOffset = 0
    //                            self.saveLyricOffset(for: song)
    //                            print("ℹ️ 偏移量过小 (\(offset) 秒)，重置为0")                        }
    //                        // 清理临时文件
    //                        try? FileManager.default.removeItem(at: localURL)
    //                        continuation.resume()
    //                    }
    //                }
    //            }
    //            return
    //        }
    //
    //        // 本地文件直接校准（无需下载和清理）
    //        await withCheckedContinuation { continuation in
    //            LyricsAutoCalibrator.shared.autoCalibrate(audioURL: localURL,
    //                                                      firstWordStartTime: firstWordStartTime) { offset in
    //                DispatchQueue.main.async {
    //                    if abs(offset) > 0.3 {
    //                        self.lyricOffset = offset
    //                        print("✅ 自动校准歌词偏移量: \(offset) 秒")
    //                        self.saveLyricOffset(for: song)
    //                    } else {
    //                        print("ℹ️ 偏移量过小 (\(offset) 秒)，不调整")
    //                    }
    //                    continuation.resume()
    //                }
    //            }
    //        }
    //    }
    // MARK: - 偏移量持久化
    func saveLyricOffset(for song: Song) {
        let key = "lyricOffset-\(song.id)"
        UserDefaults.standard.set(lyricOffset, forKey: key)
    }
    
    // 保留 loadLyrics 以兼容旧调用（可选）
    func loadLyrics(for song: Song) {
        fetchLyrics(for: song, songDuration: 0)
    }
    
    
    // deinit 会触发任务取消（Task 在 deinit 时自动取消，但显式取消更好）
    deinit {
        networkFetchTask?.cancel()
        print("🗑️ LyricsService deinit")
    }
    //    deinit {
    //        print("🗑️ LyricsService deinit")
    //    }
}
// MARK: - Whisper 对齐辅助方法
extension LyricsService {
    /// 将 Whisper 的词序列拆分为单字
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
    
    /// 判断字符是否为标点符号（不需要高亮）
    private func isPunctuation(_ char: String) -> Bool {
        let punctuationSet = CharacterSet.punctuationCharacters
        return char.unicodeScalars.allSatisfy { punctuationSet.contains($0) }
    }
    
    /// 缓存 Whisper 转写结果
    private func cacheWhisperLyrics(_ wordLyrics2D: [[WordLyrics]], for songId: String) {
        if let data = try? JSONEncoder().encode(wordLyrics2D) {
            UserDefaults.standard.set(data, forKey: "whisper_wordLyrics_\(songId)")
        }
    }
    
    private func loadCachedWhisperLyrics(for songId: String) -> [[WordLyrics]]? {
        guard let data = UserDefaults.standard.data(forKey: "whisper_wordLyrics_\(songId)") else { return nil }
        return try? JSONDecoder().decode([[WordLyrics]].self, from: data)
    }
    
    
    func applyImmediateAlignment(currentPlaybackTime: TimeInterval) {
        // ✅ 单一锚点：只使用第一句歌词的开始时间作为对齐基准
        guard let firstLine = wordLyrics.first, let firstWord = firstLine.first else {
            lyricOffset = 0
            return
        }
        
        // 如果当前播放时间小于第一词开始时间（前奏阶段），偏移量为0
        if currentPlaybackTime < firstWord.startTime {
            lyricOffset = 0
            print("🎯 对齐：前奏阶段，偏移量 = 0")
            return
        }
        
        // 计算偏移：当前播放时间 - 第一词开始时间
        let rawOffset = currentPlaybackTime - firstWord.startTime
        
        // 限制偏移范围：±8 秒，覆盖绝大多数误差
        let maxOffset: TimeInterval = 8.0
        lyricOffset = max(-maxOffset, min(maxOffset, rawOffset))
        
        print("🎯 对齐完成：当前播放时间 \(currentPlaybackTime)，第一词开始 \(firstWord.startTime)，偏移量 = \(lyricOffset)")
    }
    
    private func applyWordLyricsIfChanged(_ newValue: [[WordLyrics]]) {
        let oldIds = wordLyrics.flatMap { $0.map(\.id) }
        let newIds = newValue.flatMap { $0.map(\.id) }
        guard oldIds != newIds else { return }
        wordLyrics = newValue
    }
    
    private func applyLyricsIfChanged(_ newValue: [LyricLine]) {
        let oldTexts = lyrics.map { $0.text }
        let newTexts = newValue.map { $0.text }
        guard oldTexts != newTexts else { return }
        lyrics = newValue
    }
}

// 放在 LyricsService.swift 文件的底部，类定义之外
extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
        (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) ||
        (scalar.value >= 0x20000 && scalar.value <= 0x2A6DF) ||
        (scalar.value >= 0xF900 && scalar.value <= 0xFAFF)
    }
    
    var isEnglishOrDigit: Bool {
        return ("a"..."z").contains(self) || ("A"..."Z").contains(self) || ("0"..."9").contains(self)
    }
}


// MARK: - 修复英文歌曲逐字歌词（静默修复）

extension LyricsService {
    
    /// 检测逐字歌词数据是否有效（至少有一半的字符有时间戳）
    private func isWordLyricsValid(_ wordLyrics2D: [[WordLyrics]]) -> Bool {
        let allWords = wordLyrics2D.flatMap { $0 }
        let nonPlaceholder = allWords.filter { $0.startTime > 0 || $0.endTime > 0 }
        return nonPlaceholder.count > allWords.count / 3
    }
    
    
    /// 应用逐字歌词到 UI 状态
    private func applyWordLyrics(_ wordLyrics2D: [[WordLyrics]], songId: String) {
        //        self.wordLyrics = wordLyrics2D
        applyWordLyricsIfChanged(wordLyrics2D)
        self.precomputeProgressMetadata()   // ✅ 新增
        
        self.lyrics = wordLyrics2D.enumerated().map { index, words in
            let lineText = words.map { $0.word }.joined()
            let startTime = words.first?.startTime ?? 0
            let endTime = words.last?.endTime ?? (index + 1 < wordLyrics2D.count ? wordLyrics2D[index+1].first?.startTime : nil)
            return LyricLine(startTime: startTime, endTime: endTime, text: lineText, words: words)
        }
        self.isLoading = false
        self.currentLoadingSongId = nil
        self.updateCurrentIndex(with: self.currentPlaybackTime)
        self.objectWillChange.send()
    }
}
