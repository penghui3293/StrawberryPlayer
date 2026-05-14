

import Foundation

enum LyricsError: Error {
    case noLyrics
    case networkError(Error)
    case invalidURL
    case noData
    case parseError(Error)
}

class LyricsDownloadService {
    static let shared = LyricsDownloadService()
    
    // 简单内存缓存，记录已尝试过的歌曲（无歌词的）
    private var noLyricsCache = Set<String>()
    private let cacheQueue = DispatchQueue(label: "lyrics.cache.queue")
    
    private func cleanSearchTerm(_ term: String) -> String {
        // 移除开头的数字和点号（如 "12."、"01."）
        var cleaned = term.replacingOccurrences(of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
        // 移除常见标点符号
        cleaned = cleaned.replacingOccurrences(of: "[：、，。？！“”()（）]", with: "", options: .regularExpression)
        // 去除多余空格
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // 移除括号内容（如 (Live), (Remix) 等）
        cleaned = cleaned.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        return cleaned
    }
    
    // 在 LyricsDownloadService 中添加
    func fetchLyricsAsync(for song: Song) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.fetchLyrics(for: song) { result in
                switch result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func fetchLyrics(for song: Song, completion: @escaping (Result<String, Error>) -> Void) {
//        let cacheKey = song.url.absoluteString
        let cacheKey = song.id
        cacheQueue.sync {
            if noLyricsCache.contains(cacheKey) {
                completion(.failure(LyricsError.noLyrics))
                return
            }
        }
        
        // 1. 去除文件扩展名
        let titleWithoutExt = removeAudioExtension(from: song.title)
        let cleanTitle = cleanSearchTerm(titleWithoutExt)
        
        // 2. 判断艺术家是否有效
        let artist = song.artist
        let useArtist = !artist.isEmpty && artist.lowercased() != "unknown artist"
        let cleanArtist = useArtist ? cleanSearchTerm(artist) : nil
        
        // 3. 构建查询策略数组（按优先级排序）
        var queries: [String] = []
        
        // 策略1：标题 + 艺术家（如果有）
        if let artist = cleanArtist {
            queries.append("\(cleanTitle) \(artist)")
        }
        // 策略2：仅标题
        queries.append(cleanTitle)
        // 策略3：仅艺术家（如果有且标题可能不准确）
        if let artist = cleanArtist, artist != cleanTitle {
            queries.append(artist)
        }
        
        performSearchWithStrategies(queries: queries, artistHint: cleanArtist, retryCount: 2) { [weak self] result in
            switch result {
            case .success(let lyrics):
                completion(.success(lyrics))
            case .failure(let error):
                // 记录无歌词的歌曲到缓存
                self?.cacheQueue.async {
                    self?.noLyricsCache.insert(cacheKey)
                }
                completion(.failure(error))
            }
        }
    }
    
    /// 按策略顺序搜索，支持重试
    private func performSearchWithStrategies(queries: [String], artistHint: String?, retryCount: Int, completion: @escaping (Result<String, Error>) -> Void) {
        var queryIndex = 0
        var currentRetry = 0
        
        func attempt() {
            guard queryIndex < queries.count else {
                completion(.failure(LyricsError.noLyrics))
                return
            }
            
            let query = queries[queryIndex]
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "https://lrclib.net/api/search?q=\(encodedQuery)"
            guard let url = URL(string: urlString) else {
                completion(.failure(LyricsError.invalidURL))
                return
            }
            
            debugLog("🔍 搜索 URL: \(urlString)")
            
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    if currentRetry < retryCount {
                        currentRetry += 1
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            attempt()
                        }
                    } else {
                        // 当前策略重试耗尽，切换到下一个策略
                        queryIndex += 1
                        currentRetry = 0
                        attempt()
                    }
                    return
                }
                
                guard let data = data else {
                    completion(.failure(LyricsError.noData))
                    return
                }
                
                do {
                    if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !jsonArray.isEmpty {
                        // 在结果中寻找最佳匹配
                        let bestMatch = self.findBestMatch(in: jsonArray, artistHint: artistHint)
                        if let lyrics = bestMatch {
                            completion(.success(lyrics))
                        } else {
                            // 当前策略无匹配，尝试下一个策略
                            queryIndex += 1
                            currentRetry = 0
                            attempt()
                        }
                    } else {
                        // 空结果，尝试下一个策略
                        queryIndex += 1
                        currentRetry = 0
                        attempt()
                    }
                } catch {
                    completion(.failure(LyricsError.parseError(error)))
                }
            }
            task.resume()
        }
        
        attempt()
    }
    
    /// 在结果数组中寻找最佳匹配的歌词，优先同步歌词，并考虑艺术家相似度
    private func findBestMatch(in results: [[String: Any]], artistHint: String?) -> String? {
        var bestSync: (lyrics: String, score: Int)? = nil
        var bestPlain: String? = nil
        
        for item in results {
            // 同步歌词
            if let synced = item["syncedLyrics"] as? String, !synced.isEmpty {
                var score = 0
                if let hint = artistHint, !hint.isEmpty,
                   let artist = item["artistName"] as? String {
                    // 简单的包含判断（可改进为相似度算法）
                    if artist.lowercased().contains(hint.lowercased()) {
                        score += 2
                    }
                }
                // 标题匹配加分（可选）
                if let title = item["trackName"] as? String,
                   let hintTitle = artistHint ?? nil { // 这里简化为不处理标题匹配
                    // 暂不实现
                }
                if bestSync == nil || score > bestSync!.score {
                    bestSync = (synced, score)
                }
            }
            // 纯文本歌词作为后备
            if let plain = item["plainLyrics"] as? String, !plain.isEmpty, bestPlain == nil {
                bestPlain = plain
            }
        }
        
        return bestSync?.lyrics ?? bestPlain
    }
    
    /// 移除常见音频文件扩展名
    private func removeAudioExtension(from filename: String) -> String {
        let extensions = ["flac", "mp3", "wav", "m4a", "aac", "ogg"]
        let lowercased = filename.lowercased()
        for ext in extensions {
            if lowercased.hasSuffix(".\(ext)") {
                return String(filename.dropLast(ext.count + 1))
            }
        }
        return filename
    }
}
