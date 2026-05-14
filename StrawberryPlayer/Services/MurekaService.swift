
//
//  MurekaService.swift
//  StrawberryPlayer
//  Mureka AI 音乐生成服务
//

import Foundation

// MARK: - 扩展和响应结构
extension MurekaService {
    struct ExtendLyricsResponse: Decodable {
        let lyrics: String
    }
    
    struct ContinueSongResponse: Decodable {
        let id: String
        let status: String
    }
}

struct GenerateResponse: Decodable {
    let taskId: String
}

// MARK: - 错误枚举
enum MurekaError: Error, LocalizedError {
    case invalidURL
    case noAPIKey
    case authenticationFailed
    case rateLimitExceeded
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case networkError(Error)
    case taskFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 URL"
        case .noAPIKey:
            return "API Key 未配置"
        case .authenticationFailed:
            return "认证失败，请检查 API Key"
        case .rateLimitExceeded:
            return "超出调用频率限制"
        case .serverError(let code, let message):
            return "服务器错误 (\(code)): \(message ?? "未知错误")"
        case .decodingError(let error):
            return "数据解析失败: \(error.localizedDescription)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .taskFailed(let reason):
            return "生成任务失败: \(reason)"
        }
    }
}

// MARK: - 辅助扩展
extension MurekaService.Choice {
    func wordLyricsJSONString() -> String? {
        guard let sections = lyrics_sections else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(sections) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - API 响应模型
extension MurekaService {
    struct GenerationResult: Decodable {
        let id: String
        let status: String
        let choices: [Choice]?
        let error: TaskError?
        let trace_id: String?
        let watermarked: Bool?
        let createdAt: Int?
        let finishedAt: Int?
        
        enum CodingKeys: String, CodingKey {
            case id
            case status
            case choices
            case error
            case trace_id
            case watermarked
            case createdAt = "created_at"
            case finishedAt = "finished_at"
        }
    }
    
    struct Choice: Decodable {
        let id: String?          // 用于存储歌曲真实ID
        let url: String
        let flac_url: String?
        let wav_url: String?
        let duration: Int?          // 毫秒
        let lyrics_sections: [LyricsSection]?
    }
    
    // 在 MurekaService 的扩展中找到这些结构体定义，修改为：
    struct LyricsSection: Codable {
        let section_type: String
        let start: Int?      // 改为可选
        let end: Int?        // 改为可选
        let lines: [LyricLine]?
    }
    
    struct LyricLine: Codable {
        let start: Int?      // 改为可选
        let end: Int?        // 改为可选
        let text: String
        let words: [Word]?
    }
    
        
    struct Word: Codable {
        let start: Int
        let end: Int
        let text: String
    }
    
    struct TaskError: Decodable {
        let message: String
        let code: Int?
    }
}

extension MurekaService.Choice {
    /// 将歌词部分转换为 LRC 格式字符串
    func lyricsToLrc() -> String? {
        guard let sections = lyrics_sections else { return nil }
        var lrcLines = [String]()
        for section in sections {
            for line in section.lines ?? [] {
                // 如果有 start 值，则使用；否则跳过该行或使用默认时间 0
                if let start = line.start {
                    let minutes = start / 60000
                    let seconds = (start % 60000) / 1000
                    let hundredths = (start % 1000) / 10
                    let timestamp = String(format: "[%02d:%02d.%02d]", minutes, seconds, hundredths)
                    lrcLines.append("\(timestamp)\(line.text)")
                } else {
                    // 对于没有时间的行，可以选择不生成，或放在开头（这里放在开头）
                    lrcLines.append("[00:00.00]\(line.text)")
                }
            }
        }
        return lrcLines.joined(separator: "\n")
    }
    
}

// MARK: - 数据模型 MurekaSong
struct MurekaSong: Codable, Identifiable {
    let id: String           // 任务ID
    let realId: String?      // 实际歌曲ID（从 choices[0].id 获取）
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let audioUrl: URL?
    let coverUrl: URL?
    let lyrics: String?
    let wordLyrics: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case duration
        case audioUrl = "audioUrl"
        case coverUrl = "coverUrl"
        case lyrics
        case wordLyrics
    }
    
    init(id: String, realId: String? = nil, title: String?, artist: String?, album: String?, duration: TimeInterval?, audioUrl: URL?, coverUrl: URL?, lyrics: String?, wordLyrics: String?) {
        self.id = id
        self.realId = realId
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.audioUrl = audioUrl
        self.coverUrl = coverUrl
        self.lyrics = lyrics
        self.wordLyrics = wordLyrics
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        
        if let audioUrlString = try container.decodeIfPresent(String.self, forKey: .audioUrl) {
            audioUrl = URL(string: audioUrlString)
        } else {
            audioUrl = nil
        }
        
        if let coverUrlString = try container.decodeIfPresent(String.self, forKey: .coverUrl) {
            coverUrl = URL(string: coverUrlString)
        } else {
            coverUrl = nil
        }
        
        lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)
        wordLyrics = try container.decodeIfPresent(String.self, forKey: .wordLyrics)
        realId = nil
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(audioUrl?.absoluteString, forKey: .audioUrl)
        try container.encodeIfPresent(coverUrl?.absoluteString, forKey: .coverUrl)
        try container.encodeIfPresent(wordLyrics, forKey: .wordLyrics)
    }
}

