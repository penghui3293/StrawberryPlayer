//
//  Song.swift
//  StrawberryPlayer
//  歌曲数据模型
//

import Foundation
import AVFoundation

// MARK: - 嵌套的艺人引用
struct VirtualArtistReference: Decodable, Equatable {
    let id: String?
}

struct UserReference: Decodable {
    let id: UUID
}

// MARK: - 歌曲模型
struct Song: Identifiable, Decodable, Equatable {
    // MARK: 存储属性
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let coverUrl: String?      // 后端返回的完整 URL（绝对或相对）
    var audioUrl: String?      // 后端返回的完整 URL（绝对或相对）
    var streamURL: String?   // 对应后端 stream_url，可直接播放的转码后链接
    let lyrics: String?
    let wordLyrics: String?
    let style: String?
    let isUserGenerated: Bool
    let virtualArtist: VirtualArtistReference?
    let virtualArtistId: UUID?
    let creatorId: UUID?
    let createdAt: Date?
    let stableId: String   // ✅ 新增，从服务器获取

    
    // MARK: 计算属性（直接返回 URL，不再拼接 baseURL）
    var coverURL: URL? {
        guard let coverUrl = coverUrl else { return nil }
        if coverUrl.hasPrefix("http://") || coverUrl.hasPrefix("https://") {
            return URL(string: coverUrl)
        }
        // 相对路径，拼接 baseURL
        let base = AppConfig.baseURL
        let fullString = base.hasSuffix("/") ? base + coverUrl.dropFirst() : base + coverUrl
        return URL(string: fullString)
    }
    
    var audioURL: URL? {
        guard let audioUrl = audioUrl else { return nil }
        if audioUrl.hasPrefix("http://") || audioUrl.hasPrefix("https://") {
            return URL(string: audioUrl)
        }
        let base = AppConfig.baseURL
        let fullString = base.hasSuffix("/") ? base + audioUrl.dropFirst() : base + audioUrl
        return URL(string: fullString)
    }
    
    var hasCover: Bool { coverUrl != nil && !coverUrl!.isEmpty }
    var hasLyrics: Bool { lyrics != nil }
    
    // MARK: 解码
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case duration
        case coverUrl
        case audioUrl
        case streamURL           // 对应 JSON 中的 "streamURL"
        case streamUrlString     // 兼容其他可能的命名
        case lyrics
        case wordLyrics
        case style
        case isUserGenerated
        case virtualArtist
        case virtualArtistId
        case creator
        case createdAt
        // 新增兼容字段
        case coverUrlString
        case audioUrlString
        case stableId
    }
    
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 解码 id
        id = try container.decode(String.self, forKey: .id)
        print("🔍 [Song decode] id: \(id)")
        
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        
        // 封面 URL
        if let coverString = try? container.decode(String.self, forKey: .coverUrlString) {
            coverUrl = coverString
        } else {
            coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
        }
        
        // 音频 URL
        if let audioString = try? container.decode(String.self, forKey: .audioUrlString) {
            audioUrl = audioString
        } else {
            audioUrl = try container.decodeIfPresent(String.self, forKey: .audioUrl)
        }
        
        // 解码 streamURL
        if let streamString = try? container.decode(String.self, forKey: .streamURL) {
            streamURL = streamString
        } else if let streamString = try? container.decode(String.self, forKey: .streamUrlString) {
            streamURL = streamString
        } else {
            streamURL = nil
        }
        
        lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)
        wordLyrics = try container.decodeIfPresent(String.self, forKey: .wordLyrics)
        style = try container.decodeIfPresent(String.self, forKey: .style)
        isUserGenerated = try container.decodeIfPresent(Bool.self, forKey: .isUserGenerated) ?? false
        virtualArtist = try container.decodeIfPresent(VirtualArtistReference.self, forKey: .virtualArtist)
        
        // 解码 virtualArtistId
        if let idString = try? container.decode(String.self, forKey: .virtualArtistId) {
            virtualArtistId = UUID(uuidString: idString)
        } else {
            virtualArtistId = virtualArtist?.id.flatMap(UUID.init)
        }
        
        // 解码 creator
        if let creator = try? container.decode(UserReference.self, forKey: .creator) {
            creatorId = creator.id
        } else {
            creatorId = nil
        }
        
        // 解码 createdAt
        if let dateString = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            let formatter = ISO8601DateFormatter()
            createdAt = formatter.date(from: dateString)
        } else {
            createdAt = nil
        }
        
        // ─── 解码 stableId ───
        // 优先从 stableId 字段读取，若不存在则回退到 id，并打印相应信息
        if let sid = try? container.decode(String.self, forKey: .stableId) {
            print("✅ [Song decode] 成功解码 stableId: \(sid)")
            stableId = sid
        } else {
            print("⚠️ [Song decode] 未找到 stableId 字段，使用 id 作为 stableId: \(id)")
            stableId = id
        }
    }
    
