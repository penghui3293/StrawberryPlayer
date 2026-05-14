
//
//  LibraryService.swift
//  StrawberryPlayer
//  扫描本地文件、提取元数据
//

import Foundation
import AVFoundation
import Combine

enum PublishError: Error, LocalizedError {
    case missingWordLyrics
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case invalidResponse
    case encodingFailed
    
    var errorDescription: String? {
        switch self {
        case .missingWordLyrics:
            return "歌曲缺少逐词歌词数据"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "服务器错误 (\(code)): \(message ?? "未知错误")"
        case .invalidResponse:
            return "无效的服务器响应"
        case .encodingFailed:
            return "数据编码失败"
        }
    }
}

enum LibraryDataSource {
    case local
    case online
    case aiGenerated
}

extension Notification.Name {
    static let songsDidChange = Notification.Name("songsDidChange")
}

@MainActor
class LibraryService: ObservableObject {
    
    @Published var dataSource: LibraryDataSource = .local
    @Published var songs: [Song] = []
    @Published var isScanningCloud = false
    @Published var hasSavedBookmark: Bool = false
    
    private let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private let supportedExtensions = ["mp3", "wav", "m4a", "aiff", "caf", "flac"]
    private let bookmarksKey = "iCloudFolderBookmark"
    private var folderBookmark: Data? {
        didSet {
            hasSavedBookmark = (folderBookmark != nil)
        }
    }
    