/// 歌曲生成任务响应
struct GenerateTaskResponse: Decodable {
    let id: String
    let createdAt: Int
    let model: String
    let status: String
    let traceId: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case model
        case status
        case traceId = "trace_id"
    }
}

// MARK: - 主服务类
class MurekaService {
    static let shared = MurekaService()
    
    private let apiKey: String
    private let baseURL = "https://api.mureka.cn/v1"
    
    private init() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "MurekaAPIKey") as? String,
              !key.isEmpty else {
            fatalError("MurekaAPIKey not found in Info.plist or is empty")
        }
        self.apiKey = key
        debugLog("✅ Mureka API Key loaded, prefix: \(key.prefix(10))")
    }
    
    // MARK: - 网络请求核心
    private func makeRequest(endpoint: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: baseURL + endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // 增加超时时间
        request.httpBody = body
        return request
    }
    
    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MurekaError.serverError(statusCode: -1, message: "无效的响应")
            }
            
#if DEBUG
            if let responseStr = String(data: data, encoding: .utf8) {
                debugLog("📥 Mureka 响应 [\(httpResponse.statusCode)]: \(responseStr)")
            }
#endif
            
            switch httpResponse.statusCode {
            case 200...299:
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    if let jsonString = String(data: data, encoding: .utf8) {
                        debugLog("❌ JSON decode error: \(error)")
                        debugLog("📦 原始 JSON: \(jsonString)")
                    }
                    throw MurekaError.decodingError(error)
                }
            case 401:
                throw MurekaError.authenticationFailed
            case 429:
                throw MurekaError.rateLimitExceeded
            default:
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = errorJson["error"] as? String ?? (errorJson["message"] as? String) {
                    throw MurekaError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
                } else {
                    throw MurekaError.serverError(statusCode: httpResponse.statusCode, message: nil)
                }
            }
        } catch let error as MurekaError {
            throw error
        } catch {
            throw MurekaError.networkError(error)
        }
    }
    
    // MARK: - 公开 API
    func fetchRecommendedSongs() async throws -> [MurekaSong] {
        return []
    }
    
    // 修改 generateSong 方法签名，增加 audioFormat 参数（默认 nil，保持原行为）
    func generateSong(lyrics: String,
                      prompt: String,
                      voiceModelId: String? = nil,
                      model: String,
                      needWordLyrics: Bool = false,
                      temperature: Double? = nil,
                      topP: Double? = nil,
                      duration: TimeInterval? = nil,
                      referenceAudioURL: URL? = nil,
                      audioFormat: String? = nil) async throws -> String {   // 新增参数
        
        let endpoint = "/song/generate"
        var body: [String: Any] = [
            "lyrics": lyrics,
            "prompt": prompt,
            "need_word_lyrics": needWordLyrics,
            "model": model
        ]
        if let voiceModelId = voiceModelId {
            body["voice_model_id"] = voiceModelId
        }
        if let temperature = temperature {
            body["temperature"] = temperature
        }
        if let topP = topP {
            body["top_p"] = topP
        }
        if let duration = duration {
            body["duration"] = Int(duration)
        }
        if let referenceAudioURL = referenceAudioURL {
            body["reference_audio"] = referenceAudioURL.absoluteString
        }
        // 新增：指定音频格式
        if let format = audioFormat {
            body["audio_setting"] = ["format": format]
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let request = makeRequest(endpoint: endpoint, method: "POST", body: jsonData) else {
            throw MurekaError.invalidURL
        }
        
        let response: GenerateTaskResponse = try await performRequest(request)
        return response.id
    }

    /// 续写歌曲（按官方 API 要求）
    func continueSong(originalSongId: String, extendAtMs: Int, lyrics: String) async throws -> String {
        let endpoint = "/song/extend"
        let body: [String: Any] = [
            "song_id": originalSongId,
            "extend_at": extendAtMs,
            "lyrics": lyrics
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let request = makeRequest(endpoint: endpoint, method: "POST", body: jsonData) else {
            throw MurekaError.invalidURL
        }
#if DEBUG
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            debugLog("📤 续写请求体: \(jsonString)")
        }
#endif
        let response: GenerateTaskResponse = try await performRequest(request)
        return response.id
    }
    
    func queryTask(taskId: String) async throws -> MurekaService.GenerationResult {
        let endpoint = "/song/query/\(taskId)"
        guard let request = makeRequest(endpoint: endpoint) else {
            throw MurekaError.invalidURL
        }
        if let url = request.url {
            debugLog("🔍 查询任务 URL: \(url.absoluteString)")
        }
        return try await performRequest(request)
    }
    
    // MARK: - 等待任务完成（已修复 reviewing 状态问题）
    func waitForTaskCompletion(taskId: String,
                               maxAttempts: Int = 120,               // 保持总时长约 4 分钟（120 * 2s）
                               delaySeconds: UInt64 = 2
    ) async throws -> MurekaSong {
        var currentDelay = delaySeconds
            let maxDelay: UInt64 = 8              // 最大间隔 8 秒，避免过于频繁
        for attempt in 1...maxAttempts {
            // ✅ 检查任务是否已被取消
            try Task.checkCancellation()
            
            // ✅ 在后台队列执行网络请求，绝不阻塞主线程
                   let result: MurekaService.GenerationResult = try await withCheckedThrowingContinuation { continuation in
                       DispatchQueue.global(qos: .utility).async {
                           Task {
                               do {
                                   let res = try await self.queryTask(taskId: taskId)
                                   continuation.resume(returning: res)
                               } catch {
                                   continuation.resume(throwing: error)
                               }
                           }
                       }
                   }
            
            // 判断任务是否已完成（succeeded/completed）或者 reviewing 但已有有效数据
            let isSuccess = result.status == "succeeded" || result.status == "completed"
            let isReviewingWithData = (result.status == "reviewing" || result.status == "processing") && (result.choices?.isEmpty == false)
            
            if isSuccess || isReviewingWithData {
                guard let choices = result.choices, let firstChoice = choices.first else {
                    throw MurekaError.taskFailed(reason: "任务完成但缺少音频数据")
                }

                // 优先使用 wav_url，如果不存在则使用 url
                let audioUrlString = firstChoice.wav_url ?? firstChoice.url
                guard let audioUrl = URL(string: audioUrlString) else {
                    throw MurekaError.taskFailed(reason: "任务完成但音频 URL 无效")
                }
                
                let duration = TimeInterval(firstChoice.duration ?? 0) / 1000.0
                let lrcString = firstChoice.lyricsToLrc()
                let wordLyricsJSON = firstChoice.wordLyricsJSONString()
                let songRealId = firstChoice.id
                
                return MurekaSong(
                    id: taskId,
                    realId: songRealId,
                    title: "AI 生成音乐",
                    artist: "Mureka AI",
                    album: "AI 音乐集",
                    duration: duration,
                    audioUrl: audioUrl,
                    coverUrl: nil,
                    lyrics: lrcString,
                    wordLyrics: wordLyricsJSON
                )
            }
            
            if result.status == "failed" {
                let reason = result.error?.message ?? "未知错误"
                throw MurekaError.taskFailed(reason: reason)
            }
            
            debugLog("⏳ 任务状态: \(result.status)，等待中 (\(attempt)/\(maxAttempts))")
            
            // ✅ 指数退避：逐渐延长等待间隔
            try await Task.sleep(nanoseconds: currentDelay * 1_000_000_000)
            currentDelay = min(currentDelay * 2, maxDelay)

        }
        throw MurekaError.taskFailed(reason: "任务处理超时")
    }
    
    func generateInstrumental(prompt: String) async throws -> String {
        let endpoint = "/instrumental/generate"
        let body: [String: Any] = [
            "prompt": prompt,
            "model": "auto"
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let request = makeRequest(endpoint: endpoint, method: "POST", body: jsonData) else {
            throw MurekaError.invalidURL
        }
        let response: GenerateTaskResponse = try await performRequest(request)
        return response.id
    }
    
    
    // MARK: - 文件上传和声音克隆
    
    func uploadFile(audioFile: URL, purpose: String = "voice") async throws -> String {
        guard let url = URL(string: baseURL + "/files/upload") else {
            throw MurekaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // 添加 purpose 字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(purpose)\r\n".data(using: .utf8)!)
        
        // 添加文件字段
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFile.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        
        let audioData = try Data(contentsOf: audioFile)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        // 发送请求并处理响应（保持不变）
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MurekaError.serverError(statusCode: -1, message: "无效响应")
        }
        
        // 打印响应体以便调试
        if let responseString = String(data: data, encoding: .utf8) {
            debugLog("📥 uploadFile 响应 (\(httpResponse.statusCode)): \(responseString)")
        }
        
        guard httpResponse.statusCode == 200 else {
            // 尝试解析错误信息
            var errorMsg = "文件上传失败"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                errorMsg = message
            } else if let errorStr = String(data: data, encoding: .utf8) {
                errorMsg = errorStr
            }
            throw MurekaError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
        }
        
        struct UploadResponse: Decodable {
            let id: String
        }
        let result = try JSONDecoder().decode(UploadResponse.self, from: data)
        return result.id
    }
    
    
    /// 创建声音模型，返回voice_id
    func createVoice(fileId: String, name: String, model: String = "mureka-8") async throws -> String {
        guard let url = URL(string: baseURL + "/tts/generate") else {
            throw MurekaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "file_id": fileId,
            "name": name,
            "model": model  // 添加 model 参数
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MurekaError.serverError(statusCode: -1, message: "无效响应")
        }
        
        // 打印响应体以便调试
        if let responseString = String(data: data, encoding: .utf8) {
            debugLog("📥 createVoice 响应 (\(httpResponse.statusCode)): \(responseString)")
        }
        
        guard httpResponse.statusCode == 200 else {
            var errorMsg = "创建声音失败"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                errorMsg = message
            } else if let errorStr = String(data: data, encoding: .utf8) {
                errorMsg = errorStr
            }
            throw MurekaError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
        }
        
        struct VoiceResponse: Decodable {
            let id: String
        }
        let result = try JSONDecoder().decode(VoiceResponse.self, from: data)
        return result.id
    }
    
    
    
    /// 一键克隆声音（上传+创建）
    func cloneVoice(audioFile: URL, name: String = "克隆声音") async throws -> String {
        let fileId = try await uploadFile(audioFile: audioFile)
        // 等待一秒让服务器处理文件
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        //        let voiceId = try await createVoice(fileId: fileId, name: name)
        return fileId
    }
    
    
    // MARK: - 歌词生成 API
    
    /// 生成歌词
    func generateLyrics(prompt: String) async throws -> (title: String, lyrics: String) {
        let endpoint = "/lyrics/generate"
        let body: [String: Any] = ["prompt": prompt]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let request = makeRequest(endpoint: endpoint, method: "POST", body: jsonData) else {
            throw MurekaError.invalidURL
        }
        
        struct LyricsGenerateResponse: Decodable {
            let title: String
            let lyrics: String
        }
        
        let response: LyricsGenerateResponse = try await performRequest(request)
        return (response.title, response.lyrics)
    }
    
    /// 扩展歌词
    func extendLyrics(originalLyrics: String) async throws -> String {
        let endpoint = "/lyrics/extend"
        let body: [String: Any] = ["lyrics": originalLyrics]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let request = makeRequest(endpoint: endpoint, method: "POST", body: jsonData) else {
            throw MurekaError.invalidURL
        }
        
        struct ExtendLyricsResponse: Decodable {
            let lyrics: String
        }
        
        let response: ExtendLyricsResponse = try await performRequest(request)
        return response.lyrics
    }
    
}
