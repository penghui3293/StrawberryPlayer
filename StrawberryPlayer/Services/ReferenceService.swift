import Foundation
import Combine

// MARK: - Models
struct ReferenceArtist: Codable, Identifiable {
    let id: String          // 后端返回的 UUID 字符串
    let name: String
    let language: String?
    let genreTags: [String]?
    let stylePrompt: String?
    let shortStyleReference: String?   // 新增
    let themeGuidance: String?   // 新增
    let sortOrder: Int?
    let gender: String?   // "male" 或 "female"，可选

}

struct ReferenceSong: Codable, Identifiable {
    let id: String          // 后端返回的 UUID 字符串
    let title: String
    let artist: String
    let coverUrl: String?   // 注意：后端字段名为 cover_url，映射时会自动转换
    let theme: String
    let lyrics: String?          // 新增：歌词参考文本
    let imageryHint: String?     // 新增：意象提示（映射 imagery_hint）
    
    
    // 计算属性，保持与原有 UI 代码兼容（使用 coverURL）
    var coverURL: URL? {
        coverUrl.flatMap { URL(string: $0) }
    }
}

// MARK: - Service
class ReferenceService: ObservableObject {
    static let shared = ReferenceService()
    
    @Published var artists: [ReferenceArtist] = []
    @Published var songsByArtistId: [String: [ReferenceSong]] = [:]
    @Published var isLoading = false
    @Published var error: Error?
    
    
    private var baseURL: String {
        AppConfig.baseURL + "/api/reference"
    }
    
    func loadArtists() async {
        guard let url = URL(string: baseURL + "/artists") else { return }
        await MainActor.run { isLoading = true }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let artists = try decoder.decode([ReferenceArtist].self, from: data)
            await MainActor.run {
                self.artists = artists
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error
                self.isLoading = false
            }
        }
    }
    
    func loadSongs(for artistId: String) async {
        if songsByArtistId[artistId] != nil { return }
        
        guard let url = URL(string: baseURL + "/songs?artistId=\(artistId)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let songs = try decoder.decode([ReferenceSong].self, from: data)
            await MainActor.run {
                songsByArtistId[artistId] = songs
            }
        } catch {
            debugLog("❌ 加载歌曲失败: \(error)")
        }
    }
    
    func filterArtists(for virtualArtist: VirtualArtist) -> [ReferenceArtist] {
        let genre = virtualArtist.genre.lowercased()
        if genre.contains("国语") {
            return artists.filter { $0.language == "国语" }
        } else if genre.contains("粤语") {
            return artists.filter { $0.language == "粤语" }
        } else if genre.contains("欧美") || genre.contains("英语") {
            return artists.filter { $0.language == "English" }
        } else {
            // 默认回退到基于 genreTags 的匹配
            return artists.filter { artist in
                guard let tags = artist.genreTags else { return false }
                return tags.contains { genre.contains($0.lowercased()) }
            }
        }
    }
    
    func stylePrompt(for artist: ReferenceArtist) -> String {
        return artist.stylePrompt ?? "高质量华语流行，旋律优美，情感真挚。"
    }
}
