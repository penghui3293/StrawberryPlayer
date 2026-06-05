import Foundation
import UIKit
import Combine
import AVFoundation

struct CoverOptionsResponse: Decodable {
    let coverURLs: [String]
}

@MainActor
class VirtualArtistService: ObservableObject {
    
    weak var userService: UserService?
    
    static let shared = VirtualArtistService()
    
    private var baseURL: String {
        AppConfig.baseURL + "/api"
    }
    
    @Published var myArtists: [VirtualArtist] = []
    @Published var followedArtists: [VirtualArtist] = []
    @Published var trendingArtists: [VirtualArtist] = []
    @Published var generationProgress: String = ""
    
    private var currentGenerationTask: Task<Void, Never>?   // ✅ 新增
    
    // MARK: - 辅助方法：构建基础请求
    private func makeRequest(path: String, method: String = "GET", token: String? = nil, body: Data? = nil, boundary: String? = nil) -> URLRequest {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if let boundary = boundary {
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        } else if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        request.httpBody = body
        return request
    }
    
    // MARK: - 创建艺人（带头像上传）
    func createArtist(name: String, avatarImage: UIImage?, bio: String, genre: String,language: String?,  token: String, voiceModelId: String? = nil, completion: @escaping (Result<VirtualArtist, Error>) -> Void) {
        let url = URL(string: baseURL + "/artists")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        var params: [String: String] = [
            "name": name,
            "genre": genre,
            "bio": bio,
            "voiceModelId": voiceModelId ?? ""
        ]
        
        if let language = language, !language.isEmpty {
            params["language"] = language
        }
        
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        if let image = avatarImage, let imageData = image.jpegData(compressionQuality: 0.8) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
                    return
                }
                
