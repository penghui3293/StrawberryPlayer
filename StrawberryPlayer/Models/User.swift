import Foundation

struct User: Identifiable, Codable {
    let id: String
    let phone: String
    let nickname: String
    let avatarURL: String?
    let createdAt: Date?
    
    // ✅ 新增：AI 生成次数相关字段
    //表示剩余免费次数
    let aiSongRemaining: Int
    //表示总免费次数上限
    let aiSongLimit: Int
    
    enum CodingKeys: String, CodingKey {
        case id
        case phone
        case nickname
        case avatarURL
        case createdAt
        case aiSongRemaining
        case aiSongLimit
    }
    
}