    private var isLoadingSongs = false
    private var lastLoadTime: Date?
    
        
    struct LocalSong: Codable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let audioUrl: String
        let coverUrl: String
        let lyrics: String?
        let wordLyrics: String?
    }
    
    
    
    // MARK: - 发布 AI 歌曲到服务器
    func publishSong(_ song: MurekaSong) async throws {
        var songToPublish = song
        guard let wordLyricsData = try? JSONEncoder().encode(song.wordLyrics) else {
            throw PublishError.missingWordLyrics
        }
        
        
        let baseURL = AppConfig.baseURL

        guard !baseURL.isEmpty, let url = URL(string: baseURL + "/api/songs") else {
            throw URLError(.badURL)
        }
        
        guard let audioUrlString = song.audioUrl?.absoluteString else {
            throw NSError(domain: "publishSong", code: -1, userInfo: [NSLocalizedDescriptionKey: "音频 URL 无效"])
        }
        
        let localSong = LocalSong(
            title: song.title ?? "AI 生成音乐",
            artist: song.artist ?? "Mureka AI",
            album: song.album ?? "AI 音乐集",
            duration: song.duration ?? 0,
            audioUrl: audioUrlString,
            coverUrl: song.coverUrl?.absoluteString ?? "",
            lyrics: song.lyrics,
            wordLyrics: song.wordLyrics
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        debugLog("📤 准备发布歌曲，歌词长度: \(song.lyrics?.count ?? 0)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let requestBody = try encoder.encode([localSong])
        debugLog("📤 发送的 JSON: \(String(data: requestBody, encoding: .utf8)!)")
        request.httpBody = requestBody
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let responseStr = String(data: responseData, encoding: .utf8) {
                debugLog("服务器响应: \(responseStr)")
            }
            throw URLError(.badServerResponse)
        }
        debugLog("✅ 歌曲发布成功")
    }
    
    func loadAISongsFromServer(forceRefresh: Bool = false) async {
        guard !isLoadingSongs else {
            debugLog("⚠️ 正在加载歌曲，跳过重复请求")
            return
        }
        if !forceRefresh, let last = lastLoadTime, Date().timeIntervalSince(last) < 5 {
            debugLog("⚠️ 请求过于频繁，已忽略")
            return
        }

        isLoadingSongs = true
        lastLoadTime = Date()
        // 使用 defer 确保无论如何退出方法时都会重置 isLoadingSongs
        defer { isLoadingSongs = false }

        debugLog("📡 开始从服务器加载歌曲...")

        guard let url = URL(string: AppConfig.baseURL + "/api/songs") else {
            debugLog("❌ 无效的 AI 服务器 URL")
            await MainActor.run {
                self.dataSource = .online   // 即使失败也要切换数据源状态，让 UI 停止显示加载
                NotificationCenter.default.post(name: .songsDidChange, object: nil)
            }
            return
        }

        let maxRetries = 3
        var attempt = 0
        var lastError: Error?

        repeat {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let jsonStr = String(data: data, encoding: .utf8) {
//                    debugLog("📥 服务器返回的歌曲列表: \(jsonStr)")
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let serverSongs = try decoder.decode([Song].self, from: data)
                debugLog("📊 解码后的 songs 数量: \(serverSongs.count)")

                // 获取当前本地歌曲中已存在的完整 Song 实例（以 id 为键）
                let localSongsDict = await MainActor.run {
                    return Dictionary(uniqueKeysWithValues: self.songs.map { ($0.id, $0) })
                }

                // 合并：如果本地存在相同 id 的歌曲，则保留其 cachedWordLyrics
                let mergedSongs = serverSongs.map { serverSong -> Song in
                    guard let localSong = localSongsDict[serverSong.id],
                          let localLyrics = localSong.cachedWordLyrics else {
                        return serverSong
                    }
                    var merged = serverSong
                    merged.cachedWordLyrics = localLyrics
                    return merged
                }
                
                
                // ✅ 自动关联本地缓存路径：如果本地已下载该歌曲，则替换 audioUrl 为本地文件 URL
                let songsWithLocalURL = mergedSongs.map { song -> Song in
                    var updatedSong = song
                    let localURL = PlaybackService.localAudioURL(for: song.id)
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        updatedSong.audioUrl = localURL.absoluteString
                        debugLog("📀 歌曲 \(song.title) 已关联本地缓存")
                    }
                    return updatedSong
                }

                for song in songsWithLocalURL {
                    if let lyrics = song.lyrics {
                        _ = saveLyricsToFile(lyrics: lyrics, forSongId: song.id)
                    }
                    debugLog("📀 歌曲: \(song.title), coverURL: \(song.coverURL?.absoluteString ?? "nil")")
                }

                await MainActor.run {
                    self.songs = songsWithLocalURL   // 注意这里改为使用 songsWithLocalURL
                    self.dataSource = .online
                    debugLog("✅ self.songs 已更新，当前数量: \(self.songs.count)")
                    NotificationCenter.default.post(name: .songsDidChange, object: nil)
                }
                
                return   // 成功，退出方法

            } catch {
                lastError = error
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
                    attempt += 1
                    if attempt <= maxRetries {
                        debugLog("⚠️ 网络不可达，第 \(attempt) 次重试...")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)   // 2 秒后重试
                        continue
                    }
                }
                // 不可重试的错误或重试耗尽，跳出循环
                break
            }
        } while attempt <= maxRetries

        // 所有重试均失败
        debugLog("❌ 加载 AI 歌曲失败: \(lastError?.localizedDescription ?? "未知错误")")
        await MainActor.run {
            // 即使失败，也要将 dataSource 置为 .online，以便 UI 知道加载已结束，不再显示加载指示器
            self.dataSource = .online
            NotificationCenter.default.post(name: .songsDidChange, object: nil)
        }
    }
    
    private func saveLyricsToFile(lyrics: String, forSongId: String) -> URL? {
        let fileName = "\(forSongId).lrc"
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let fileURL = documentsURL.appendingPathComponent(fileName)
        do {
            try lyrics.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            debugLog("❌ 保存歌词文件失败: \(error)")
            return nil
        }
    }
    
    init() {
        hasSavedBookmark = (folderBookmark != nil)
        
        // 监听逐字歌词修复完成通知
        NotificationCenter.default.addObserver(
            forName: .songWordLyricsDidRepair,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let songId = notification.userInfo?["songId"] as? String,
                  let wordLyrics = notification.userInfo?["wordLyrics"] as? [[WordLyrics]],
                  let index = self.songs.firstIndex(where: { $0.id == songId }) else {
                debugLog("⚠️ 无法处理歌词修复通知：缺少必要数据")
                return
            }
            
            var updatedSong = self.songs[index]
            updatedSong.cachedWordLyrics = wordLyrics
            self.songs[index] = updatedSong
            
            debugLog("✅ LibraryService 已更新歌曲「\(updatedSong.title)」的逐字歌词缓存")
            NotificationCenter.default.post(name: .songsDidChange, object: nil)
        }
    }
    
    
    // MARK: - 按专辑分组（用于显示）
    var folderGroups: [(name: String, coverData: Data?, songs: [Song])] {
        switch dataSource {
        case .local:
            let grouped = Dictionary(grouping: songs) { song -> String in
                song.audioURL?.deletingLastPathComponent().path ?? ""
            }
            return grouped.map { (path, songs) in
                let name = URL(fileURLWithPath: path).lastPathComponent
                // 由于新 Song 模型无 artworkData，封面数据设为 nil
                return (name: name, coverData: nil, songs: songs)
            }.sorted { $0.name < $1.name }
        case .online, .aiGenerated:
            let grouped = Dictionary(grouping: songs) { $0.album ?? "未知专辑" }
            return grouped.map { (album, songs) in
                // 同样，封面数据设为 nil
                return (name: album, coverData: nil, songs: songs)
            }.sorted { $0.name < $1.name }
        }
    }
    
    // MARK: - 从 Navidrome 加载数据
    func loadFromNavidrome() async {
        guard NavidromeService.shared.isAuthenticated else {
            debugLog("⚠️ Navidrome 未认证")
            return
        }
        
        DispatchQueue.main.async { self.isScanningCloud = true }
        do {
            let albums = try await NavidromeService.shared.getAlbumList(limit: 50)
            var allSongs: [Song] = []
            
            for album in albums {
                let songs = try await NavidromeService.shared.getAlbum(id: album.id)
                for song in songs {
                    if let streamURL = NavidromeService.shared.getStreamURL(songId: song.id) {
                        var coverData: Data? = nil
                        if let coverArtId = song.coverArt ?? album.coverArt,
                           let coverURL = NavidromeService.shared.getCoverArtURL(coverArtId: coverArtId, size: 300) {
                            if let (data, _) = try? await URLSession.shared.data(from: coverURL) {
                                if data.count < 60000 {
                                    coverData = data
                                    debugLog("✅ 保留封面，大小: \(data.count)")
                                } else {
                                    coverData = nil
                                    debugLog("❌ 丢弃默认封面，大小: \(data.count)")
                                }
                            }
                        }
                        
                        let newSong = Song(
                            id: song.id,
                            title: song.title,
                            artist: song.artist,
                            album: song.album,
                            duration: TimeInterval(song.duration ?? 0),
                            audioUrl: streamURL.absoluteString,
                            coverUrl: nil,
                            lyrics: nil,
                            virtualArtist: nil,
                            creatorId: nil,
                            isUserGenerated: false,
                            wordLyrics: nil,
                            createdAt: nil,
                            style: nil
                        )
                        allSongs.append(newSong)
                    }
                }
            }
            DispatchQueue.main.async {
                self.songs = allSongs
                self.dataSource = .online
                self.isScanningCloud = false
            }
        } catch {
            debugLog("❌ 从 Navidrome 加载失败: \(error)")
            DispatchQueue.main.async { self.isScanningCloud = false }
        }
    }
    
    // MARK: - 导入 iCloud 文件夹
    func importFolderFromCloud(at cloudURL: URL, completion: @escaping (Bool) -> Void) {
        guard cloudURL.startAccessingSecurityScopedResource() else {
            debugLog("⚠️ 无法访问 iCloud 路径")
            completion(false)
            return
        }
        defer { cloudURL.stopAccessingSecurityScopedResource() }
        
        do {
            let resourceValues = try cloudURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else {
                debugLog("⚠️ 请选择文件夹")
                completion(false)
                return
            }
        } catch {
            debugLog("❌ 无法获取资源属性: \(error)")
            completion(false)
            return
        }
        
        debugLog("📂 开始导入 iCloud 文件夹: \(cloudURL.lastPathComponent)")
        
        let destinationRoot = documentsURL
            .appendingPathComponent("iCloudImports", isDirectory: true)
            .appendingPathComponent(cloudURL.lastPathComponent, isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            debugLog("❌ 创建目标目录失败: \(error)")
            completion(false)
            return
        }
        
        let fileManager = FileManager.default
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard cloudURL.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            defer { cloudURL.stopAccessingSecurityScopedResource() }
            
            guard let enumerator = fileManager.enumerator(at: cloudURL,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            var copiedCount = 0
            var fileCount = 0
            for case let fileURL as URL in enumerator {
                fileCount += 1
                if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                    continue
                }
                guard self.isAudioFile(fileURL) else { continue }
                
                let fileName = fileURL.lastPathComponent
                let destinationURL = destinationRoot.appendingPathComponent(fileName)
                
                if fileManager.fileExists(atPath: destinationURL.path) {
                    continue
                }
                
                do {
                    try fileManager.copyItem(at: fileURL, to: destinationURL)
                    copiedCount += 1
                    debugLog("✅ 已复制: \(fileName)")
                } catch {
                    debugLog("❌ 复制失败: \(fileName) - \(error)")
                }
            }
            
            debugLog("📊 总计扫描文件: \(fileCount)，成功复制: \(copiedCount)")
            
            guard copiedCount > 0 else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            let newSongs = self.scanSongsInDirectory(destinationRoot)
            DispatchQueue.main.async {
                let existingURLs = Set(self.songs.compactMap { $0.audioURL })
                let songsToAdd = newSongs.filter { song in
                    guard let url = song.audioURL else { return false }
                    return !existingURLs.contains(url)
                }
                self.songs.append(contentsOf: songsToAdd)
                
                do {
                    let bookmarkData = try cloudURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.folderBookmark = bookmarkData
                    debugLog("✅ 文件夹书签已保存")
                } catch {
                    debugLog("❌ 保存书签失败: \(error)")
                }
                completion(true)
            }
        }
    }
    
    func restoreAndScanFromBookmark() {
        guard let bookmarkData = folderBookmark else {
            debugLog("⚠️ 没有保存的书签")
            return
        }
        
        var isStale = false
        do {
            let folderURL = try URL(resolvingBookmarkData: bookmarkData,
                                    options: [],
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &isStale)
            
            if isStale {
                debugLog("⚠️ 书签已失效，需要重新选择文件夹")
                folderBookmark = nil
                return
            }
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                guard folderURL.startAccessingSecurityScopedResource() else {
                    debugLog("⚠️ 无法访问书签指向的文件夹")
                    return
                }
                defer { folderURL.stopAccessingSecurityScopedResource() }
                
                let newSongs = self.scanSongsInDirectory(folderURL)
                DispatchQueue.main.async {
                    let existingURLs = Set(self.songs.compactMap { $0.audioURL })
                    let songsToAdd = newSongs.filter { song in
                        guard let url = song.audioURL else { return false }
                        return !existingURLs.contains(url)
                    }
                    self.songs.append(contentsOf: songsToAdd)
                    debugLog("✅ 从书签恢复并扫描完成，新增 \(songsToAdd.count) 首歌曲")
                }
            }
        } catch {
            debugLog("❌ 解析书签失败: \(error)")
        }
    }
    
    /// 内部方法：扫描指定目录下的所有音频文件，返回 [Song]（不更新 @Published）
    private func scanSongsInDirectory(_ directory: URL) -> [Song] {
        var scannedSongs: [Song] = []
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        for case let fileURL as URL in enumerator {
            guard isAudioFile(fileURL) else { continue }
            
            let lyricsURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
            let hasLyrics = fileManager.fileExists(atPath: lyricsURL.path)
            let lyrics: String? = hasLyrics ? try? String(contentsOf: lyricsURL, encoding: .utf8) : nil
            
            let asset = AVAsset(url: fileURL)
            
            if let song = Song.from(asset: asset, url: fileURL, lyricsURL: lyricsURL) {
                scannedSongs.append(song)
            }
        }
        return scannedSongs
    }
    
    /// 扫描指定文件夹下的所有音频文件（递归），并更新 songs 数组
    func scanSongs(in directory: URL) -> [Song] {
        let scanned = scanSongsInDirectory(directory)
        DispatchQueue.main.async {
            self.songs = scanned
        }
        return scanned
    }
    
    func importFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            debugLog("⚠️ 无法访问文件")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let destinationURL = generateUniqueDestinationURL(for: url.lastPathComponent)
        
        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
            debugLog("✅ 文件已导入: \(destinationURL.lastPathComponent)")
            
            let originalLyricsURL = url.deletingPathExtension().appendingPathExtension("lrc")
            let lyrics: String? = FileManager.default.fileExists(atPath: originalLyricsURL.path) ? try? String(contentsOf: originalLyricsURL, encoding: .utf8) : nil
            
            // 异步提取元数据
            Task {
                let asset = AVAsset(url: destinationURL)
                do {
                    let commonMetadata = try await asset.load(.commonMetadata)
                    let title = await Self.extractString(from: commonMetadata, key: .commonKeyTitle) ?? destinationURL.deletingPathExtension().lastPathComponent
                    let artist = await Self.extractString(from: commonMetadata, key: .commonKeyArtist) ?? "未知艺术家"
                    let album = await Self.extractString(from: commonMetadata, key: .commonKeyAlbumName) ?? "未知专辑"
                    let duration = try await asset.load(.duration).seconds
                    let validDuration = duration.isFinite && !duration.isNaN ? duration : 0
                    
                    let song = Song(
                        id: UUID().uuidString,
                        title: title,
                        artist: artist,
                        album: album,
                        duration: validDuration,
                        audioUrl: destinationURL.absoluteString,
                        coverUrl: nil,
                        lyrics: lyrics,
                        virtualArtist: nil,
                        creatorId: nil,
                        isUserGenerated: false,
                        wordLyrics: nil,
                        createdAt: nil,
                        style: nil
                    )
                    
                    await MainActor.run {
                        self.songs.append(song)
                    }
                } catch {
                    debugLog("❌ 提取元数据失败: \(destinationURL.lastPathComponent) - \(error)")
                }
            }
        } catch {
            debugLog("❌ 导入失败: \(error)")
        }
    }
    
    private func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
    
    private func generateUniqueDestinationURL(for filename: String) -> URL {
        let baseURL = documentsURL.appendingPathComponent(filename)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        while true {
            let newName = "\(name) \(counter).\(ext)"
            let newURL = documentsURL.appendingPathComponent(newName)
            if !fileManager.fileExists(atPath: newURL.path) {
                return newURL
            }
            counter += 1
        }
    }
    
    private var metadataQuery: NSMetadataQuery?
    private var queryObserver: AnyCancellable?
    
    // 启动 iCloud Drive 扫描
    func startScanningICloudDrive() {
        guard !isScanningCloud else { return }
        
        metadataQuery?.stop()
        
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = NSPredicate(format: "%K.pathExtension IN %@",
                                      NSMetadataItemFSNameKey,
                                      supportedExtensions)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinishGathering),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        
        self.metadataQuery = query
        query.start()
        
        DispatchQueue.main.async {
            self.isScanningCloud = true
        }
    }
    
    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        processMetadataQueryResults()
    }
    
    @objc private func metadataQueryDidFinishGathering(_ notification: Notification) {
        processMetadataQueryResults()
        DispatchQueue.main.async {
            self.isScanningCloud = false
        }
    }
    
    private func processMetadataQueryResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        
        var newSongs: [Song] = []
        let group = DispatchGroup()
        
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                
                let downloadStatus = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                debugLog("📄 文件: \(fileURL.lastPathComponent), 下载状态: \(downloadStatus ?? "unknown")")
                
                if downloadStatus != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                    debugLog("⏳ 文件未下载，触发下载: \(fileURL.lastPathComponent)")
                    try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    continue
                }
                
                group.enter()
                processFile(fileURL) { song in
                    if let song = song {
                        newSongs.append(song)
                        debugLog("✅ 处理成功: \(song.title)")
                    } else {
                        debugLog("❌ 处理失败: \(fileURL.lastPathComponent)")
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            let existingURLs = Set(self.songs.compactMap { $0.audioURL })
            let songsToAdd = newSongs.filter { song in
                guard let url = song.audioURL else { return false }
                return !existingURLs.contains(url)
            }
            self.songs.append(contentsOf: songsToAdd)
            debugLog("✅ 本次查询新增 \(songsToAdd.count) 首歌曲")
            query.enableUpdates()
        }
    }
    
    private func processFile(_ fileURL: URL, completion: @escaping (Song?) -> Void) {
        guard fileURL.startAccessingSecurityScopedResource() else {
            debugLog("⚠️ 无法获取文件安全访问权限: \(fileURL.path)")
            completion(nil)
            return
        }
        
        let lyricsURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
        let hasLyrics = FileManager.default.fileExists(atPath: lyricsURL.path)
        let lyrics: String? = hasLyrics ? try? String(contentsOf: lyricsURL, encoding: .utf8) : nil
        let asset = AVAsset(url: fileURL)
        
        Task {
            defer { fileURL.stopAccessingSecurityScopedResource() }
            do {
                let commonMetadata = try await asset.load(.commonMetadata)
                let title = await Self.extractString(from: commonMetadata, key: .commonKeyTitle) ?? fileURL.deletingPathExtension().lastPathComponent
                let artist = await Self.extractString(from: commonMetadata, key: .commonKeyArtist) ?? "未知艺术家"
                let album = await Self.extractString(from: commonMetadata, key: .commonKeyAlbumName) ?? "未知专辑"
                let duration = try await asset.load(.duration).seconds
                
                let song = Song(
                    id: UUID().uuidString,
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    audioUrl: fileURL.absoluteString,
                    coverUrl: nil,
                    lyrics: lyrics,
                    virtualArtist: nil,
                    creatorId: nil,
                    isUserGenerated: false,
                    wordLyrics: nil,
                    createdAt: nil,
                    style: nil
                )
                completion(song)
            } catch {
                debugLog("❌ 提取元数据失败: \(fileURL.lastPathComponent) - \(error)")
                completion(nil)
            }
        }
    }
    
    private static func extractString(from metadata: [AVMetadataItem], key: AVMetadataKey) async -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common)
        guard let item = items.first else { return nil }
        return try? await item.load(.value) as? String
    }
    
    private static func extractData(from metadata: [AVMetadataItem], key: AVMetadataKey) async -> Data? {
        let items = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common)
        guard let item = items.first else { return nil }
        return try? await item.load(.dataValue)
    }
    
}


extension LibraryService {
    func deleteSong(songId: String, token: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let baseURLString = AppConfig.baseURL
        guard !baseURLString.isEmpty else {
            completion(.failure(URLError(.badURL)))
            return
        }
        let urlString = baseURLString + "/api/songs/\(songId)"
        guard let url = URL(string: urlString) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"])))
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    completion(.success(()))
                } else {
                    // 尝试解析错误信息
                    var errorMsg = "删除失败"
                    if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                        errorMsg = "服务器返回: \(responseStr)"
                        debugLog("❌ 删除失败，状态码: \(httpResponse.statusCode)，响应: \(responseStr)")
                    } else {
                        debugLog("❌ 删除失败，状态码: \(httpResponse.statusCode)")
                    }
                    completion(.failure(NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                }
            }
        }.resume()
    }
}