                if let jsonString = String(data: data, encoding: .utf8) {
                    debugLog("📥 创建艺人返回 JSON: \(jsonString)")
                }
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let errorMsg: String
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let reason = json["reason"] as? String {
                        errorMsg = reason
                    } else {
                        errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
                    }
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    completion(.failure(NSError(domain: "ServerError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                    return
                }
                
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let artist = try decoder.decode(VirtualArtist.self, from: data)
                    self.getMyArtists(token: token) { result in
                        switch result {
                        case .success:
                            completion(.success(artist))
                        case .failure(let error):
                            debugLog("刷新艺人列表失败: \(error)")
                            completion(.success(artist))
                        }
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    func uploadSong(title: String, artist: String, style: String, audioFile: URL, virtualArtistId: UUID? = nil, token: String, completion: @escaping (Result<Song, Error>) -> Void) {
        let url = URL(string: baseURL + "/songs/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        let asset = AVAsset(url: audioFile)
        let duration = CMTimeGetSeconds(asset.duration)
        
        let params: [String: String] = [
            "title": title,
            "artist": artist,
            "style": style,
            "duration": "\(duration)"
        ]
        if let virtualArtistId = virtualArtistId {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"virtual_artist_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(virtualArtistId.uuidString)\r\n".data(using: .utf8)!)
        }
        
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        
        do {
            let audioData = try Data(contentsOf: audioFile)
            let fileName = audioFile.lastPathComponent
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n".data(using: .utf8)!)
        } catch {
            completion(.failure(error))
            return
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse {
                    debugLog("📥 上传歌曲状态码: \(httpResponse.statusCode)")
                }
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
                    return
                }
                if let jsonString = String(data: data, encoding: .utf8) {
                    debugLog("📦 服务器返回原始 JSON: \(jsonString)")
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let song = try decoder.decode(Song.self, from: data)
                    completion(.success(song))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    func createSong(artistId: UUID? = nil, title: String, artistName: String, style: String, audioFile: URL, coverImage: UIImage? = nil, token: String, completion: @escaping (Result<Song, Error>) -> Void) {
        
        // 添加日志
        print("📤 准备上传歌曲: title=\(title), artist=\(artistName), style=\(style)")
        print("📁 音频文件路径: \(audioFile.path), 存在: \(FileManager.default.fileExists(atPath: audioFile.path))")
        if let coverImage = coverImage {
            let dataSize = coverImage.jpegData(compressionQuality: 0.8)?.count ?? 0
            print("🖼️ 封面图片大小: \(dataSize) 字节")
        } else {
            print("🖼️ 无封面图片")
        }
        
        let url = URL(string: baseURL + "/songs/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        let asset = AVAsset(url: audioFile)
        let duration = CMTimeGetSeconds(asset.duration)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"title\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(title)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"artist\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(artistName)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"style\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(style)\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"duration\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(duration)\r\n".data(using: .utf8)!)
        
        if let artistId = artistId {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"virtual_artist_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(artistId.uuidString)\r\n".data(using: .utf8)!)
        }
        
        if let coverImage = coverImage, let imageData = coverImage.jpegData(compressionQuality: 0.8) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"cover\"; filename=\"cover.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(imageData)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        do {
            let audioData = try Data(contentsOf: audioFile)
            let fileName = audioFile.lastPathComponent
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n".data(using: .utf8)!)
        } catch {
            completion(.failure(error))
            return
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse {
                    debugLog("📥 上传歌曲状态码: \(httpResponse.statusCode)")
                }
                // ✅ 添加以下日志
                if let httpResponse = response as? HTTPURLResponse {
                    print("🔍 [createSong] 状态码: \(httpResponse.statusCode)")
                }
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("📦 [createSong] 原始响应: \(responseString)")
                } else if let data = data {
                    print("📦 [createSong] 响应数据长度: \(data.count) 字节，无法转为字符串")
                }
                // ✅ 日志结束
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
                    return
                }
                if let jsonString = String(data: data, encoding: .utf8) {
                    debugLog("📦 服务器返回原始 JSON: \(jsonString)")
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let song = try decoder.decode(Song.self, from: data)
                    debugLog("✅ 解析成功: \(song.title)")
                    completion(.success(song))
                } catch {
                    debugLog("❌ 解析失败: \(error)")
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // MARK: - 获取热门艺人（无需 token）
    func fetchTrendingArtists(completion: @escaping (Result<[VirtualArtist], Error>) -> Void) {
        let request = makeRequest(path: "/artists/trending")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let artists = try decoder.decode([VirtualArtist].self, from: data)
                    self.trendingArtists = artists
                    completion(.success(artists))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // MARK: - 获取我创建的艺人（需要 token）
    func getMyArtists(token: String, completion: @escaping (Result<[VirtualArtist], Error>) -> Void) {
        debugLog("🔍 getMyArtists 被调用，userService: \(userService != nil ? "存在" : "nil")")
        
        Task {
            do {
                let artists: [VirtualArtist] = try await performRequestWithAuth(path: "/artists/mine")
                DispatchQueue.main.async {
                    self.myArtists = artists
                    completion(.success(artists))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - 获取艺人详情（无需 token）
    func fetchArtist(id: String, completion: @escaping (Result<VirtualArtist, Error>) -> Void) {
        let request = makeRequest(path: "/artists/\(id)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let artist = try decoder.decode(VirtualArtist.self, from: data)
                    completion(.success(artist))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // MARK: - 获取艺人的歌曲（无需 token）
    func fetchSongs(for artistId: String, completion: @escaping (Result<[Song], Error>) -> Void) {
        let request = makeRequest(path: "/artists/\(artistId)/songs")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let songs = try decoder.decode([Song].self, from: data)
                    completion(.success(songs))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // MARK: - 删除艺人
    func deleteArtist(artistId: UUID, token: String) async throws {
        let path = "/artists/\(artistId)"
        try await performRequestWithAuthNoDecode(path: path, method: "DELETE")
    }
    
    // MARK: - 关注艺人（需要 token）
    func followArtist(artistId: String, token: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await performRequestWithAuthNoDecode(path: "/artists/\(artistId)/follow", method: "POST")
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - 取消关注（需要 token）
    func unfollowArtist(artistId: String, token: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                try await performRequestWithAuthNoDecode(path: "/artists/\(artistId)/follow", method: "DELETE")
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - AI 生成歌曲（关联到艺人）- 修改版，增加 referenceAudioURL 参数
    func generateAISong(
        artist: VirtualArtist,
        songTitle: String,
        album: String,
        lyrics: String,
        prompt: String,
        coverURL: String?,
        token: String,
        temperature: Double? = 0.8,          // 音乐温度（Mureka）
        topP: Double? = 0.95,
        customLyrics: String? = nil,
        customTitle: String? = nil,
        customStylePrompt: String? = nil,
        targetDuration: TimeInterval? = nil,
        lyricsTemperature: Double = 0.8,      // 歌词生成温度
        lyricsMaxTokens: Int = 3000,          // 歌词最大长度
        referenceAudioURL: URL? = nil,        // 新增：参考音轨 URL
        translatedLyrics: String? = nil,   // 新增
        completion: @escaping (Result<Song, Error>) -> Void
    ) {
        // 取消之前的生成任务
        currentGenerationTask?.cancel()
        
        let task = Task {
            do {
                var finalLyrics = lyrics
                var finalTitle = songTitle
                
                if let customLyrics = customLyrics, !customLyrics.isEmpty {
                    finalLyrics = customLyrics
                    debugLog("🎤 使用用户提供的歌词，长度: \(finalLyrics.count)字符")
                } else if finalLyrics.isEmpty {
                    debugLog("🎤 开始生成歌词，prompt: \(prompt)")
                    await MainActor.run {
                        self.generationProgress = "正在生成歌词..."
                    }
                    do {
                        let (generatedTitle, generatedLyrics) = try await DeepSeekService.shared.generateLyrics(
                            prompt: prompt,
                            temperature: lyricsTemperature,
                            maxTokens: lyricsMaxTokens
                        )
                        finalTitle = generatedTitle.isEmpty ? songTitle : generatedTitle
                        finalLyrics = generatedLyrics
                        debugLog("✅ 歌词生成完成，标题: \(finalTitle)")
                        await MainActor.run {
                            self.generationProgress = "歌词已完成，正在合成音乐..."
                        }
                    } catch {
                        debugLog("❌ DeepSeek 歌词生成失败: \(error)")
                        throw error
                    }
                }
                
                if let customTitle = customTitle, !customTitle.isEmpty {
                    finalTitle = customTitle
                    debugLog("🎤 使用用户自定义标题: \(finalTitle)")
                }
                
                debugLog("🎵 使用 Mureka V8 生成歌曲")
                var musicPrompt = customStylePrompt ?? prompt
                
                // 根据艺人语言添加演唱语言指令
                if let language = artist.language, !language.isEmpty {
                    switch language {
                    case "粤语":
                        musicPrompt += " 演唱语言：粤语，必须使用地道粤语发音和词汇，旋律风格参考经典粤语金曲。"
                    case "English":
                        musicPrompt += " Sing in English with clear pronunciation, natural flow, and western pop style."
                    default:
                        musicPrompt += " 演唱语言：国语，发音标准，旋律流畅。"
                    }
                }
                
                debugLog("🎵 发送给 Mureka 的 prompt: \(musicPrompt)")
                debugLog("🎵 发送给 Mureka 的歌词: \(finalLyrics)")
                if let refURL = referenceAudioURL {
                    debugLog("🎵 参考音轨: \(refURL.absoluteString)")
                }
                
                await MainActor.run {
                    self.generationProgress = "正在提交音乐生成任务..."
                }
                
                let taskId = try await MurekaService.shared.generateSong(
                    lyrics: finalLyrics,
                    prompt: musicPrompt,
                    voiceModelId: artist.voiceModelId,
                    model: "mureka-9",
                    needWordLyrics: true,
                    temperature: temperature,
                    topP: topP,
                    duration: targetDuration,
                    referenceAudioURL: referenceAudioURL,
                    audioFormat: "wav"   // 强制返回 WAV 格式
                )
                
                try Task.checkCancellation()
                
                await MainActor.run {
                    self.generationProgress = "AI 正在创作音乐，请耐心等待..."
                }
                
                let generatedSong = try await MurekaService.shared.waitForTaskCompletion(taskId: taskId)
                
                try Task.checkCancellation()
                
                var publishData: [String: Any] = [
                    "title": finalTitle,
                    "artist": artist.name,
                    "album": album.isEmpty ? "单曲" : album,
                    "duration": generatedSong.duration ?? 0,
                    "audio_url": generatedSong.audioUrl?.absoluteString ?? "",
                    "cover_url": generatedSong.coverUrl?.absoluteString ?? "",
                    "lyrics": finalLyrics,
                    "word_lyrics": generatedSong.wordLyrics ?? "",
                    "virtual_artist_id": artist.id,
                    "is_user_generated": true
                ]
                
                if let customCoverURL = coverURL {
                    publishData["cover_url"] = customCoverURL
                }
                
                if let translated = translatedLyrics, !translated.isEmpty {
                    publishData["translated_lyrics"] = translated
                }
                
                await MainActor.run {
                    self.generationProgress = "音乐已生成，正在保存到你的作品库..."
                }
                
                let url = URL(string: baseURL + "/songs/generate_and_link")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 600   // 10 分钟，留足生成 + 转码时间
                request.httpBody = try JSONSerialization.data(withJSONObject: publishData)
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    DispatchQueue.main.async {
                        self.generationProgress = ""
                        if let error = error {
                            completion(.failure(error))
                            return
                        }
                        guard let httpResponse = response as? HTTPURLResponse else {
                            completion(.failure(NSError(domain: "NoResponse", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器无响应"])))
                            return
                        }
                        // ✅ 处理 402 支付错误
                        if httpResponse.statusCode == 402 {
                            let error = NSError(domain: "PaymentRequired", code: 402, userInfo: [NSLocalizedDescriptionKey: "免费次数已用完，请付费解锁更多生成次数"])
                            completion(.failure(error))
                            return
                        }
                        guard httpResponse.statusCode == 200 else {
                            let errorMsg = String(data: data ?? Data(), encoding: .utf8) ?? "生成失败"
                            completion(.failure(NSError(domain: "ServerError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                            return
                        }
                        guard let data = data else {
                            completion(.failure(NSError(domain: "NoData", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器无数据"])))
                            return
                        }
                        if let jsonString = String(data: data, encoding: .utf8) {
                            debugLog("📦 服务器返回原始 JSON: \(jsonString)")
                        }
                        do {
                            let decoder = JSONDecoder()
                            decoder.dateDecodingStrategy = .iso8601
                            let song = try decoder.decode(Song.self, from: data)
                            debugLog("🔊 解析后的歌曲音频 URL: \(String(describing: song.audioURL))")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                completion(.success(song))
                            }
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }.resume()
            } catch {
                await MainActor.run {
                    self.generationProgress = ""
                }
                if Task.isCancelled {
                    debugLog("⏹️ AI 歌曲生成任务已取消")
                } else {
                    
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }
        
        currentGenerationTask = task
        
    }
    
    // 新增取消方法
    func cancelAISongGeneration() {
        currentGenerationTask?.cancel()
        currentGenerationTask = nil
    }
    
    // 异步包装方法
    func createSongAsync(artistId: UUID? = nil, title: String, artistName: String, style: String, audioFile: URL, coverImage: UIImage? = nil, token: String) async throws -> Song {
        return try await withCheckedThrowingContinuation { continuation in
            createSong(
                artistId: artistId,
                title: title,
                artistName: artistName,
                style: style,
                audioFile: audioFile,
                coverImage: coverImage,
                token: token,
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }
    
    func uploadCoverImage(_ image: UIImage, token: String) async throws -> String {
        let url = URL(string: baseURL + "/songs/images")!
        debugLog("🌐 上传封面 URL: \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "ImageError", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法处理图片"])
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"cover\"; filename=\"cover.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseString = String(data: data, encoding: .utf8) ?? "无响应"
            throw NSError(domain: "UploadError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "上传失败: \(responseString)"])
        }
        struct ImageResponse: Decodable {
            let url: String
        }
        let result = try JSONDecoder().decode(ImageResponse.self, from: data)
        return URL(string: result.url)?.path ?? ""
    }
}

extension VirtualArtistService {
    
    func generateCoverOptions(for song: ReferenceSong, count: Int, token: String,gender: String? = nil) async throws -> [URL] {
        guard let url = URL(string: "\(baseURL)/ai/generate-covers") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var parameters: [String: Any] = [
            "songId": song.id,
            "title": song.title,
            "artist": song.artist,
            "coverURL": song.coverURL?.absoluteString ?? "",
            "count": count
        ]
        if let gender = gender {
            parameters["gender"] = gender
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        
        debugLog("📤 请求生成封面: \(parameters)")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        debugLog("📥 响应状态码: \(httpResponse.statusCode)")
        
        if let jsonString = String(data: data, encoding: .utf8) {
            debugLog("📦 响应数据: \(jsonString)")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "未知错误"
            throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "服务器返回错误: \(errorMsg)"])
        }
        
        let decoder = JSONDecoder()
        do {
            let response = try decoder.decode(CoverOptionsResponse.self, from: data)
            return response.coverURLs.compactMap { URL(string: $0) }
        } catch {
            debugLog("❌ 解码失败: \(error)")
            throw error
        }
    }
    
    
    func generateSongFromReference(
        originalSong: ReferenceSong,
        selectedCoverURL: URL,
        creativity: Double,
        duration: Double,
        artist: VirtualArtist,
        customLyrics: String,
        customStylePrompt: String,
        customTitle: String,
        token: String,
        lyricsTemperature: Double = 0.85,
        lyricsMaxTokens: Int = 4000,
        referenceAudioURL: URL? = nil,
        translatedLyrics: String? = nil,
        voiceModelIdOverride: String? = nil,
        referenceArtistLanguage: String? = nil
    ) async throws -> Song {
        
        // 使用参考歌曲的主题作为歌词创作主题
        let themeForLyrics = originalSong.theme.isEmpty ? "怀旧" : originalSong.theme
        let lyricsPrompt = """
            请创作一首与《\(originalSong.title)》风格相似的歌词，主题围绕“\(themeForLyrics)”，歌词需结构完整、押韵。
            风格特点：\(customStylePrompt)
            """
        
        // 根据主题推断情绪，增强风格描述
        let themeLower = originalSong.theme.lowercased()
        let mood: String
        if themeLower.contains("悲伤") || themeLower.contains("难过") || themeLower.contains("sad") {
            mood = "melancholic"
        } else if themeLower.contains("快乐") || themeLower.contains("喜悦") || themeLower.contains("happy") {
            mood = "joyful"
        } else if themeLower.contains("思念") || themeLower.contains("怀念") {
            mood = "nostalgic"
        } else if themeLower.contains("浪漫") || themeLower.contains("爱情") {
            mood = "romantic"
        } else {
            mood = "emotional"
        }
        
        // ✅ 修复后的风格增强逻辑
        let enrichedBase = customStylePrompt.isEmpty
        ? "\(mood) mood"
        : "\(customStylePrompt), \(mood) mood"
        
        let referenceGenre = artist.genre
        var enrichedStylePrompt = enrichedBase
        if !referenceGenre.isEmpty {
            enrichedStylePrompt += ", genre: \(referenceGenre)"
        }
        
        // 尝试从参考歌手的 stylePrompt 中提取人声描述（如性别、音色）
        let referenceStylePrompt = ReferenceService.shared.artists.first(where: { $0.name == originalSong.artist })?.stylePrompt ?? ""
        let vocalDescription = extractVocalDescription(from: referenceStylePrompt)
        
        let finalMusicPrompt = enrichedStylePrompt +
        " \(vocalDescription)" +
        " 要求编曲、音色和演唱风格高度模仿该歌手，音质达到无损级别。"
        
        // ========== 第一阶段：生成歌词并获取 Mureka 生成的歌曲 ==========
        // 注意：这部分仍使用原有的 generateAISong 逻辑，但我们需要将其改造为提交任务+轮询
        // 由于原有的 generateAISong 是同步等待 Mureka 完成，我们现在将其拆分为两步：
        // 1. 先调用原有的 generateAISong 来生成歌词和 Mureka 歌曲（这部分仍然是同步的）
        // 2. 然后提交到队列保存到数据库
        
        // 使用原有的 generateAISong 方法（它会调用 Mureka 并返回生成的 Song）
        // 但原有的 generateAISong 最后会调用 /songs/generate_and_link 接口，这个接口现在已经是异步队列了
        // 所以我们需要改用直接调用 Mureka 生成歌曲，然后提交任务
        
        // 更简洁的方式：复用原有的 generateAISong 逻辑，但跳过最后的保存步骤，改为队列提交
        // 由于代码量较大，这里提供一个完整的重构版本
        
        return try await withCheckedThrowingContinuation { continuation in
            // 第一步：生成歌词并调用 Mureka 生成歌曲（同步等待 Mureka 完成）
            // 使用原有的 generateAISong 方法，但传入一个特殊的 completion 处理
            // 注意：原有的 generateAISong 会调用 /songs/generate_and_link，这个接口现在返回 taskId
            // 所以我们需要修改 generateAISong 来支持异步队列
            
            // 为了保持兼容，我们直接调用 generateAISong，它会返回 Song（因为后端已经改为异步队列，
            // 但前端还没有适配，所以我们需要修改 generateAISong 的内部实现来轮询）
            
            // 由于时间关系，这里提供一个直接调用新接口的版本：
            Task {
                do {
                    // 1. 先使用 DeepSeek 生成歌词（如果需要）
                    var finalLyrics = customLyrics
                    var finalTitle = customTitle
                    
                    if finalLyrics.isEmpty {
                        await MainActor.run {
                            self.generationProgress = "正在生成歌词..."
                        }
                        let (generatedTitle, generatedLyrics) = try await DeepSeekService.shared.generateLyrics(
                            prompt: lyricsPrompt,
                            temperature: lyricsTemperature,
                            maxTokens: lyricsMaxTokens
                        )
                        finalTitle = generatedTitle.isEmpty ? customTitle : generatedTitle
                        finalLyrics = generatedLyrics
                        await MainActor.run {
                            self.generationProgress = "歌词已完成，正在合成音乐..."
                        }
                    }
                    
                    // 2. 调用 Mureka 生成歌曲（同步等待，这步仍然会耗时）
                    await MainActor.run {
                        self.generationProgress = "正在提交音乐生成任务..."
                    }
                    
                    
                    // 构建人声和编曲增强指令
                    let vocalDesc: String
                    if let refArtist = ReferenceService.shared.artists.first(where: { $0.name == originalSong.artist }),
                       let fullPrompt = refArtist.stylePrompt,
                       let vocalRange = fullPrompt.range(of: "人声：") {
                        vocalDesc = String(fullPrompt[vocalRange.lowerBound...])
                            .split(separator: "\n").first.map(String.init) ?? "人声：深情温暖，咬字清晰"
                    } else {
                        vocalDesc = "人声：深情温暖，咬字清晰"
                    }
                    
                    // 获取参考歌手的语言（从 ReferenceService 中查找）
                    var languageInstruction = ""
                    if let refArtist = ReferenceService.shared.artists.first(where: { $0.name == originalSong.artist }),
                       let lang = refArtist.language {
                        switch lang {
                        case "粤语":
                            languageInstruction = " 演唱语言：粤语，必须使用地道粤语发音和词汇，旋律风格参考经典粤语金曲。"
                        case "English":
                            languageInstruction = " Sing in English with clear pronunciation, natural flow, and western pop style."
                        default:
                            languageInstruction = " 演唱语言：国语，发音标准，旋律流畅。"
                        }
                    }
                    
                    let enhancedMusicPrompt = """
                    \(finalMusicPrompt)
                    【演唱要求】\(vocalDesc)\(languageInstruction)
                    【编曲要求】请严格参考原曲《\(originalSong.title)》的编曲风格：\(originalSong.musicStyle ?? "遵循原版")
                    【音质要求】无损级别，高保真。
                    """
                    
                    // 确定最终使用的 voiceModelId
                    let finalVoiceModelId = voiceModelIdOverride ?? artist.voiceModelId
                    
                    
                    let murekaTaskId = try await MurekaService.shared.generateSong(
                        lyrics: finalLyrics,
                        prompt: enhancedMusicPrompt,
                        voiceModelId: finalVoiceModelId,   // 传递 voiceModelId
                        model: "mureka-9",
                        needWordLyrics: true,
                        temperature: creativity,
                        topP: 0.95,
                        duration: duration,
                        referenceAudioURL: referenceAudioURL,
                        audioFormat: "wav"
                    )
                    
                    await MainActor.run {
                        self.generationProgress = "AI 正在创作音乐，请耐心等待..."
                    }
                    
                    let generatedSong = try await MurekaService.shared.waitForTaskCompletion(taskId: murekaTaskId)
                    
                    // 3. 构建提交数据，调用异步队列接口
                    var publishData: [String: Any] = [
                        "title": finalTitle,
                        "artist": artist.name,
                        "album": "AI 经典再造",
                        "duration": generatedSong.duration ?? 0,
                        "audio_url": generatedSong.audioUrl?.absoluteString ?? "",
                        "cover_url": generatedSong.coverUrl?.absoluteString ?? "",
                        "lyrics": finalLyrics,
                        "word_lyrics": generatedSong.wordLyrics ?? "",
                        "virtual_artist_id": artist.id,
                        "is_user_generated": true
                    ]
                    
                    if let customCoverURL = selectedCoverURL.absoluteString as? String {
                        publishData["cover_url"] = customCoverURL
                    }
                    
                    if let translated = translatedLyrics, !translated.isEmpty {
                        publishData["translated_lyrics"] = translated
                    }
                    
                    // ✅ 新增：传递性别信息给后端
                    if let gender = artist.gender, !gender.isEmpty {
                        publishData["gender"] = gender
                        print("🔍 [性别传递] artist.gender = \(gender)")
                    }
                    
                    publishData["song_structure"] = [
                        "intro_bars": 4,
                        "verse_a_lines": 4,
                        "verse_b_lines": 4,
                        "chorus_lines": 4,
                        "bridge_lines": 4,
                        "outro_bars": 4
                    ]
                    
                    await MainActor.run {
                        self.generationProgress = "音乐已生成，正在保存到你的作品库..."
                    }
                    
                    // 4. 提交任务到队列，并轮询等待完成
                    let taskId = try await submitGenerationTask(publishData: publishData, token: token)
                    let finalSong = try await pollTaskStatus(taskId: taskId, token: token)
                    
                    await MainActor.run {
                        self.generationProgress = ""
                    }
                    continuation.resume(returning: finalSong)
                } catch {
                    await MainActor.run {
                        self.generationProgress = ""
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    
    func generateCovers(title: String,artist: String,coverURL: String?,count: Int,token: String,gender: String? = nil) async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/ai/generate-covers") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var parameters: [String: Any] = [
            "title": title,
            "artist": artist,
            "coverURL": coverURL ?? "",
            "count": count
        ]
        if let gender = gender {
            parameters["gender"] = gender
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        
        print("📤 [generateCovers] 请求参数: \(parameters)")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📥 [generateCovers] 响应状态码: \(httpResponse.statusCode)")
        }
        if let jsonString = String(data: data, encoding: .utf8) {
            print("📦 [generateCovers] 原始 JSON: \(jsonString)")
        }
        
        let decoder = JSONDecoder()
        let responseObj = try decoder.decode(CoverOptionsResponse.self, from: data)
        print("✅ [generateCovers] 解析后的 coverURLs: \(responseObj.coverURLs)")
        return responseObj.coverURLs
        
    }
    
    // MARK: - 歌词优化（使用 DeepSeek）
    func improveLyrics(currentLyrics: String,
                       task: String,
                       theme: String = "",
                       referenceArtist: String? = nil,
                       referenceSongTitle: String = "",           // ✅ 新增
                       referenceSongDuration: TimeInterval = 210, // ✅ 新增
                       optimizationGoals: Set<String> = [],
                       token: String,
                       temperature: Double = 0.85,
                       maxTokens: Int = 3000,
                       referenceLyrics: String? = nil,          // 新增：参考歌曲原歌词
                       referenceImageryHint: String? = nil,     // 新增：参考意象提示
                       songMusicStyle: String? = nil
    ) async throws -> (title: String, lyrics: String) {
        
        guard task == "optimize" else {
            throw NSError(domain: "ImproveLyrics", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的任务类型"])
        }
        
        // 1. 确定语言及获取歌手信息
        let languageInstruction: String
        let referenceArtistObject: ReferenceArtist?
        
        if let artistName = referenceArtist, !artistName.isEmpty {
            let referenceArtists = ReferenceService.shared.artists
            if referenceArtists.isEmpty {
                await ReferenceService.shared.loadArtists()
                referenceArtistObject = ReferenceService.shared.artists.first(where: { $0.name == artistName })
            } else {
                referenceArtistObject = referenceArtists.first(where: { $0.name == artistName })
            }
            
            let language = referenceArtistObject?.language
            switch language {
            case "粤语":
                languageInstruction = "请使用地道、口语化的粤语进行优化，严格避免普通话词汇。"
            case "English":
                languageInstruction = "Please optimize the lyrics in English, maintaining natural phrasing and avoiding awkward translations."
            default:
                languageInstruction = "请使用国语进行优化。"
            }
        } else {
            referenceArtistObject = nil
            languageInstruction = "保持原歌词的语言不变。"
        }
        
        // 2. 构建优化目标指令
        var additionalInstructions = ""
        if optimizationGoals.isEmpty {
            additionalInstructions += "- 深度打磨用词、增强韵律和诗意，保持原内容核心不变。\n"
        } else {
            if optimizationGoals.contains("替换陈旧意象") {
                additionalInstructions += "- 替换陈旧的、泛化的意象，使用更独特和新颖的具体细节。\n"
            }
            if optimizationGoals.contains("强化副歌记忆点") {
                additionalInstructions += "- 强化副歌的记忆点，让核心句式更有传唱性。\n"
            }
            if optimizationGoals.contains("丰富故事层次") {
                additionalInstructions += "- 丰富故事的起承转合，用场景推动情感递进。\n"
            }
            if optimizationGoals.contains("雕琢金句") {
                additionalInstructions += "- 精心雕琢1-2句金句，使其成为整首歌词的亮点。\n"
            }
        }
        
        // 3. 参考风格构建（shortStyleReference 优先）
        let styleReferenceText = referenceArtistObject?.shortStyleReference ?? """
            经典华语抒情歌曲的叙事方式——用具体场景表达情感，副歌简洁有力，整体情感真挚。
            """
        
        // 4. 主题引导
        let specificThemeGuidance = referenceArtistObject?.themeGuidance ?? ""
        let effectiveTheme = theme.isEmpty ? "思念" : theme
        
        var musicStyleGuidance = ""
        if let musicStyle = songMusicStyle, !musicStyle.isEmpty {
            musicStyleGuidance = """
                
                **编曲风格参考（必须严格遵守）**：
                参考歌曲《\(referenceSongTitle)》的编曲风格：\(musicStyle)
                请在优化歌词时，确保歌词的节奏、长短句、韵脚与上述编曲风格相匹配，使最终生成的歌曲能够完美契合该编曲。
                """
        }
        
        // 5. 精简后的优化提示词（只关注润色，不改变结构）
        let fullPrompt = """
        请对以下歌词进行**润色优化**，要求：
        
        1. **保持原有行数、段落结构（主歌/副歌/桥段）完全不变**，不要增加或删除任何行。
        2. 仅针对选定的优化目标进行改进：
        \(additionalInstructions)
        3. 语言要求：\(languageInstruction)
        4. 编曲风格参考：\(musicStyleGuidance)
        5. 参考歌手的风格：\(styleReferenceText)
        6. 意象创新：\(referenceImageryHint?.isEmpty == false ? "优先使用以下意象：\(referenceImageryHint!)" : "使用具体、新颖的生活细节。")
        
        **原歌词**：
        \(currentLyrics)
        
        **输出要求**：
        - 只输出优化后的歌词，保持原有的段落标记（如 [主歌A] 等）和空行分隔。
        - 不要输出任何解释、注释或额外内容。
        """
        
        
        // 调用 DeepSeek 生成（内部已含模型降级与思考模式）
        let (title, rawLyrics) = try await DeepSeekService.shared.generateLyrics(
            prompt: fullPrompt,
            temperature: temperature,
            maxTokens: maxTokens
        )
        
        // 清洗歌词
        let cleanedLyrics = cleanLyrics(rawLyrics)
        return (title, cleanedLyrics)
    }
    
    // MARK: - 上传公共版权音乐
    func uploadPublicDomainSong(
        title: String,
        artist: String,
        style: String,
        audioFile: URL,
        coverImage: UIImage?,
        token: String
    ) async throws -> Song {
        print("🔍 [uploadPublicDomainSong] 开始，标题：\(title)，歌手：\(artist)")
        let exists = try await checkPublicDomainSongExists(title: title, artist: artist, token: token)
        print("🔍 [uploadPublicDomainSong] exists = \(exists)")
        
        if exists {
            throw NSError(
                domain: "DuplicateSong",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "该音乐已存在于公共版权库中，请勿重复导入"]
            )
        }
        return try await createSongAsync(
            artistId: nil,
            title: title,
            artistName: artist,
            style: style,
            audioFile: audioFile,
            coverImage: coverImage,
            token: token
        )
    }
    
    func checkPublicDomainSongExists(title: String, artist: String, token: String) async throws -> Bool {
        guard let url = URL(string: baseURL + "/songs/check-exists") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "title": title,
            "artist": artist,
            "is_public_domain": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // ✅ 添加日志开始
        if let httpResponse = response as? HTTPURLResponse {
            print("🔍 [checkPublicDomainSongExists] 状态码: \(httpResponse.statusCode)")
        }
        if let responseString = String(data: data, encoding: .utf8) {
            print("📦 [checkPublicDomainSongExists] 原始响应: \(responseString)")
        } else {
            print("📦 [checkPublicDomainSongExists] 响应数据无法转为字符串")
        }
        // ✅ 添加日志结束
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard httpResponse.statusCode == 200 else {
            // 这里可以打印更详细错误
            throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: nil)
        }
        struct CheckResponse: Decodable { let exists: Bool }
        let result = try JSONDecoder().decode(CheckResponse.self, from: data)
        return result.exists
    }
    
    //    func checkPublicDomainSongExists(title: String, artist: String, token: String) async throws -> Bool {
    //        guard let url = URL(string: baseURL + "/songs/check-exists") else {
    //            throw URLError(.badURL)
    //        }
    //        var request = URLRequest(url: url)
    //        request.httpMethod = "POST"
    //        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    //        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    //        let body: [String: Any] = [
    //            "title": title,
    //            "artist": artist,
    //            "is_public_domain": true
    //        ]
    //        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    //
    //        let (data, _) = try await URLSession.shared.data(for: request)
    //        struct CheckResponse: Decodable {
    //            let exists: Bool
    //        }
    //        let result = try JSONDecoder().decode(CheckResponse.self, from: data)
    //        return result.exists
    //    }
}

extension VirtualArtistService {
    
    // MARK: - 歌词清洗（去除特殊符号）
    private func cleanLyrics(_ lyrics: String) -> String {
        // 1. 去除所有括号及其内容（包括中英文括号、方括号）
        // 优化：同时去除未闭合括号
        let bracketPattern = "（[^（）]*）?|\\([^()]*\\)?|\\[.*?\\]?|【.*?】?"
        var cleaned = lyrics.replacingOccurrences(of: bracketPattern, with: "", options: .regularExpression)
        
        // 2. 去除常见非歌词符号
        let symbolsToRemove = ["*", "#", "@", "～", "~", "`", "「", "」", "『", "』", "•", "■", "□"]
        for symbol in symbolsToRemove {
            cleaned = cleaned.replacingOccurrences(of: symbol, with: "")
        }
        
        // 3. 压缩连续空行（保留一个空行作为段落分隔）
        cleaned = cleaned.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        
        // 4. 去除首尾空白和空行
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    
    
    private func performRequestWithAuth<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        boundary: String? = nil,
        retryCount: Int = 0
    ) async throws -> T {
        guard let userService = userService else {
            throw NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户服务未初始化"])
        }
        let token = try await userService.getValidAccessToken()
        var request = makeRequest(path: path, method: method, token: token, body: body, boundary: boundary)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        // ✅ 401 处理：尝试刷新一次，如果刷新失败则清除本地数据并抛出错误
        if httpResponse.statusCode == 401 && retryCount == 0 {
            debugLog("⚠️ Token 失效，尝试刷新...")
            do {
                _ = try await userService.refreshAccessToken(silent: true)
                // 刷新成功，重试请求
                return try await performRequestWithAuth(path: path, method: method, body: body, boundary: boundary, retryCount: 1)
            } catch {
                // 刷新失败，清除本地登录状态并提示重新登录
                debugLog("❌ 刷新失败，清除本地登录状态")
                throw NSError(domain: "AuthError", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录已过期，请重新登录"])
            }
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "请求失败"
            throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        if data.isEmpty && T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
    
    private struct EmptyResponse: Decodable {}
    
    private func performRequestWithAuthNoDecode(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        boundary: String? = nil,
        retryCount: Int = 0
    ) async throws {
        guard let userService = userService else {
            throw NSError(domain: "AuthError", code: -1, userInfo: [NSLocalizedDescriptionKey: "用户服务未初始化"])
        }
        let token = try await userService.getValidAccessToken()
        var request = makeRequest(path: path, method: method, token: token, body: body, boundary: boundary)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        // ✅ 401 处理：尝试刷新一次，如果刷新失败则清除本地数据并抛出错误
        if httpResponse.statusCode == 401 && retryCount == 0 {
            debugLog("⚠️ Token 失效，尝试刷新...")
            do {
                _ = try await userService.refreshAccessToken(silent: true)
                // 刷新成功，重试请求
                return try await performRequestWithAuthNoDecode(path: path, method: method, body: body, boundary: boundary, retryCount: 1)
            } catch {
                // 刷新失败，清除本地登录状态并提示重新登录
                debugLog("❌ 刷新失败，清除本地登录状态")
                throw NSError(domain: "AuthError", code: 401, userInfo: [NSLocalizedDescriptionKey: "登录已过期，请重新登录"])
            }
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败"])
        }
    }
    
    
    // MARK: - 音频母带处理
    /// 提交母带处理任务，返回任务ID
    func submitMasterTask(audioURL: URL, token: String) async throws -> String {
        guard let url = URL(string: baseURL + "/audio/master") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 202 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorMsg = String(data: data, encoding: .utf8) ?? "提交任务失败"
            throw NSError(domain: "MasterError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        struct TaskResponse: Decodable {
            let taskId: String
        }
        let result = try JSONDecoder().decode(TaskResponse.self, from: data)
        return result.taskId
    }
    
    /// 查询任务状态（自动刷新 token）
    func getMasterTaskStatus(taskId: String, token: String) async throws -> (status: String, processedURL: String?, error: String?, progress: Int?) {
        try Task.checkCancellation()
        
        // 定义响应结构体（与后端保持一致）
        struct TaskStatusResponse: Decodable {
            let taskId: String
            let status: String
            let processedAudioURL: String?
            let error: String?
            let progress: Int?
        }
        
        let path = "/audio/task/\(taskId)"
        // 使用带自动刷新 token 的请求包装器，忽略传入的 token 参数
        let response: TaskStatusResponse = try await performRequestWithAuth(path: path, method: "GET")
        return (response.status, response.processedAudioURL, response.error, response.progress)
    }
    
    func waitForMasterTaskCompletion(
        taskId: String,
        token: String,
        onProgress: @escaping (Int, String) -> Void = { _, _ in }
    ) async throws -> URL {
        let maxDuration: TimeInterval = 180 // 从 600 秒降至 180 秒，防止无限等待
        let startTime = Date()
        
        var interval: TimeInterval = 2.0
        let maxInterval: TimeInterval = 5.0   // 从 10 秒降至 5 秒
        let backoffFactor = 1.2
        
        while true {
            try Task.checkCancellation()
            
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > maxDuration {
                throw NSError(
                    domain: "MasterError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "AI 生成超时，请稍后重试"]
                )
            }
            
            let (status, processedURL, error, progress) = try await getMasterTaskStatus(taskId: taskId, token: token)
            onProgress(progress ?? 0, status)
            
            switch status {
            case "completed":
                guard let urlString = processedURL, let url = URL(string: urlString) else {
                    throw NSError(domain: "MasterError", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成完成但无音频"])
                }
                return url
            case "failed":
                throw NSError(domain: "MasterError", code: -1, userInfo: [NSLocalizedDescriptionKey: error ?? "AI 生成失败"])
            case "pending", "processing":
                break
            default:
                throw NSError(domain: "MasterError", code: -1, userInfo: [NSLocalizedDescriptionKey: "未知状态: \(status)"])
            }
            
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            interval = min(interval * backoffFactor, maxInterval)
        }
    }
    
    // MARK: - 异步任务提交与查询（解耦 UI）
    func submitGenerationTask(
        originalSong: ReferenceSong,
        selectedCoverURL: URL,
        creativity: Double,
        duration: Double,
        artist: VirtualArtist,
        customLyrics: String,
        customStylePrompt: String,
        customTitle: String,
        token: String,
        lyricsTemperature: Double = 0.85,
        lyricsMaxTokens: Int = 4000,
        referenceAudioURL: URL? = nil,
        translatedLyrics: String? = nil,
        voiceModelIdOverride: String? = nil,
        referenceArtistLanguage: String? = nil,
        gender: String? = nil   // ✅ 新增
    ) async throws -> String {
        // 构建后端需要的参数（不调用 Mureka）
        let publishData: [String: Any] = [
            "title": customTitle,
            "artist": artist.name,
            "album": "AI 经典再造",
            "duration": duration,
            "lyrics": customLyrics,
            "word_lyrics": "",  // 后端生成
            "style": customStylePrompt,
            "cover_url": selectedCoverURL.absoluteString,
            "virtual_artist_id": artist.id ?? "",   // ✅ 修复：artist.id 是 String? 类型
            "is_user_generated": true,
            "translated_lyrics": translatedLyrics ?? "",
            "reference_audio_url": referenceAudioURL?.absoluteString ?? "",
            "reference_artist_language": referenceArtistLanguage ?? "",
            "original_song_title": originalSong.title,
            "original_song_music_style": originalSong.musicStyle ?? "",
            "original_song_theme": originalSong.theme,
            "creativity": creativity,
            "lyrics_temperature": lyricsTemperature,
            "lyrics_max_tokens": lyricsMaxTokens,
            "voice_model_id": voiceModelIdOverride ?? artist.voiceModelId ?? "",
            "duration_seconds": duration,
            "gender": gender ?? ""   // ✅ 添加到请求体
        ]
        
        // 提交到后端队列，获得 taskId
        let taskId = try await submitGenerationTaskToBackend(publishData: publishData, token: token)
        return taskId
    }
    
    // submitGenerationTaskToBackend 方法保持不变（已存在）
    private func submitGenerationTaskToBackend(publishData: [String: Any], token: String) async throws -> String {
        let url = URL(string: baseURL + "/songs/generate_and_link")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: publishData)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        struct TaskResponse: Decodable { let taskId: String }
        let response = try JSONDecoder().decode(TaskResponse.self, from: data)
        return response.taskId
    }
    
    
    // 2. 查询任务状态（供轮询使用）
    func queryTaskStatus(taskId: String, token: String) async throws -> (status: String, song: Song?) {
        let url = URL(string: baseURL + "/songs/task/\(taskId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        struct StatusResponse: Decodable {
            let status: String
            let songId: String?
            let title: String?
            let artist: String?
            let coverUrl: String?
            let audioUrl: String?
            let lyrics: String?
            let wordLyrics: String?
            let error: String?
            let translatedLyrics: String?
            let translatedWordLyrics: String?
        }
        let statusResp = try JSONDecoder().decode(StatusResponse.self, from: data)
        var song: Song? = nil
        if statusResp.status == "completed",
           let songId = statusResp.songId,
           let title = statusResp.title,
           let artist = statusResp.artist,
           let coverUrl = statusResp.coverUrl,
           let audioUrl = statusResp.audioUrl {
            song = Song(
                id: songId,
                title: title,
                artist: artist,
                album: nil,
                duration: 0,
                audioUrl: audioUrl,
                coverUrl: coverUrl,
                lyrics: statusResp.lyrics,
                virtualArtist: nil,
                virtualArtistId: nil,
                creatorId: nil,
                isUserGenerated: true,
                wordLyrics: statusResp.wordLyrics,
                createdAt: nil,
                style: nil,
                streamURL: nil,
                translatedLyrics: statusResp.translatedLyrics,
                translatedWordLyrics: statusResp.translatedWordLyrics
            )
        }
        return (statusResp.status, song)
    }
    
}

// MARK: - 异步队列辅助方法
extension VirtualArtistService {
    
    /// 提交生成任务到队列
    private func submitGenerationTask(publishData: [String: Any], token: String) async throws -> String {
        let url = URL(string: baseURL + "/songs/generate_and_link")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: publishData)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        struct TaskResponse: Decodable {
            let taskId: String
        }
        let response = try JSONDecoder().decode(TaskResponse.self, from: data)
        return response.taskId
    }
    
    /// 轮询任务状态直到完成
    private func pollTaskStatus(taskId: String, token: String) async throws -> Song {
        let maxAttempts = 300  // 最多轮询 5 分钟（每次间隔 1 秒）
        
        var attempts = 0
        
        while attempts < maxAttempts {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 秒
            attempts += 1
            
            let url = URL(string: baseURL + "/songs/task/\(taskId)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            struct StatusResponse: Decodable {
                let status: String
                let songId: String?
                let title: String?
                let artist: String?
                let coverUrl: String?
                let audioUrl: String?
                let lyrics: String?
                let wordLyrics: String?
                let error: String?
                let translatedLyrics: String?
                let translatedWordLyrics: String?
            }
            let statusResp = try JSONDecoder().decode(StatusResponse.self, from: data)
            
            switch statusResp.status {
            case "completed":
                guard let songId = statusResp.songId,
                      let title = statusResp.title,
                      let artist = statusResp.artist,
                      let coverUrl = statusResp.coverUrl,
                      let audioUrl = statusResp.audioUrl else {
                    throw NSError(domain: "PollingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "任务完成但返回数据不完整"])
                }
                // 构造 Song 对象返回
                return Song(
                    id: songId,
                    title: title,
                    artist: artist,
                    album: nil,
                    duration: 0,
                    audioUrl: audioUrl,
                    coverUrl: coverUrl,
                    lyrics: statusResp.lyrics,
                    virtualArtist: nil,
                    virtualArtistId: nil,
                    creatorId: nil,
                    isUserGenerated: true,
                    wordLyrics: statusResp.wordLyrics,
                    createdAt: nil,
                    style: nil,
                    streamURL: nil,
                    translatedLyrics: statusResp.translatedLyrics,      // ✅ 新增
                    translatedWordLyrics: statusResp.translatedWordLyrics  // ✅ 新增
                )
            case "failed":
                throw NSError(domain: "TaskFailed", code: -1, userInfo: [NSLocalizedDescriptionKey: statusResp.error ?? "生成失败"])
            default:
                continue
            }
        }
        throw NSError(domain: "Timeout", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成超时，请稍后重试"])
    }
}

// MARK: - 使用 MiniMax 生成歌曲（与 DeepSeek 歌词无缝集成）
extension VirtualArtistService {
    
    // MARK: - 音频文件有效性校验
    private func isValidAudioFile(at url: URL) -> Bool {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return audioFile.length > 0
        } catch {
            return false
        }
    }
    
    private func downloadTempFile(from url: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // 验证文件大小至少 1KB，避免空文件
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        guard let fileSize = attrs[.size] as? Int64, fileSize > 1024 else {
            throw NSError(domain: "InvalidFileSize", code: -1)
        }
        return tempURL
    }
    
    func downloadSongToLocal(_ song: Song) async throws -> URL {
        guard let remoteURL = song.audioURL else {
            throw NSError(domain: "NoAudioURL", code: -1)
        }
        // 使用 .wav 扩展名保持格式
        let localURL = PlaybackService.localAudioURL(for: song.id, extension: "wav")
        let directory = localURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // 已有有效缓存则直接返回
        if FileManager.default.fileExists(atPath: localURL.path), isValidAudioFile(at: localURL) {
            return localURL
        }
        
        // 下载临时文件
        let tempURL = try await downloadTempFile(from: remoteURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // 验证下载的临时文件有效性
        guard isValidAudioFile(at: tempURL) else {
            throw NSError(domain: "InvalidDownload", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载的文件无效"])
        }
        
        // 直接移动原始 WAV 文件到缓存目录（不转换，保证高品质）
        do {
            try FileManager.default.moveItem(at: tempURL, to: localURL)
            print("✅ AI 歌曲已缓存到本地 (WAV): \(localURL.path)")
            return localURL
        } catch {
            print("⚠️ 移动文件失败: \(error)，将使用远程播放")
            throw NSError(domain: "UseRemoteURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "使用原始远程URL"])
        }
    }
    
    private func extractVocalDescription(from stylePrompt: String) -> String {
        // 简单提取包含“人声”或“性别”的行
        let lines = stylePrompt.components(separatedBy: "\n")
        let vocalLine = lines.first(where: { $0.contains("人声") || $0.contains("男声") || $0.contains("女声") })
        return vocalLine ?? ""
    }
}
