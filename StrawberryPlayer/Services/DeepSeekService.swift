import Foundation

enum DeepSeekError: Error, LocalizedError {
    case invalidURL
    case noAPIKey
    case requestFailed(Error)
    case invalidResponse
    case decodingError(Error)
    case apiError(statusCode: Int, message: String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .noAPIKey: return "DeepSeek API Key 未配置"
        case .requestFailed(let error): return "请求失败: \(error.localizedDescription)"
        case .invalidResponse: return "无效的响应"
        case .decodingError(let error): return "数据解析失败: \(error.localizedDescription)"
        case .apiError(let code, let message): return "DeepSeek API 错误 (\(code)): \(message)"
        }
    }
}

class DeepSeekService {
    static let shared = DeepSeekService()
    
    private let apiKey: String
    private let baseURL = "https://api.deepseek.com/v1/chat/completions"
    
    private init() {
        // 临时调试：直接打印 Info.plist 里的值
        let value = Bundle.main.object(forInfoDictionaryKey: "DEEPSEEK_API_KEY")
        debugLog("原始读取到的值: \(value ?? "nil")，类型: \(type(of: value))")
        
        guard let key = value as? String, !key.isEmpty else {
            fatalError("DEEPSEEK_API_KEY not found in Info.plist or is empty")
        }
        self.apiKey = key
        debugLog("✅ DeepSeek API Key loaded")
    }
    
    private func cleanGeneratedLyrics(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // 跳过纯标记行（完整或未闭合的方括号/圆括号标记）
            if isPureMarkerLine(trimmed) {
                continue
            }
            
            // 跳过空行（后续会统一压缩）
            if trimmed.isEmpty {
                continue
            }
            
            cleanedLines.append(line)
        }
        
        // 将有效行重新组合，并压缩连续的空行为单个空行
        var result = cleanedLines.joined(separator: "\n")
        result = result.replacingOccurrences(of: "\n\\s*\n", with: "\n", options: .regularExpression)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 判断一行是否为纯标记行（支持完整或未闭合的括号标记）
    private func isPureMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        
        // 完整方括号标记 [xxx]
        let fullBracket = "^\\[[^\\]]+\\]$"
        if let _ = trimmed.range(of: fullBracket, options: .regularExpression) {
            return true
        }
        
        // 未闭合方括号标记 [xxx（缺少右括号）
        let unclosedBracket = "^\\[[^\\]]+$"
        if let _ = trimmed.range(of: unclosedBracket, options: .regularExpression) {
            return true
        }
        
        // 完整圆括号标记 (xxx)
        let fullParen = "^\\([^\\)]+\\)$"
        if let _ = trimmed.range(of: fullParen, options: .regularExpression) {
            return true
        }
        
        // 未闭合圆括号标记 (xxx（缺少右括号）
        let unclosedParen = "^\\([^\\)]+$"
        if let _ = trimmed.range(of: unclosedParen, options: .regularExpression) {
            return true
        }
        
        return false
    }
    
    /// 调用 DeepSeek 生成或优化歌词（专注生成，不使用推理模型）
    func generateLyrics(prompt: String, temperature: Double = 0.65, maxTokens: Int = 8000) async throws -> (title: String, lyrics: String) {
        guard let url = URL(string: baseURL) else {
            throw DeepSeekError.invalidURL
        }

        let systemPrompt = """
        你是一位世界级作词大师，精通国语、粤语、英语等多种语言，并能精准模仿任何指定歌手的风格。
        你善于用具体意象代替空泛抒情，掌握各类押韵模式和音节控制，让歌词兼具文学性与传唱度。
        请完全遵循用户提供的风格约束进行创作，不要擅自偏离。
        """

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": prompt]
        ]

        // 仅使用生成模型，避免推理链占用 token
        let model = "deepseek-v4-flash"
        
        var currentTokens = maxTokens   // 用局部变量，可修改

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": currentTokens,
            "temperature": temperature,
            "top_p": 0.95
        ]

        // 自定义 URLSession：120 秒超时
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 120
        sessionConfig.timeoutIntervalForResource = 120
        let customSession = URLSession(configuration: sessionConfig)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 重试一次处理超时
        for attempt in 0...1 {
            do {
                let (data, response) = try await customSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw DeepSeekError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    struct DeepSeekResponse: Decodable {
                        let choices: [Choice]
                        struct Choice: Decodable {
                            let message: Message
                            struct Message: Decodable {
                                let content: String
                            }
                        }
                    }
                    let result = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
                    if let fullContent = result.choices.first?.message.content, !fullContent.isEmpty {
                        let (title, rawLyrics) = parseTitleAndLyrics(from: fullContent)
                        let cleanedLyrics = cleanGeneratedLyrics(rawLyrics)
                        return (title, cleanedLyrics)
                    } else {
                        // 内容为空，可能是 token 不足，增加后重试
                        if attempt == 0 {
                            currentTokens = 8000
                            body["max_tokens"] = currentTokens
                            request.httpBody = try JSONSerialization.data(withJSONObject: body)
                            continue
                        }
                        throw DeepSeekError.decodingError(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "响应内容为空"]))
                    }
                } else {
                    let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "未知错误"
                    throw DeepSeekError.apiError(statusCode: httpResponse.statusCode, message: errorMsg)
                }
            } catch {
                if (error as NSError).code == -1001 && attempt == 0 {
                    debugLog("⏱️ 请求超时，正在重试...")
                    continue
                }
                throw error
            }
        }

        throw DeepSeekError.apiError(statusCode: -1, message: "生成失败，请重试")
    }
        
    /// 解析返回的完整文本，提取歌名和歌词
    private func parseTitleAndLyrics(from fullContent: String) -> (title: String, lyrics: String) {
        let lines = fullContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        // 默认值
        var title = "未知歌名"
        var lyrics = fullContent
        
        // 尝试从第一行提取歌名，支持多种格式
        if let firstLine = lines.first {
            // 格式：【歌名】
            if firstLine.hasPrefix("【") && firstLine.hasSuffix("】") {
                let rawTitle = String(firstLine.dropFirst().dropLast())
                let invalidTitles = ["song title", "歌名", "title", "song name"]
                if invalidTitles.contains(rawTitle.lowercased()) {
                    // 如果包含无效占位符，尝试从行中提取实际歌名
                    let remaining = firstLine.replacingOccurrences(of: "【Song Title】", with: "")
                        .replacingOccurrences(of: "【song title】", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !remaining.isEmpty {
                        title = remaining
                    } else {
                        // 若无剩余文本，则从后续行中寻找第一个非空有效行作为歌名
                        for nextLine in lines.dropFirst() {
                            let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty && !trimmed.hasPrefix("【") && !trimmed.hasSuffix("】") {
                                title = trimmed
                                break
                            }
                        }
                    }
                } else {
                    title = rawTitle
                }
                lyrics = lines.dropFirst().joined(separator: "\n")
            }
            
            // 格式：# 歌名
            else if firstLine.hasPrefix("# ") {
                title = String(firstLine.dropFirst(2))
                lyrics = lines.dropFirst().joined(separator: "\n")
            }
            // 格式：《歌名》
            else if firstLine.hasPrefix("《") && firstLine.hasSuffix("》") {
                title = String(firstLine.dropFirst().dropLast())
                lyrics = lines.dropFirst().joined(separator: "\n")
            }
            // 其他情况：将第一行作为标题，剩余部分作为歌词
            else {
                title = firstLine
                lyrics = lines.dropFirst().joined(separator: "\n")
            }
        }
        
        return (title, lyrics)
    }
}