//    init(from decoder: Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        id = try container.decode(String.self, forKey: .id)
//        title = try container.decode(String.self, forKey: .title)
//        artist = try container.decode(String.self, forKey: .artist)
//        album = try container.decodeIfPresent(String.self, forKey: .album)
//        duration = try container.decode(TimeInterval.self, forKey: .duration)
//        
//        // 封面 URL：优先使用 coverUrlString，其次 coverUrl
//        if let coverString = try? container.decode(String.self, forKey: .coverUrlString) {
//            coverUrl = coverString
//        } else {
//            coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
//        }
//        
//        // 音频 URL：优先使用 audioUrlString，其次 audioUrl
//        if let audioString = try? container.decode(String.self, forKey: .audioUrlString) {
//            audioUrl = audioString
//        } else {
//            audioUrl = try container.decodeIfPresent(String.self, forKey: .audioUrl)
//        }
//        
//        // ✅ 新增：解码 streamURL（优先使用 streamURL，兼容 streamUrlString）
//        if let streamString = try? container.decode(String.self, forKey: .streamURL) {
//            streamURL = streamString
//        } else if let streamString = try? container.decode(String.self, forKey: .streamUrlString) {
//            streamURL = streamString
//        } else {
//            streamURL = nil
//        }
//        
//        lyrics = try container.decodeIfPresent(String.self, forKey: .lyrics)
//        wordLyrics = try container.decodeIfPresent(String.self, forKey: .wordLyrics)
//        style = try container.decodeIfPresent(String.self, forKey: .style)
//        isUserGenerated = try container.decodeIfPresent(Bool.self, forKey: .isUserGenerated) ?? false
//        virtualArtist = try container.decodeIfPresent(VirtualArtistReference.self, forKey: .virtualArtist)
//        
//        // 解码 virtualArtistId
//        if let idString = try? container.decode(String.self, forKey: .virtualArtistId) {
//            virtualArtistId = UUID(uuidString: idString)
//        } else {
//            virtualArtistId = virtualArtist?.id.flatMap(UUID.init)
//        }
//        
//        if let creator = try? container.decode(UserReference.self, forKey: .creator) {
//            creatorId = creator.id
//        } else {
//            creatorId = nil
//        }
////        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
//        if let dateString = try container.decodeIfPresent(String.self, forKey: .createdAt) {
//            let formatter = ISO8601DateFormatter()
//            createdAt = formatter.date(from: dateString)
//        } else {
//            createdAt = nil
//        }
//        stableId = try container.decodeIfPresent(String.self, forKey: .stableId) ?? id
//    }
    
    
    // 手动初始化器（用于本地创建）
    init(id: String = UUID().uuidString,
         stableId: String? = nil,     // ✅ 新增
         title: String,
         artist: String,
         album: String? = nil,
         duration: TimeInterval,
         audioUrl: String,
         coverUrl: String? = nil,
         lyrics: String? = nil,
         virtualArtist: VirtualArtistReference? = nil,
         virtualArtistId: UUID? = nil,
         creatorId: UUID? = nil,
         isUserGenerated: Bool = false,
         wordLyrics: String? = nil,
         createdAt: Date? = nil,
         style: String? = nil,
         streamURL: String? = nil) {
        self.id = id
        self.stableId = stableId ?? id  // 若没提供则回退到 id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.audioUrl = audioUrl
        self.coverUrl = coverUrl
        self.lyrics = lyrics
        self.wordLyrics = wordLyrics
        self.style = style
        self.isUserGenerated = isUserGenerated
        self.virtualArtist = virtualArtist
        self.virtualArtistId = virtualArtistId
        self.creatorId = creatorId
        self.createdAt = createdAt
        self.streamURL = streamURL            // 赋值
    }
    
    // MARK: 从本地 AVAsset 创建 Song（用于本地文件导入）
    static func from(asset: AVAsset, url: URL, lyricsURL: URL? = nil) -> Song? {
        let metadata = asset.commonMetadata
        
        var title = extractString(from: metadata, withKey: .commonKeyTitle) ?? ""
        if title.isEmpty {
            for format in asset.availableMetadataFormats {
                let formatMetadata = asset.metadata(forFormat: format)
                if let value = extractString(from: formatMetadata, withKey: .commonKeyTitle) {
                    title = value
                    break
                }
            }
        }
        if title.isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }
        
        var artist = extractString(from: metadata, withKey: .commonKeyArtist) ?? ""
        if artist.isEmpty {
            for format in asset.availableMetadataFormats {
                let formatMetadata = asset.metadata(forFormat: format)
                if let value = extractString(from: formatMetadata, withKey: .commonKeyArtist) {
                    artist = value
                    break
                }
            }
        }
        if artist.isEmpty {
            artist = "未知艺术家"
        }
        
        let albumItem = AVMetadataItem.metadataItems(from: metadata,
                                                     withKey: AVMetadataKey.commonKeyAlbumName,
                                                     keySpace: .common).first
        let album = (try? albumItem?.value as? String) ?? "未知专辑"
        
        let duration = asset.duration.seconds
        let validDuration = duration.isFinite && !duration.isNaN ? duration : 0
        
        let lyricsContent = lyricsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        
        return Song(
            id: url.absoluteString,
            title: title,
            artist: artist,
            album: album,
            duration: validDuration,
            audioUrl: url.absoluteString,
            coverUrl: nil,
            lyrics: lyricsContent,
            virtualArtist: nil,
            creatorId: nil,
            isUserGenerated: false,
            wordLyrics: nil,
            createdAt: nil,
            style: nil
        )
    }
    
    private static func extractString(from metadata: [AVMetadataItem], withKey key: AVMetadataKey) -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, withKey: key.rawValue, keySpace: .common)
        return items.first?.value as? String
    }
    
    private static func extractData(from metadata: [AVMetadataItem], withKey key: AVMetadataKey) -> Data? {
        let items = AVMetadataItem.metadataItems(from: metadata, withKey: key.rawValue, keySpace: .common)
        return items.first?.dataValue
    }
    
    var cachedWordLyrics: [[WordLyrics]]? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "wordLyrics_\(id)"),
                  let array = try? JSONDecoder().decode([[WordLyrics]].self, from: data) else { return nil }
            return array
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "wordLyrics_\(id)")
            }
        }
    }
}

