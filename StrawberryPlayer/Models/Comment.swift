import Foundation

struct Comment: Identifiable, Codable {
    let id: String
    let content: String
    let userName: String
    let avatarURL: String?           // 头像 URL（对应后端 userAvatar）
    let createdAt: Date
    var likesCount: Int
    let parentId: String?            // 父评论 ID（一级评论为 nil）
    let isPinned: Bool               // 是否置顶
    let replyCount: Int              // 回复总数（来自后端）
    var isLiked: Bool                // 当前用户是否已点赞

    // 前端组织树时使用，不参与解码
    var replies: [Comment] = []
    var hasLoadedReplies: Bool = false   // 是否已加载子评论

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case userName
        case avatarURL = "userAvatar"   // 映射后端返回的 userAvatar 字段
        case createdAt
        case likesCount
        case parentId
        case isPinned
        case replyCount
        case isLiked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        userName = try container.decode(String.self, forKey: .userName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        likesCount = try container.decode(Int.self, forKey: .likesCount)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        replyCount = try container.decode(Int.self, forKey: .replyCount)
        isLiked = try container.decode(Bool.self, forKey: .isLiked)

        // replies 和 hasLoadedReplies 保持默认值
    }

    // 可选：提供便捷初始化方法（用于测试或本地创建）
    init(id: String, content: String, userName: String, avatarURL: String? = nil,
         createdAt: Date, likesCount: Int, parentId: String? = nil, isPinned: Bool = false,
         replyCount: Int = 0, isLiked: Bool = false) {
        self.id = id
        self.content = content
        self.userName = userName
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.likesCount = likesCount
        self.parentId = parentId
        self.isPinned = isPinned
        self.replyCount = replyCount
        self.isLiked = isLiked
    }
}

// MARK: - 树节点辅助结构
struct CommentNode: Identifiable {
    let id: String
    let comment: Comment
    var children: [CommentNode] = []
}

extension Comment {
    func toNode(children: [CommentNode] = []) -> CommentNode {
        CommentNode(id: id, comment: self, children: children)
    }
}
