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
    func createArtist(name: String, avatarImage: UIImage?, bio: String, genre: String, token: String, voiceModelId: String? = nil, completion: @escaping (Result<VirtualArtist, Error>) -> Void) {
        let url = URL(string: baseURL + "/artists")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        let params: [String: String] = [
            "name": name,
            "genre": genre,
            "bio": bio,
            "voiceModelId": voiceModelId ?? ""
        ]
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
                let musicPrompt = customStylePrompt ?? prompt
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
                
//                URLSession.shared.dataTask(with: request) { data, response, error in
//                    DispatchQueue.main.async {
//                        self.generationProgress = ""   // 清空进度
//                        if let error = error {
//                            completion(.failure(error))
//                            return
//                        }
//                        guard let data = data else {
//                            completion(.failure(NSError(domain: "NoData", code: -1, userInfo: nil)))
//                            return
//                        }
//                        if let jsonString = String(data: data, encoding: .utf8) {
//                            debugLog("📦 服务器返回原始 JSON: \(jsonString)")
//                        }
//                        do {
//                            let decoder = JSONDecoder()
//                            decoder.dateDecodingStrategy = .iso8601
//                            let song = try decoder.decode(Song.self, from: data)
//                            debugLog("🔊 解析后的歌曲音频 URL: \(String(describing: song.audioURL))")
//                            // 延迟 0.5 秒再通知前端，给内存和资源释放留出时间
//                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//                                completion(.success(song))
//                            }
//                        } catch {
//                            completion(.failure(error))
//                        }
//                    }
//                }.resume()
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
        referenceAudioURL: URL? = nil          // 新增：参考音轨
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
        
        return try await withCheckedThrowingContinuation { continuation in
            generateAISong(
                artist: artist,
                songTitle: originalSong.title,
                album: "AI 经典再造",
                lyrics: "",
                prompt: lyricsPrompt,
                coverURL: selectedCoverURL.absoluteString,
                token: token,
                temperature: creativity,
                topP: 0.95,
                customLyrics: customLyrics,
                customTitle: customTitle,
                customStylePrompt: finalMusicPrompt,   // 使用增强后的风格提示
                targetDuration: duration,
                lyricsTemperature: lyricsTemperature,
                lyricsMaxTokens: lyricsMaxTokens,
                referenceAudioURL: referenceAudioURL,   // 传递参考音轨
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }
    
    
    func generateCovers(
        title: String,
        artist: String,
        coverURL: String?,
        count: Int,
        token: String,
        gender: String? = nil      // 新增
    ) async throws -> [String] {
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
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(CoverOptionsResponse.self, from: data)
        return response.coverURLs
    }
    
    // MARK: - 歌词优化（使用 DeepSeek）
    func improveLyrics(currentLyrics: String,
                       task: String,
                       theme: String = "",
                       referenceArtist: String? = nil,
                       optimizationGoals: Set<String> = [],
                       token: String,
                       temperature: Double = 0.85,
                       maxTokens: Int = 3000,
                       referenceLyrics: String? = nil,          // 新增：参考歌曲原歌词
                       referenceImageryHint: String? = nil      // 新增：参考意象提示
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
        
        // 5. 构建创作提示词（模仿 generateInitialLyricsAndStyle 的结构，但任务是优化）
        var prompt = """
        你是一位世界级作词大师，正在帮助用户优化一首已存在的歌词。请保留歌词的核心情感与结构，但大幅提升其文学性、韵律感与意象的独创性。优化要求如下：
        
        1. **原歌词初稿**：
           \(currentLyrics)
        
        2. **核心风格参考**：
           - \(styleReferenceText)
           \(specificThemeGuidance.isEmpty ? "" : "- 补充主题引导：" + specificThemeGuidance)
        
        3. **语言要求**：
           \(languageInstruction)
        
        4. **优化重点**：
           \(additionalInstructions)
        
        5. **意象创新**：
           - 避免“月光、泪水、誓言”等已被过度使用的词汇。
           \(referenceImageryHint?.isEmpty == false ? "- 优先从以下意象中汲取灵感：\(referenceImageryHint!)。请用它们构建独特的场景，避免抽象抒情。" : "- 使用具体、新颖、与情感契合的生活细节作为意象。")
        
        6. **参考歌词范例**（从中学习用词和句式，但不可照搬）：
           \(referenceLyrics?.isEmpty == false ? "“\(referenceLyrics!)”" : "无")
        
        7. **韵律与演唱要求**：
           - 优化后的歌词每一句都应保持相近的音节数，不能出现一句极短一句极长的失衡感。中文每句控制在7~10个字，英文每句8~10个音节。
           - 副歌严格押韵，韵脚统一，段落间对应行音节数一致（差异≤2）。
           - 避免生僻字和拗口词汇，确保流畅自然。
        
        8. **输出格式**：
           - 只输出优化后的纯歌词文本，不要包含任何括号、舞台提示、和声标注、符号标记。
           - 段落之间使用一个空行分隔。
           - 如果优化后歌名有变，请在第一行直接写新歌名，不加符号；否则可沿用原歌名。
        
        请直接输出优化后的歌词：
        """
        
        // 调用 DeepSeek 生成（内部已含模型降级与思考模式）
        let (title, rawLyrics) = try await DeepSeekService.shared.generateLyrics(
            prompt: prompt,
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
        let exists = try await checkPublicDomainSongExists(title: title, artist: artist, token: token)
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
        
        let (data, _) = try await URLSession.shared.data(for: request)
        struct CheckResponse: Decodable {
            let exists: Bool
        }
        let result = try JSONDecoder().decode(CheckResponse.self, from: data)
        return result.exists
    }
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
    // 带自动刷新 token 的请求包装器，返回解码后的数据
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
        
        if httpResponse.statusCode == 401 && retryCount == 0 {
            debugLog("⚠️ Token 失效，尝试刷新...")
            _ = try await userService.refreshAccessToken()
            return try await performRequestWithAuth(path: path, method: method, body: body, boundary: boundary, retryCount: 1)
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
    
    // 带自动刷新 token 的请求包装器，不关心返回内容
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
        
        if httpResponse.statusCode == 401 && retryCount == 0 {
            debugLog("⚠️ Token 失效，尝试刷新...")
            _ = try await userService.refreshAccessToken()
            return try await performRequestWithAuthNoDecode(path: path, method: method, body: body, boundary: boundary, retryCount: 1)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "HTTPError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "请求失败"])
        }
    }
    
    // MARK: - 音频母带处理
    // 替换原有的 masterAudio 方法为以下两个方法
    
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
    
}
// MARK: - 使用 MiniMax 生成歌曲（与 DeepSeek 歌词无缝集成）
extension VirtualArtistService {
    
    func downloadSongToLocal(_ song: Song) async throws -> URL {
        guard let remoteURL = song.audioURL else {
            throw NSError(domain: "NoAudioURL", code: -1)
        }
        let localFLACURL = PlaybackService.localAudioURL(for: song.id)
        // 如果本地已有 FLAC 缓存，直接返回
        if FileManager.default.fileExists(atPath: localFLACURL.path) {
            return localFLACURL
        }
        
        // 1. 下载到临时文件（带扩展名，确保转换器能识别格式）
        let tempDownloadURL: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: remoteURL) { tempURL, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    continuation.resume(throwing: NSError(domain: "DownloadError", code: -1))
                    return
                }
                let originalExtension = remoteURL.pathExtension.isEmpty ? "tmp" : remoteURL.pathExtension
                let renamedTempURL = tempURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("creation_\(UUID().uuidString).\(originalExtension)")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: renamedTempURL)
                    continuation.resume(returning: renamedTempURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
        
        // 2. 尝试转成 FLAC / M4A 无损并缓存
        do {
            let convertedURL = try autoreleasepool { try AudioConverter.convertToFlac(sourceURL: tempDownloadURL) }
            try FileManager.default.moveItem(at: convertedURL, to: localFLACURL)
            // 清理残留的临时文件及旧格式
            try? FileManager.default.removeItem(at: tempDownloadURL)
            let base = localFLACURL.deletingPathExtension()
            for ext in ["wav", "mp3", "m4a", "tmp"] {
                let oldFile = base.appendingPathExtension(ext)
                if oldFile != localFLACURL {
                    try? FileManager.default.removeItem(at: oldFile)
                }
            }
            print("✅ AI 歌曲已转为 FLAC 缓存: \(localFLACURL.lastPathComponent)")
            return localFLACURL
        } catch {
            // 转换失败时，保留原始下载文件作为缓存（不丢数据）
            print("⚠️ 转换失败，直接缓存原始文件: \(error)")
            let originalExtension = remoteURL.pathExtension.isEmpty ? "mp3" : remoteURL.pathExtension
            let fallbackURL = localFLACURL
                .deletingPathExtension()
                .appendingPathExtension(originalExtension)
            try? FileManager.default.moveItem(at: tempDownloadURL, to: fallbackURL)
            return fallbackURL
        }
    }
    
    private func extractVocalDescription(from stylePrompt: String) -> String {
        // 简单提取包含“人声”或“性别”的行
        let lines = stylePrompt.components(separatedBy: "\n")
        let vocalLine = lines.first(where: { $0.contains("人声") || $0.contains("男声") || $0.contains("女声") })
        return vocalLine ?? ""
    }
}
