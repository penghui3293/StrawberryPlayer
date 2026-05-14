//
//  NavidromeService.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/3/2.
//

// NavidromeService.swift
import Foundation
import Combine

class NavidromeService: ObservableObject {
    static let shared = NavidromeService()
    
    @Published var isAuthenticated = false
    @Published var serverURL: String = ""
    
    private var username: String = ""
    private var password: String = ""
    private let clientName = "StrawberryPlayer"
    private let apiVersion = "1.16.0"
    
    private init() {
        // 从 UserDefaults 加载保存的认证信息
        if let savedURL = UserDefaults.standard.string(forKey: "navidrome_server") {
            serverURL = savedURL
        }
        if let savedUsername = UserDefaults.standard.string(forKey: "navidrome_username") {
            username = savedUsername
        }
        if let savedPassword = UserDefaults.standard.string(forKey: "navidrome_password") {
            password = savedPassword
        }
        isAuthenticated = !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }
    
    func saveCredentials(server: String, username: String, password: String) {
        self.serverURL = server
        self.username = username
        self.password = password
        UserDefaults.standard.set(server, forKey: "navidrome_server")
        UserDefaults.standard.set(username, forKey: "navidrome_username")
        UserDefaults.standard.set(password, forKey: "navidrome_password")
        isAuthenticated = true
    }
    
    func clearCredentials() {
        serverURL = ""
        username = ""
        password = ""
        UserDefaults.standard.removeObject(forKey: "navidrome_server")
        UserDefaults.standard.removeObject(forKey: "navidrome_username")
        UserDefaults.standard.removeObject(forKey: "navidrome_password")
        isAuthenticated = false
    }
    
    private func buildURL(endpoint: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        var components = URLComponents(string: serverURL + "/rest/" + endpoint)
        var items = queryItems
        items.append(URLQueryItem(name: "u", value: username))
        items.append(URLQueryItem(name: "p", value: password))
        items.append(URLQueryItem(name: "v", value: apiVersion))
        items.append(URLQueryItem(name: "c", value: clientName))
        items.append(URLQueryItem(name: "f", value: "json"))
        components?.queryItems = items
        return components?.url
    }
    
//    private func request<T: Decodable>(_ endpoint: String, queryItems: [URLQueryItem] = []) async throws -> T {
//        guard let url = buildURL(endpoint: endpoint, queryItems: queryItems) else {
//            throw URLError(.badURL)
//        }
//        let (data, _) = try await URLSession.shared.data(from: url)
//        let decoder = JSONDecoder()
//        let response = try decoder.decode(SubsonicResponse<T>.self, from: data)
//        return response.subsonicResponse
//    }
    
    private func request<T: Decodable>(_ endpoint: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let url = buildURL(endpoint: endpoint, queryItems: queryItems) else {
            debugLog("❌ 构建 URL 失败")
            throw URLError(.badURL)
        }
        
        debugLog("🌐 请求 URL: \(url.absoluteString)")
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        debugLog("📥 响应状态码: \(httpResponse.statusCode)")
        
        // 打印原始响应内容（用于调试）
        if let responseStr = String(data: data, encoding: .utf8) {
            debugLog("📦 原始响应: \(responseStr)")
        }
        
        // 如果状态码不是200，尝试解析错误信息
        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(SubsonicErrorResponse.self, from: data) {
                let errorMsg = errorResponse.subsonicResponse.error?.message ?? "未知错误"
                throw NSError(domain: "Navidrome", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            } else {
                // 无法解析为错误响应，直接抛出状态码错误
                throw URLError(.badServerResponse)
            }
        }
        
        // 尝试解析目标类型
        do {
            let result = try JSONDecoder().decode(SubsonicResponse<T>.self, from: data)
            return result.subsonicResponse
        } catch {
            debugLog("❌ JSON 解析失败: \(error)")
            // 再次打印原始响应以便排查
            if let responseStr = String(data: data, encoding: .utf8) {
                debugLog("📦 无法解析的响应: \(responseStr)")
            }
            throw error
        }
    }
    
    // 获取专辑列表
    func getAlbumList(offset: Int = 0, limit: Int = 100) async throws -> [SubsonicAlbum] {
        let queryItems = [
            URLQueryItem(name: "type", value: "random"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "size", value: "\(limit)")
        ]
        struct Response: Decodable {
            let albumList2: AlbumList
        }
        struct AlbumList: Decodable {
            let album: [SubsonicAlbum]
        }
        let result: Response = try await request("getAlbumList2", queryItems: queryItems)
        return result.albumList2.album
    }
    
    // 获取专辑详情（包含歌曲）
    func getAlbum(id: String) async throws -> [SubsonicSong] {
        let queryItems = [URLQueryItem(name: "id", value: id)]
        struct Response: Decodable {
            let album: AlbumDetail
        }
        struct AlbumDetail: Decodable {
            let song: [SubsonicSong]?
        }
        let result: Response = try await request("getAlbum", queryItems: queryItems)
        return result.album.song ?? []
    }
    
    // 获取歌曲流 URL
    func getStreamURL(songId: String) -> URL? {
        return buildURL(endpoint: "stream", queryItems: [URLQueryItem(name: "id", value: songId)])
    }
    
    // 获取封面图片 URL
    func getCoverArtURL(coverArtId: String, size: Int? = nil) -> URL? {
        var items = [URLQueryItem(name: "id", value: coverArtId)]
        if let size = size {
            items.append(URLQueryItem(name: "size", value: "\(size)"))
        }
        return buildURL(endpoint: "getCoverArt", queryItems: items)
    }
}

// Subsonic 数据模型
struct SubsonicAlbum: Decodable, Identifiable {
    let id: String
    let name: String
    let artist: String
    let coverArt: String?
    let songCount: Int
    let duration: Int?
}

struct SubsonicSong: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Int?
    let track: Int?
    let coverArt: String?
}

// Subsonic 响应包装
//struct SubsonicResponse<T: Decodable>: Decodable {
//    let subsonicResponse: T
//}

// Subsonic 错误响应模型
//struct SubsonicErrorResponse: Decodable {
//    let subsonicResponse: SubsonicError
//    
//    enum CodingKeys: String, CodingKey {
//        case subsonicResponse = "subsonic-response"
//    }
//}

struct SubsonicResponse<T: Decodable>: Decodable {
    let subsonicResponse: T
    
    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicErrorResponse: Decodable {
    let subsonicResponse: SubsonicError
    
    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

struct SubsonicError: Decodable {
    let status: String
    let version: String
    let error: SubsonicErrorDetail?
}

struct SubsonicErrorDetail: Decodable {
    let code: Int
    let message: String
}
