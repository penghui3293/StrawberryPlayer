//// VirtualArtist.swift
//import Foundation
//
//struct VirtualArtist: Identifiable, Codable {
//    let id: String
//    let name: String
//    let avatarURL: URL?
//    let voiceModelId: String?
//    let bio: String?                     // 改为可选
//    let genre: String
//    let createdBy: String
//    let createdAt: Date
//    var songCount: Int
//    var followerCount: Int
//
//}
//extension VirtualArtist {
//    var fullAvatarURL: URL? {
//        guard let urlString = avatarURL?.absoluteString else { return nil }
//        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
//            return avatarURL
//        }
//        let base = AppConfig.baseURL
//        let fullString = base.hasSuffix("/") ? base + urlString.dropFirst() : base + urlString
//        return URL(string: fullString)
//    }
//}

import Foundation

struct VirtualArtist: Identifiable, Codable {
    let id: String
    let name: String
    let avatarURL: URL?
    let voiceModelId: String?
    let bio: String?
    let genre: String
    let createdBy: String
    let createdAt: Date
    var songCount: Int
    var followerCount: Int
}

extension VirtualArtist {
    var fullAvatarURL: URL? {
        guard let urlString = avatarURL?.absoluteString else { return nil }
        
        // 如果已经是安全的 HTTPS，直接返回
        if urlString.hasPrefix("https://") {
            return avatarURL
        }
        
        // 如果是 HTTP，使用 secure 升级为 HTTPS
        if urlString.hasPrefix("http://") {
            return URL.secure(urlString)
        }
        
        // 相对路径，基于 baseURL 拼接（这种情况应该已经被 secure 覆盖）
        let base = AppConfig.baseURL
        let fullString = base.hasSuffix("/") ? base + urlString.dropFirst() : base + urlString
        return URL.secure(fullString)
    }
}
